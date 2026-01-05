defmodule Skuld.Effects.FxList do
  @moduledoc """
  FxList - Effectful list operations with full control effect support.

  The default effectful list module with full support for resumable
  Yield/Suspend semantics. Uses continuation chains for natural control
  effect propagation.

  ## When to Use FxList vs FxFasterList

  | Feature                    | FxList      | FxFasterList |
  |----------------------------|-------------|--------------|
  | Throw (error handling)     | ✓ Works     | ✓ Works      |
  | Yield (suspend/resume)     | ✓ Full      | ✗ Limited    |
  | Performance                | ~0.2 µs/op  | ~0.1 µs/op   |
  | Memory                     | Higher      | Lower        |

  **Use FxList (this module) when:**
  - You need resumable Yield/Suspend semantics
  - Each element might yield and you need to resume from that exact point
  - Natural control effect propagation is important
  - This is the recommended default

  **Use FxFasterList when:**
  - Performance is critical
  - You only use Throw for error handling (not Yield)
  - You don't need to resume suspended computations

  ## How It Works

  FxList elaborates the list operation into a chain of `Comp.bind` calls:

  ```elixir
  # fx_map([1, 2, 3], f) becomes:
  Comp.bind(f.(1), fn r1 ->
    Comp.bind(f.(2), fn r2 ->
      Comp.bind(f.(3), fn r3 ->
        Comp.pure([r1, r2, r3])
      end)
    end)
  end)
  ```

  This means control effects propagate naturally through CPS - no special
  pattern matching needed. When a computation yields, the continuation
  chain captures the full iteration context for proper resumption.

  ## Operations

  - `fx_map(enumerable, f)` - Map effectful function over enumerable
  - `fx_reduce(enumerable, init, f)` - Reduce with effectful function
  - `fx_each(enumerable, f)` - Execute effectful function for each element
  - `fx_filter(enumerable, pred)` - Filter with effectful predicate

  ## Example with Yield

      # Process items with interruptible iteration
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(Yield.yield({:processing, x}), fn _ ->
            Comp.pure(x * 2)
          end)
        end)
        |> Yield.with_handler()

      # Each yield can be resumed to continue through the list
      {%Suspend{value: {:processing, 1}, resume: r1}, _} = Comp.run(comp)
      {%Suspend{value: {:processing, 2}, resume: r2}, _} = r1.(:ok)
      {%Suspend{value: {:processing, 3}, resume: r3}, _} = r2.(:ok)
      {[2, 4, 6], _} = r3.(:ok)
  """

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @doc """
  Map an effectful function over an enumerable.

  Returns a computation that produces a list of results.
  Each element's computation is chained via `Comp.bind`, so control
  effects propagate naturally.

  ## Example

      FxList.fx_map([1, 2, 3], fn x ->
        comp do
          count <- State.get()
          _ <- State.put(count + 1)
          return(x * 2)
        end
      end)
      # => computation returning [2, 4, 6]
  """
  @spec fx_map(Enumerable.t(), (term() -> Types.computation())) :: Types.computation()
  def fx_map(enumerable, f) do
    enumerable
    |> Enum.to_list()
    |> do_fx_map(f)
  end

  defp do_fx_map([], _f) do
    Comp.pure([])
  end

  defp do_fx_map([elem | rest], f) do
    Comp.bind(f.(elem), fn result ->
      Comp.bind(do_fx_map(rest, f), fn rest_results ->
        Comp.pure([result | rest_results])
      end)
    end)
  end

  @doc """
  Reduce an enumerable with an effectful function.

  Each element's computation is chained via `Comp.bind`.

  ## Example

      FxList.fx_reduce([1, 2, 3], 0, fn x, acc ->
        comp do
          _ <- Writer.tell("processing \#{x}")
          return(acc + x)
        end
      end)
      # => computation returning 6
  """
  @spec fx_reduce(Enumerable.t(), term(), (term(), term() -> Types.computation())) ::
          Types.computation()
  def fx_reduce(enumerable, init, f) do
    enumerable
    |> Enum.to_list()
    |> do_fx_reduce(init, f)
  end

  defp do_fx_reduce([], acc, _f) do
    Comp.pure(acc)
  end

  defp do_fx_reduce([elem | rest], acc, f) do
    Comp.bind(f.(elem, acc), fn new_acc ->
      do_fx_reduce(rest, new_acc, f)
    end)
  end

  @doc """
  Execute an effectful function for each element, discarding results.

  Returns a computation that produces `:ok`.

  ## Example

      FxList.fx_each(1..1000, fn i ->
        comp do
          n <- State.get()
          _ <- State.put(n + 1)
          return(:ok)
        end
      end)
      # => computation returning :ok
  """
  @spec fx_each(Enumerable.t(), (term() -> Types.computation())) :: Types.computation()
  def fx_each(enumerable, f) do
    enumerable
    |> Enum.to_list()
    |> do_fx_each(f)
  end

  defp do_fx_each([], _f) do
    Comp.pure(:ok)
  end

  defp do_fx_each([elem | rest], f) do
    Comp.bind(f.(elem), fn _result ->
      do_fx_each(rest, f)
    end)
  end

  @doc """
  Filter an enumerable with an effectful predicate.

  ## Example

      FxList.fx_filter([1, 2, 3, 4], fn x ->
        comp do
          threshold <- Reader.ask()
          return(x > threshold)
        end
      end)
      # With threshold=2 => computation returning [3, 4]
  """
  @spec fx_filter(Enumerable.t(), (term() -> Types.computation())) :: Types.computation()
  def fx_filter(enumerable, pred) do
    enumerable
    |> Enum.to_list()
    |> do_fx_filter(pred)
  end

  defp do_fx_filter([], _pred) do
    Comp.pure([])
  end

  defp do_fx_filter([elem | rest], pred) do
    Comp.bind(pred.(elem), fn keep? ->
      Comp.bind(do_fx_filter(rest, pred), fn rest_results ->
        if keep? do
          Comp.pure([elem | rest_results])
        else
          Comp.pure(rest_results)
        end
      end)
    end)
  end
end
