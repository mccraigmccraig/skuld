defmodule Skuld.Effects.Reader do
  @moduledoc """
  Reader effect - access an immutable environment value.

  Supports both simple single-context usage and multiple independent contexts via tags.

  ## Simple Usage (default tag)

      use Skuld.Syntax
      alias Skuld.Effects.Reader

      comp do
        cfg <- Reader.ask()
        cfg.name
      end
      |> Reader.with_handler(%{name: "alice"})
      |> Comp.run!()
      #=> "alice"

  ## Multiple Contexts (explicit tags)

      comp do
        db <- Reader.ask(:db)
        api <- Reader.ask(:api)
        {db.host, api.url}
      end
      |> Reader.with_handler(%{host: "localhost"}, tag: :db)
      |> Reader.with_handler(%{url: "https://api.example.com"}, tag: :api)
      |> Comp.run!()
      #=> {"localhost", "https://api.example.com"}
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

  def_op(Ask, [:tag], atom_fields: [:tag])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Read the current environment value.

  ## Examples

      Reader.ask()        # use default tag
      Reader.ask(:config) # use explicit tag
  """
  @spec ask(atom()) :: Types.computation()
  def ask(tag \\ @sig) do
    Comp.effect(@sig, %Ask{tag: tag})
  end

  @doc """
  Read and apply a function to the environment value.

  ## Examples

      Reader.asks(&Map.get(&1, :name))           # use default tag
      Reader.asks(:user, &Map.get(&1, :name))    # use explicit tag
  """
  @spec asks((term() -> term())) :: Types.computation()
  def asks(f) when is_function(f, 1) do
    Comp.map(ask(), f)
  end

  @spec asks(atom(), (term() -> term())) :: Types.computation()
  def asks(tag, f) when is_atom(tag) and is_function(f, 1) do
    Comp.map(ask(tag), f)
  end

  @doc """
  Run a computation with a modified environment value.

  ## Examples

      Reader.local(&Map.put(&1, :debug, true), comp)           # use default tag
      Reader.local(:config, &Map.put(&1, :debug, true), comp)  # use explicit tag
  """
  @spec local((term() -> term()), Types.computation()) :: Types.computation()
  def local(modify, comp) when is_function(modify, 1) do
    local(@sig, modify, comp)
  end

  @spec local(atom(), (term() -> term()), Types.computation()) :: Types.computation()
  def local(tag, modify, comp) when is_atom(tag) and is_function(modify, 1) do
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
  Install a scoped Reader handler for a computation.

  ## Options

  - `tag` - the context tag (default: `Skuld.Effects.Reader`)

  ## Examples

      # Simple usage with default tag
      comp do
        cfg <- Reader.ask()
        cfg.name
      end
      |> Reader.with_handler(%{name: "alice"})
      |> Comp.run!()
      #=> "alice"

      # With explicit tag
      comp do
        db <- Reader.ask(:db)
        db.host
      end
      |> Reader.with_handler(%{host: "localhost"}, tag: :db)
      |> Comp.run!()
      #=> "localhost"

      # Multiple contexts
      comp do
        db <- Reader.ask(:db)
        cache <- Reader.ask(:cache)
        {db, cache}
      end
      |> Reader.with_handler(%{host: "db.local"}, tag: :db)
      |> Reader.with_handler(%{host: "cache.local"}, tag: :cache)
      |> Comp.run!()
      #=> {%{host: "db.local"}, %{host: "cache.local"}}
  """
  @spec with_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_handler(comp, value, opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)
    state_key = state_key(tag)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(state_key, value, scoped_opts)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Extract the context value for the given tag from an env"
  @spec get_context(Types.env(), atom()) :: term()
  def get_context(env, tag \\ @sig) do
    Env.get_state(env, state_key(tag))
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
  ## State Key Helper
  #############################################################################

  @doc """
  Returns the env.state key used for a given tag.

  Useful for configuring EffectLogger's `state_keys` filter.

  ## Examples

      # Only capture Reader context in EffectLogger snapshots
      EffectLogger.with_logging(state_keys: [Reader.state_key(:config)])

      # Multiple contexts
      EffectLogger.with_logging(state_keys: [
        Reader.state_key(:db),
        Reader.state_key(:api)
      ])
  """
  @spec state_key(atom()) :: {module(), atom()}
  def state_key(tag), do: {__MODULE__, tag}
end
