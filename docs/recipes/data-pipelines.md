# Data Pipelines

Brook provides streaming data pipelines with backpressure, concurrent
transforms, and automatic I/O batching. It runs within a single BEAM
process using cooperative fibers, making it lightweight and fast for
I/O-bound workloads.

## Basic pipeline

```elixir
comp do
  source <- Brook.from_enum(1..1000)
  mapped <- Brook.map(source, &transform/1)
  filtered <- Brook.filter(mapped, &valid?/1)
  Brook.to_list(filtered)
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

## Concurrent transforms

Add concurrency to any stage with the `concurrency:` option:

```elixir
comp do
  source <- Brook.from_enum(items)
  enriched <- Brook.map(source, &enrich/1, concurrency: 4)
  Brook.to_list(enriched)
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

With `concurrency: 4`, up to 4 chunks process simultaneously. Order
is preserved regardless of which chunk finishes first.

## Streaming from external sources

Use `from_function` for sources that produce data incrementally:

```elixir
comp do
  source <- Brook.from_function(fn ->
    case ExternalAPI.fetch_page(cursor) do
      {:ok, %{items: items, next: nil}} -> {:items, items}
      {:ok, %{items: items, next: next}} ->
        Process.put(:cursor, next)
        {:items, items}
      {:error, e} -> {:error, e}
    end
  end, chunk_size: 50)

  Brook.each(source, fn item ->
    comp do
      _ <- DB.insert(Record.changeset(%Record{}, item))
      :ok
    end
  end)
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

## ETL pipeline with I/O batching

Combine Brook with Query contracts for automatic batching across
pipeline stages:

```elixir
defmodule ETL.Queries do
  use Skuld.Query.Contract
  deffetch lookup_customer(ref :: String.t()) :: Customer.t() | nil
  deffetch lookup_product(sku :: String.t()) :: Product.t() | nil
end

defcomp enrich_order(raw_order) do
  customer <- ETL.Queries.lookup_customer(raw_order.customer_ref)
  product <- ETL.Queries.lookup_product(raw_order.product_sku)
  %{
    order: raw_order,
    customer: customer,
    product: product,
    total: raw_order.quantity * (product && product.price || 0)
  }
end

comp do
  # Stream raw orders
  source <- Brook.from_enum(raw_orders, chunk_size: 10)

  # Enrich with concurrent lookups - queries batch automatically
  enriched <- Brook.map(source, &enrich_order/1, concurrency: 5)

  # Filter invalid
  valid <- Brook.filter(enriched, fn o -> o.customer != nil end)

  # Persist
  Brook.each(valid, fn order ->
    comp do
      _ <- DB.insert(EnrichedOrder.changeset(%EnrichedOrder{}, order))
      :ok
    end
  end)
end
|> ETL.Queries.with_executor(ETL.Queries.EctoExecutor)
|> DB.Ecto.with_handler(MyApp.Repo)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

With `chunk_size: 10` and `concurrency: 5`, up to 50 orders are in
flight at once. All `lookup_customer` calls across those 50 orders
batch into a single executor invocation, and all `lookup_product`
calls batch into another.

## Backpressure control

Each stage uses a bounded channel buffer. Configure with `buffer:`:

```elixir
Brook.map(source, &slow_transform/1, buffer: 5, concurrency: 3)
```

When the consumer can't keep up, the buffer fills, and the producer
blocks. This prevents memory from growing unboundedly.

Default buffer size is 10. For CPU-bound transforms, larger buffers
can smooth out variance. For memory-heavy items, smaller buffers keep
footprint low.

## Side effects per item

Use `Brook.each` for fire-and-forget side effects:

```elixir
Brook.each(stream, fn item ->
  comp do
    _ <- Writer.tell(%{processed: item.id})
    :ok
  end
end)
```

Use `Brook.run` when you need to consume items with a callback:

```elixir
Brook.run(stream, fn item ->
  comp do
    _ <- DB.insert(changeset_for(item))
    :ok
  end
end)
```

## When to use Brook vs GenStage

- **Brook** - I/O-bound pipelines, automatic query batching, order
  preservation, lightweight (no process overhead)
- **GenStage/Flow** - CPU-bound parallel processing across cores,
  long-lived production pipelines, built-in rate limiting
- **Enum/Stream** - Simple sequential processing, no concurrency needed

Brook shines when your pipeline spends most of its time waiting on
I/O (database queries, API calls) and can benefit from batching those
calls across concurrent items.
