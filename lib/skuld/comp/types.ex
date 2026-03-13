defmodule Skuld.Comp.Types do
  @moduledoc """
  Type definitions for Skuld.Comp.

  These types define the core abstractions of the evidence-passing effect system.
  """

  @typedoc "Any result value - opaque to the framework"
  @type result :: term()

  @typedoc "Effect signature - identifies which handler handles an operation. Can be a simple atom or a tuple for tagged effects."
  @type sig :: atom() | {atom(), atom()}

  @typedoc "The environment carrying evidence, state, and leave-scope"
  @type env :: Skuld.Comp.Env.t()

  @typedoc "A handler interprets effect operations"
  @type handler :: (args :: term(), env(), k() -> {result(), env()})

  @typedoc "Continuation after an effect"
  @type k :: (term(), env() -> {result(), env()})

  @typedoc """
  A computation awaiting execution.

  The type parameter documents what the computation produces when run.
  Dialyzer erases it (it's a phantom parameter), but it appears in
  hover docs, ExDoc, and generated specs for readability.

  ## Examples

      @spec get_todo(String.t()) :: computation({:ok, Todo.t()} | {:error, term()})
      @spec get_todo!(String.t()) :: computation(Todo.t())
  """
  @type computation(_result) :: (env(), k() -> {result(), env()})
  @type computation() :: computation(term())

  @typedoc "Leave-scope handler - cleans up or redirects"
  @type leave_scope :: (result(), env() -> {result(), env()})

  @typedoc "Transform-suspend handler - decorates ExternalSuspend values when yielding"
  @type transform_suspend :: (Skuld.Comp.ExternalSuspend.t(), env() ->
                                {Skuld.Comp.ExternalSuspend.t(), env()})
end
