if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.ChangeEvent do
    @moduledoc """
    Generic wrapper for changeset persistence operations.

    Captures what happened (insert/update/upsert/delete) along with
    the changeset and any options for the operation.

    This follows the Decider pattern where Events are facts about what
    happened (past tense). Rather than requiring per-schema event structs,
    this provides a generic wrapper - the schema is derived from the changeset.

    ## Example

        alias Skuld.Effects.ChangeEvent

        # Create events for different operations
        insert_event = ChangeEvent.insert(user_changeset)
        update_event = ChangeEvent.update(user_changeset, returning: true)
        delete_event = ChangeEvent.delete(user_changeset)

        # Extract the schema from an event
        ChangeEvent.schema(insert_event)
        #=> MyApp.User

    ## With EventAccumulator

        alias Skuld.Effects.{EventAccumulator, ChangeEvent}

        comp do
          user_cs = User.changeset(%User{}, %{name: "Alice"})
          _ <- EventAccumulator.emit(ChangeEvent.insert(user_cs))
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Comp.run!()
        #=> {:ok, [%ChangeEvent{op: :insert, ...}]}
    """

    defstruct [:op, :changeset, :opts]

    @typedoc "Changeset operation type"
    @type op :: :insert | :update | :upsert | :delete

    @typedoc "ChangeEvent struct"
    @type t :: %__MODULE__{
            op: op(),
            changeset: Ecto.Changeset.t(),
            opts: keyword()
          }

    @doc """
    Create an insert event.

    ## Example

        ChangeEvent.insert(User.changeset(%User{}, attrs))
        ChangeEvent.insert(changeset, returning: true)
    """
    @spec insert(Ecto.Changeset.t(), keyword()) :: t()
    def insert(changeset, opts \\ []) do
      %__MODULE__{op: :insert, changeset: changeset, opts: opts}
    end

    @doc """
    Create an update event.

    ## Example

        ChangeEvent.update(User.changeset(user, attrs))
        ChangeEvent.update(changeset, force: true)
    """
    @spec update(Ecto.Changeset.t(), keyword()) :: t()
    def update(changeset, opts \\ []) do
      %__MODULE__{op: :update, changeset: changeset, opts: opts}
    end

    @doc """
    Create an upsert event.

    ## Example

        ChangeEvent.upsert(changeset, conflict_target: :email)
        ChangeEvent.upsert(changeset, on_conflict: :replace_all)
    """
    @spec upsert(Ecto.Changeset.t(), keyword()) :: t()
    def upsert(changeset, opts \\ []) do
      %__MODULE__{op: :upsert, changeset: changeset, opts: opts}
    end

    @doc """
    Create a delete event.

    ## Example

        ChangeEvent.delete(Ecto.Changeset.change(user))
        ChangeEvent.delete(changeset, stale_error_field: :id)
    """
    @spec delete(Ecto.Changeset.t(), keyword()) :: t()
    def delete(changeset, opts \\ []) do
      %__MODULE__{op: :delete, changeset: changeset, opts: opts}
    end

    @doc """
    Extract the schema module from a ChangeEvent.

    ## Example

        event = ChangeEvent.insert(User.changeset(%User{}, attrs))
        ChangeEvent.schema(event)
        #=> MyApp.User
    """
    @spec schema(t()) :: module()
    def schema(%__MODULE__{changeset: %Ecto.Changeset{data: %schema{}}}), do: schema

    @doc """
    Extract the changeset from a ChangeEvent.
    """
    @spec changeset(t()) :: Ecto.Changeset.t()
    def changeset(%__MODULE__{changeset: cs}), do: cs

    @doc """
    Extract the operation type from a ChangeEvent.
    """
    @spec op(t()) :: op()
    def op(%__MODULE__{op: op}), do: op

    @doc """
    Extract the options from a ChangeEvent.
    """
    @spec opts(t()) :: keyword()
    def opts(%__MODULE__{opts: opts}), do: opts
  end
end
