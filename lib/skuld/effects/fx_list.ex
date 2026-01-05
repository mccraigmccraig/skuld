defmodule Skuld.Effects.FxList do
  @moduledoc """
  FxList - High-performance effectful list operations.

  Provides map and reduce operations with effectful functions using an
  optimized iterative approach. Best for computations that don't need
  resumable Yield/Suspend semantics.

  ## When to Use FxList vs FxControlList

  | Feature                    | FxList      | FxControlList |
  |----------------------------|-------------|--------------|
  | Performance                | ~2x faster  | Slower       |
  | Throw (error handling)     | ✓ Works     | ✓ Works      |
  | Yield (suspend/resume)     | ✗ Limited*  | ✓ Full       |
  | Memory                     | Lower       | Higher       |

  *FxList suspends but loses list context - resume returns only the
  single element's result, not the full list.

  **Use FxList when:**
  - Performance is critical
  - You only use Throw for error handling (not Yield)
  - You don't need to resume suspended computations

  **Use FxControlList when:**
  - You need resumable Yield/Suspend semantics
  - You want natural control effect propagation

  ## Operations

  - `fx_map(enumerable, f)` - Map effectful function over enumerable
  - `fx_reduce(enumerable, init, f)` - Reduce with effectful function
  - `fx_each(enumerable, f)` - Execute effectful function for each element (returns :ok)
  - `fx_filter(enumerable, pred)` - Filter with effectful predicate

  ## Example

      import Skuld.Syntax

      defcomp process_users(user_ids) do
        users <- FxList.fx_map(user_ids, fn id ->
          comp do
            user <- fetch_user(id)
            count <- State.get()
            _ <- State.put(count + 1)
            return(user)
          end
        end)
        return(users)
      end

  ## Implementation

  FxList uses `Enum.reduce_while` to iterate, running each element's
  computation to completion before moving to the next. This avoids
  building continuation chains, providing ~0.1 µs/op constant cost.

  Control effects (Throw, Suspend) are detected via pattern matching
  and handled explicitly - Throw propagates correctly, but Suspend
  loses the iteration context.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @doc """
  Map an effectful function over an enumerable.

  Returns a computation that produces a list of results.
  Each element's computation runs to completion before the next begins,
  avoiding continuation chain buildup.

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
    fn env, outer_k ->
      result =
        Enum.reduce_while(enumerable, {:ok, [], env}, fn elem, {:ok, acc, current_env} ->
          case Comp.call(f.(elem), current_env, &Comp.identity_k/2) do
            {%Comp.Throw{} = throw, err_env} ->
              {:halt, {:error, throw, err_env}}

            {%Comp.Suspend{} = suspend, suspend_env} ->
              {:halt, {:suspended, suspend, suspend_env}}

            {value, new_env} ->
              {:cont, {:ok, [value | acc], new_env}}
          end
        end)

      case result do
        {:ok, acc, final_env} ->
          outer_k.(Enum.reverse(acc), final_env)

        {:error, throw, err_env} ->
          err_env.leave_scope.(throw, err_env)

        {:suspended, suspend, suspend_env} ->
          {suspend, suspend_env}
      end
    end
  end

  @doc """
  Reduce an enumerable with an effectful function.

  Each element's computation runs to completion before the next begins.

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
    fn env, outer_k ->
      result =
        Enum.reduce_while(enumerable, {:ok, init, env}, fn elem, {:ok, acc, current_env} ->
          case Comp.call(f.(elem, acc), current_env, &Comp.identity_k/2) do
            {%Comp.Throw{} = throw, err_env} ->
              {:halt, {:error, throw, err_env}}

            {%Comp.Suspend{} = suspend, suspend_env} ->
              {:halt, {:suspended, suspend, suspend_env}}

            {new_acc, new_env} ->
              {:cont, {:ok, new_acc, new_env}}
          end
        end)

      case result do
        {:ok, final_acc, final_env} ->
          outer_k.(final_acc, final_env)

        {:error, throw, err_env} ->
          err_env.leave_scope.(throw, err_env)

        {:suspended, suspend, suspend_env} ->
          {suspend, suspend_env}
      end
    end
  end

  @doc """
  Execute an effectful function for each element, discarding results.

  Returns a computation that produces `:ok`.
  Each element's computation runs to completion before the next begins.

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
    fn env, outer_k ->
      result =
        Enum.reduce_while(enumerable, {:ok, env}, fn elem, {:ok, current_env} ->
          case Comp.call(f.(elem), current_env, &Comp.identity_k/2) do
            {%Comp.Throw{} = throw, err_env} ->
              {:halt, {:error, throw, err_env}}

            {%Comp.Suspend{} = suspend, suspend_env} ->
              {:halt, {:suspended, suspend, suspend_env}}

            {_value, new_env} ->
              {:cont, {:ok, new_env}}
          end
        end)

      case result do
        {:ok, final_env} ->
          outer_k.(:ok, final_env)

        {:error, throw, err_env} ->
          err_env.leave_scope.(throw, err_env)

        {:suspended, suspend, suspend_env} ->
          {suspend, suspend_env}
      end
    end
  end

  @doc """
  Filter an enumerable with an effectful predicate.

  Each element's predicate runs to completion before the next begins.

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
    fn env, outer_k ->
      result =
        Enum.reduce_while(enumerable, {:ok, [], env}, fn elem, {:ok, acc, current_env} ->
          case Comp.call(pred.(elem), current_env, &Comp.identity_k/2) do
            {%Comp.Throw{} = throw, err_env} ->
              {:halt, {:error, throw, err_env}}

            {%Comp.Suspend{} = suspend, suspend_env} ->
              {:halt, {:suspended, suspend, suspend_env}}

            {keep?, new_env} ->
              new_acc = if keep?, do: [elem | acc], else: acc
              {:cont, {:ok, new_acc, new_env}}
          end
        end)

      case result do
        {:ok, acc, final_env} ->
          outer_k.(Enum.reverse(acc), final_env)

        {:error, throw, err_env} ->
          err_env.leave_scope.(throw, err_env)

        {:suspended, suspend, suspend_env} ->
          {suspend, suspend_env}
      end
    end
  end
end
