# Throw & Bracket

Error handling and resource management.

## Throw

Raise and catch errors within a computation:

```elixir
_ <- Throw.throw(:not_found)        # raise an error
Throw.catch_error(comp, fn error -> ... end)  # catch and handle
Throw.intercept(:not_found, comp)   # catch specific error, return nil
```

The `throw` operation creates a `%Comp.Throw{}` sentinel. Without a
`Throw.with_handler`, the computation stops. With one, errors are
propagated through the handler chain.

```elixir
computation |> Throw.with_handler()
```

Place `Throw.with_handler` outermost in your handler stack so it
catches errors from all inner handlers.

## Bracket

Acquire a resource, use it, then release it — regardless of errors:

```elixir
Bracket.bracket(
  fn -> open_file(path) end,        # acquire
  fn file -> File.close(file) end,  # release
  fn file -> process(file) end      # use
)
```

The release function runs even if `process` throws an error.
`Bracket.finally/2` provides just the cleanup:

```elixir
comp |> Bracket.finally(fn -> cleanup() end)
```

Bracket is a pure combinator — no handler needed. It composes naturally
with other effects in the stack.

## Error handling patterns

```elixir
defcomp safe_lookup(id) do
  result <- Throw.catch_error(
    do_lookup(id),
    fn
      :not_found -> {:error, :not_found}
      other -> Throw.throw(other)   # re-raise unexpected errors
    end
  )
  result
end

# Place Throw handler outermost
safe_lookup("123")
|> State.with_handler(0)
|> Throw.with_handler()
|> Comp.run!()
```

| Operation | Purpose |
|-----------|---------|
| `Throw.throw(error)` | Raise an error |
| `Throw.catch_error(comp, handler_fn)` | Catch and handle |
| `Throw.intercept(error_val, comp)` | Catch specific error, return nil |
| `Bracket.bracket(acquire, use, release)` | Resource with cleanup |
| `Bracket.finally(comp, cleanup)` | Cleanup after computation |
