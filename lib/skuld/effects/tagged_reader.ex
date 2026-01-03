defmodule Skuld.Effects.TaggedReader do
  @moduledoc """
  Tagged Reader effect - access multiple independent immutable environment values.

  Like `Reader`, but allows multiple independent reader contexts identified by tags.

  ## Example

      alias Skuld.Comp
      alias Skuld.Effects.TaggedReader

      comp do
        db_config <- TaggedReader.ask(:db)
        api_config <- TaggedReader.ask(:api)
        return({db_config, api_config})
      end
      |> TaggedReader.with_handler(:db, %{host: "localhost"})
      |> TaggedReader.with_handler(:api, %{url: "https://api.example.com"})
      |> Comp.run!()

      # => {%{host: "localhost"}, %{url: "https://api.example.com"}}
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Ask, [:tag])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Read the environment value for the given tag"
  @spec ask(atom()) :: Types.computation()
  def ask(tag) do
    Comp.effect(@sig, %Ask{tag: tag})
  end

  @doc "Read and apply a function to the environment value for the given tag"
  @spec asks(atom(), (term() -> term())) :: Types.computation()
  def asks(tag, f) do
    Comp.map(ask(tag), f)
  end

  @doc "Run a computation with a modified environment value for the given tag"
  @spec local(atom(), (term() -> term()), Types.computation()) :: Types.computation()
  def local(tag, modify, comp) do
    state_key = state_key(tag)

    Comp.scoped(comp, fn env ->
      current = Env.get_state(env, state_key)
      modified_env = Env.put_state(env, state_key, modify.(current))
      finally_k = fn value, e -> {value, Env.put_state(e, state_key, current)} end
      {modified_env, finally_k}
    end)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped TaggedReader handler for a computation with the given tag.

  Multiple TaggedReader handlers with different tags can be installed simultaneously.

  ## Example

      comp do
        db <- TaggedReader.ask(:db)
        cache <- TaggedReader.ask(:cache)
        return({db, cache})
      end
      |> TaggedReader.with_handler(:db, %{host: "db.local"})
      |> TaggedReader.with_handler(:cache, %{host: "cache.local"})
      |> Comp.run!()
  """
  @spec with_handler(Types.computation(), atom(), term()) :: Types.computation()
  def with_handler(comp, tag, value) do
    state_key = state_key(tag)

    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, state_key)
      modified = Env.put_state(env, state_key, value)

      finally_k = fn v, e ->
        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, state_key)}
            val -> Env.put_state(e, state_key, val)
          end

        {v, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Ask{tag: tag}, env, k) do
    value = Env.get_state(env, state_key(tag))
    k.(value, env)
  end

  #############################################################################
  ## Private
  #############################################################################

  defp state_key(tag), do: {__MODULE__, tag}
end
