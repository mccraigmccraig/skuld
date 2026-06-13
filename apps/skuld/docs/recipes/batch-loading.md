# Batch Loading

<!-- nav:header:start -->
[< Durable Computation](durable-computation.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:header:end -->

Eliminate N+1 queries with `deffetch` operations and `FiberPool`.

Each `deffetch` call suspends the current fiber, signalling the scheduler
to hold the request. `FiberPool` collects suspended fetch calls across
*all* concurrent fibers and dispatches them in batches to your executor.
Within a `query do` block, dependency analysis adds automatic concurrency
for independent fetches. Together they eliminate N+1 queries without
restructuring code.

## When you need this

If your data lives in a single SQL database, Ecto joins and preloads
handle N+1 well — the query planner does the heavy lifting. This recipe
is for when your data lives *behind remote APIs*: REST services, gRPC
endpoints, GraphQL resolvers, S3 listings — anything without a join engine.

## The N+1 problem with remote APIs

You're building a blog analytics dashboard. Users, posts, and comments
live behind three separate services — each exposes a "batch by ID"
endpoint, but none can join across services.

A naive approach walks the tree row-by-row, making one HTTP call per
entity:

```elixir
# 1 + N + (N * M) HTTP calls: one for users, then N for posts, then N * M for comments
{:ok, users} <- UserService.list_users()

Enum.map(users, fn user ->
  {:ok, posts} <- PostService.get_posts(user.id)

  posts_with_counts =
    Enum.map(posts, fn post ->
      {:ok, comments} <- CommentService.get_comments(post.id)
      Map.put(post, :comment_count, length(comments))
    end)

  {user, posts_with_counts}
end)
```

For 10 users averaging 5 posts each, that's 1 + 10 + 50 = 61 HTTP
round-trips. Each round-trip might be 50-200ms. Your dashboard takes
*seconds* to render.

## The manual batching alternative

Each service has bulk endpoints (`/users?ids=1,2,3`), so you batch
manually:

```elixir
# Step 1: batch all users
{:ok, users} <- UserService.list_users()
user_ids = Enum.map(users, & &1.id)

# Step 2: batch all posts for all users
{:ok, posts} <- PostService.get_posts_bulk(user_ids)

# Step 3: group posts by user, extract post IDs, batch comments
posts_by_user = Enum.group_by(posts, & &1.user_id)
post_ids = Enum.map(posts, & &1.id)
{:ok, comments} <- CommentService.get_comments_bulk(post_ids)
comments_by_post = Enum.group_by(comments, & &1.post_id)

# Step 4: reassemble the tree
Enum.map(users, fn user ->
  user_posts = Map.get(posts_by_user, user.id, [])
  |> Enum.map(fn post ->
    count = Map.get(comments_by_post, post.id, []) |> length()
    Map.put(post, :comment_count, count)
  end)
  {user, user_posts}
end)
```

This works — 3 HTTP calls instead of 61. But the orchestration code is
brittle: three `Enum.group_by` calls, manual ID extraction at each level,
and the reassembly logic is coupled to the batching strategy. Add another
level of nesting (comment reactions? threads?) and it gets worse.

## Skuld's approach

Declare the fetches as `deffetch` operations. Each one generates a function
that returns a suspended computation (`InternalSuspend`) carrying the
operation data — a description of the fetch, not the fetch itself. The
FiberPool scheduler collects these across all concurrent fibers and
dispatches them in batches to your executor:

```elixir
defmodule BlogQueries do
  use Skuld.QueryContract

  deffetch fetch_user(id :: String.t()) :: User.t() | nil
  deffetch fetch_posts(user_id :: String.t()) :: [Post.t()]
  deffetch fetch_comment_count(post_id :: String.t()) :: non_neg_integer()
end
```

Build a summary for one user. The `query` block automatically batches
calls across concurrent transforms. `Query.map` spawns each comment-count
fetch as a fiber so they batch together:

```elixir
defquery build_user_summary(user_id) do
  user <- BlogQueries.fetch_user(user_id)
  posts <- BlogQueries.fetch_posts(user_id)

  post_ids = Enum.map(posts, & &1.id)
  comment_counts <- Query.map(post_ids, &BlogQueries.fetch_comment_count/1)

  posts_with_counts =
    Enum.zip_with(posts, comment_counts, fn post, count ->
      Map.put(post, :comment_count, count)
    end)

  {user, posts_with_counts}
end
```

Notice there's no batching code — no `Enum.group_by`, no manual ID
extraction, no tree reassembly. You write the domain logic for *one*
user, and the system handles the rest.

## Streaming with concurrency

Feed a stream of user IDs through `Brook.map` with concurrency. The
query system batches `deffetch` calls from *all* concurrent
`build_user_summary` transforms:

```elixir
defcomp build_user_summaries(user_ids_source) do
  concurrency <- Reader.ask(BlogQueries.Concurrency)

  Brook.map(
    user_ids_source,
    &build_user_summary/1,
    concurrency: concurrency
  )
end

comp do
  user_ids_source <- Brook.from_enum(user_ids, buffer: 20)
  summaries <- build_user_summaries(user_ids_source)
  Brook.to_list(summaries)
end
|> Skuld.Query.with_executor(BlogQueries, BlogAPIExecutor)
|> Reader.with_handler(%{BlogQueries.Concurrency => 4})
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

## What happens

With `concurrency: 4`, the FiberPool runs 4 `build_user_summary`
transforms concurrently. As each transform calls `fetch_user(user_id)`,
the query system holds the call. When the run queue is empty and there's
no more enqueued work, all accumulated batch suspensions are dispatched
together in a single round-trip:

- **10 users, concurrency 4**: `fetch_user` calls arrive in batches
  of [4, 4, 2] → 3 HTTP calls. Same for `fetch_posts`.
- **10 users, concurrency 1**: each batch has only 1 call → no
  batching benefit (10 HTTP calls per fetch type).

Dependent calls (like `fetch_comment_count` which depends on `posts`
from the previous fetch) wait for their inputs and run in subsequent
rounds — but they still batch across all concurrent transforms.

## Wiring the executor

The executor receives a *list* of `{ref, op}` tuples — all the calls
that were batched together — and returns a map keyed by ref:

```elixir
defmodule BlogAPIExecutor do
  @behaviour BlogQueries

  @impl true
  def fetch_user(ops) do
    ids = Enum.map(ops, fn {_ref, %BlogQueries.FetchUser{id: id}} -> id end)
    results = UserAPI.bulk_get_users(ids)

    Map.new(ops, fn {ref, %{id: id}} ->
      {ref, Map.get(results, id)}
    end)
  end

  @impl true
  def fetch_posts(ops) do
    user_ids = Enum.map(ops, fn {_ref, %BlogQueries.FetchPosts{user_id: uid}} -> uid end)
    results = PostAPI.bulk_get_posts_by_users(user_ids)

    Map.new(ops, fn {ref, %{user_id: uid}} ->
      {ref, Map.get(results, uid, [])}
    end)
  end

  @impl true
  def fetch_comment_count(ops) do
    post_ids = Enum.map(ops, fn {_ref, %BlogQueries.FetchCommentCount{post_id: pid}} -> pid end)
    results = CommentAPI.bulk_get_comment_counts(post_ids)

    Map.new(ops, fn {ref, %{post_id: pid}} ->
      {ref, Map.fetch!(results, pid)}
    end)
  end
end
```

The batching interface is the same regardless of what's behind the
executor: a REST API, a gRPC stub, a Cachex cache, or an in-memory
map for testing.

## How it works

`query do` blocks desugar into `deffetch` calls with dependency analysis.
Independent operations are held and dispatched in batches via `FiberPool`.
Dependent operations wait for their inputs and run in subsequent rounds.
The result is automatic N+1 elimination — no manual batching, no data
loader boilerplate, no code restructuring.

This sounds like a lot, but it's the composition of individually simple
concepts — which is exactly what algebraic effects enable. `deffetch` calls
return a suspended computation with data describing the operation
(`Skuld.Comp.InternalSuspend`). Fibers, like coroutines, are also suspended
computations bundled with some state ([Coroutine](../effects/coroutine.md)).
[FiberPool](../effects/fiberpool.md) decides which suspended computation to
run next.

Batching, concurrency, and data fetching are three separate concerns.
Skuld gives you the first two for free so you only write the third.

<!-- nav:footer:start -->

---

[< Durable Computation](durable-computation.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:footer:end -->
