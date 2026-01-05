if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.EctoPersist.EctoEvent do
    @moduledoc """
    Generic wrapper for Ecto operations.

    Captures what happened (insert/update/upsert/delete) along with
    the changeset and any options for the operation.

    This follows the Decider pattern where Events are facts about what
    happened (past tense). Rather than requiring per-schema event structs,
    this provides a generic wrapper - the schema is derived from the changeset.

    ## Example

        alias Skuld.Effects.EctoPersist.EctoEvent

        # Create events for different operations
        insert_event = EctoEvent.insert(user_changeset)
        update_event = EctoEvent.update(user_changeset, returning: true)
        delete_event = EctoEvent.delete(user_changeset)

        # Extract the schema from an event
        EctoEvent.schema(insert_event)
        #=> MyApp.User

    ## With EventAccumulator

        alias Skuld.Effects.{EventAccumulator, EctoPersist.EctoEvent}

        comp do
          user_cs = User.changeset(%User{}, %{name: "Alice"})
          _ <- EventAccumulator.emit(EctoEvent.insert(user_cs))
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Comp.run!()
        #=> {:ok, [%EctoEvent{op: :insert, ...}]}
    """

    defstruct [:op, :changeset, :opts]

    @typedoc "Ecto operation type"
    @type op :: :insert | :update | :upsert | :delete

    @typedoc "EctoEvent struct"
    @type t :: %__MODULE__{
            op: op(),
            changeset: Ecto.Changeset.t(),
            opts: keyword()
          }

    @doc """
    Create an insert event.

    ## Example

        EctoEvent.insert(User.changeset(%User{}, attrs))
        EctoEvent.insert(changeset, returning: true)
    """
    @spec insert(Ecto.Changeset.t(), keyword()) :: t()
    def insert(changeset, opts \\ []) do
      %__MODULE__{op: :insert, changeset: changeset, opts: opts}
    end

    @doc """
    Create an update event.

    ## Example

        EctoEvent.update(User.changeset(user, attrs))
        EctoEvent.update(changeset, force: true)
    """
    @spec update(Ecto.Changeset.t(), keyword()) :: t()
    def update(changeset, opts \\ []) do
      %__MODULE__{op: :update, changeset: changeset, opts: opts}
    end

    @doc """
    Create an upsert event.

    ## Example

        EctoEvent.upsert(changeset, conflict_target: :email)
        EctoEvent.upsert(changeset, on_conflict: :replace_all)
    """
    @spec upsert(Ecto.Changeset.t(), keyword()) :: t()
    def upsert(changeset, opts \\ []) do
      %__MODULE__{op: :upsert, changeset: changeset, opts: opts}
    end

    @doc """
    Create a delete event.

    ## Example

        EctoEvent.delete(Ecto.Changeset.change(user))
        EctoEvent.delete(changeset, stale_error_field: :id)
    """
    @spec delete(Ecto.Changeset.t(), keyword()) :: t()
    def delete(changeset, opts \\ []) do
      %__MODULE__{op: :delete, changeset: changeset, opts: opts}
    end

    @doc """
    Extract the schema module from an EctoEvent.

    ## Example

        event = EctoEvent.insert(User.changeset(%User{}, attrs))
        EctoEvent.schema(event)
        #=> MyApp.User
    """
    @spec schema(t()) :: module()
    def schema(%__MODULE__{changeset: %Ecto.Changeset{data: %schema{}}}), do: schema

    @doc """
    Extract the changeset from an EctoEvent.
    """
    @spec changeset(t()) :: Ecto.Changeset.t()
    def changeset(%__MODULE__{changeset: cs}), do: cs

    @doc """
    Extract the operation type from an EctoEvent.
    """
    @spec op(t()) :: op()
    def op(%__MODULE__{op: op}), do: op

    @doc """
    Extract the options from an EctoEvent.
    """
    @spec opts(t()) :: keyword()
    def opts(%__MODULE__{opts: opts}), do: opts
  end
end
