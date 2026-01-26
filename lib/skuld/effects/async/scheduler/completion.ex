defmodule Skuld.Effects.Async.Scheduler.Completion do
  @moduledoc """
  Normalize completion messages from various sources to a common format.

  The scheduler receives messages from multiple sources:
  - Tasks: `{ref, result}` on success, `{:DOWN, ref, :process, pid, reason}` on failure
  - Timers: `{:timeout, ref, _msg}` when fired
  - AsyncComputations: `{AsyncComputation, tag, result}` for various outcomes

  This module normalizes these to a common `{:completed, target_key, result}` format
  that the scheduler state can process uniformly.

  ## Message Formats

  ### Task Messages (from Task.async)

  ```elixir
  # Success - task returned a value
  {ref, value} when is_reference(ref)

  # Failure - task process died
  {:DOWN, ref, :process, pid, reason}
  ```

  ### Timer Messages (from Process.send_after)

  ```elixir
  {:timeout, ref, _msg}
  ```

  ### AsyncComputation Messages

  ```elixir
  # Success - computation completed
  {AsyncComputation, tag, value}

  # Yielded - computation wants external input (not a completion)
  {AsyncComputation, tag, %Suspend{}}

  # Threw - computation threw an error
  {AsyncComputation, tag, %Throw{}}

  # Cancelled - computation was cancelled
  {AsyncComputation, tag, %Cancelled{}}
  ```
  """

  alias Skuld.AsyncComputation
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.Suspend
  alias Skuld.Comp.Throw
  alias Skuld.Effects.Async.AwaitRequest

  @type target_key :: AwaitRequest.target_key()
  @type result :: {:ok, term()} | {:error, term()}

  @type completion :: {:completed, target_key(), result()}
  @type yield :: {:yielded, target_key(), Suspend.t()}
  @type match_result :: completion() | yield() | :unknown

  @doc """
  Match a message and extract completion info.

  Returns one of:
  - `{:completed, target_key, {:ok, value}}` - Target completed successfully
  - `{:completed, target_key, {:error, reason}}` - Target failed
  - `{:yielded, target_key, suspend}` - AsyncComputation yielded (needs external handling)
  - `:unknown` - Message not recognized as a completion
  """
  @spec match(term()) :: match_result()

  # Task success: {ref, result}
  def match({ref, result}) when is_reference(ref) do
    {:completed, {:task, ref}, {:ok, result}}
  end

  # Task failure: {:DOWN, ref, :process, pid, reason}
  def match({:DOWN, ref, :process, _pid, reason}) when is_reference(ref) do
    {:completed, {:task, ref}, {:error, {:down, reason}}}
  end

  # Timer fired: {:timeout, ref, msg}
  def match({:timeout, ref, _msg}) when is_reference(ref) do
    {:completed, {:timer, ref}, {:ok, :timeout}}
  end

  # AsyncComputation yielded - not a completion, needs external handling
  def match({AsyncComputation, tag, %Suspend{} = suspend}) do
    {:yielded, {:computation, tag}, suspend}
  end

  # AsyncComputation threw
  def match({AsyncComputation, tag, %Throw{error: error}}) do
    {:completed, {:computation, tag}, {:error, {:throw, error}}}
  end

  # AsyncComputation cancelled
  def match({AsyncComputation, tag, %Cancelled{reason: reason}}) do
    {:completed, {:computation, tag}, {:error, {:cancelled, reason}}}
  end

  # AsyncComputation completed with value
  def match({AsyncComputation, tag, result}) do
    {:completed, {:computation, tag}, {:ok, result}}
  end

  # Unknown message
  def match(_), do: :unknown
end
