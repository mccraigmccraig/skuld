defmodule Skuld.Effects.DB.EctoTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.ChangeEvent
  alias Skuld.Effects.DB
  alias Skuld.Effects.Throw

  # Test schema
  defmodule TestUser do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email])
      |> Ecto.Changeset.validate_required([:name])
    end
  end

  # Mock Repo for testing
  defmodule MockRepo do
    def insert(%Ecto.Changeset{valid?: true} = cs, _opts) do
      struct = Ecto.Changeset.apply_changes(cs)
      {:ok, %{struct | id: :rand.uniform(1000)}}
    end

    def insert(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def update(%Ecto.Changeset{valid?: true} = cs, _opts) do
      {:ok, Ecto.Changeset.apply_changes(cs)}
    end

    def update(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def insert_or_update(%Ecto.Changeset{valid?: true} = cs, _opts) do
      struct = Ecto.Changeset.apply_changes(cs)
      {:ok, %{struct | id: struct.id || :rand.uniform(1000)}}
    end

    def insert_or_update(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def delete(input, _opts) do
      struct =
        case input do
          %Ecto.Changeset{} = cs -> Ecto.Changeset.apply_changes(cs)
          %{__struct__: _} = s -> s
        end

      {:ok, struct}
    end

    def insert_all(schema, entries, opts) do
      returning = Keyword.get(opts, :returning, false)

      structs =
        if returning do
          Enum.map(entries, fn entry ->
            struct(schema, Map.put(entry, :id, :rand.uniform(1000)))
          end)
        else
          nil
        end

      {length(entries), structs}
    end

    def update_all(_query, _opts) do
      {1, nil}
    end

    # Transaction support - mirrors Ecto.Repo behaviour
    def transaction(fun, _opts) do
      try do
        result = fun.()
        {:ok, result}
      catch
        # Handle rollback throw (same pattern as Ecto.Repo)
        :throw, {:mock_rollback, value} -> {:error, value}
      end
    end

    def rollback(value) do
      throw({:mock_rollback, value})
    end
  end

  describe "single write operations" do
    test "insert with changeset" do
      cs = TestUser.changeset(%{name: "Alice", email: "alice@test.com"})

      computation =
        comp do
          user <- DB.insert(cs)
          return(user)
        end
        |> DB.Ecto.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Alice"
      assert user.email == "alice@test.com"
      assert user.id != nil
    end

    test "insert with ChangeEvent" do
      cs = TestUser.changeset(%{name: "Bob"})
      event = ChangeEvent.insert(cs)

      computation =
        comp do
          user <- DB.insert(event)
          return(user)
        end
        |> DB.Ecto.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Bob"
    end

    test "insert with invalid changeset throws" do
      cs = TestUser.changeset(%{email: "invalid@test.com"})

      computation =
        comp do
          user <- DB.insert(cs)
          return(user)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: {:invalid_changeset, _}} = result
    end

    test "insert with invalid changeset can be caught" do
      cs = TestUser.changeset(%{email: "invalid@test.com"})

      computation =
        comp do
          user <- DB.insert(cs)
          return({:ok, user})
        catch
          {Throw, {:invalid_changeset, changeset}} -> return({:error, changeset})
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> Throw.with_handler()

      {:error, changeset} = Comp.run!(computation)
      assert changeset.valid? == false
    end

    test "update with changeset" do
      user = %TestUser{id: 1, name: "Old", email: "old@test.com"}
      cs = TestUser.changeset(user, %{name: "New"})

      computation =
        comp do
          updated <- DB.update(cs)
          return(updated)
        end
        |> DB.Ecto.with_handler(MockRepo)

      updated = Comp.run!(computation)
      assert updated.name == "New"
      assert updated.id == 1
    end

    test "upsert with changeset" do
      cs = TestUser.changeset(%{name: "Upserted"})

      computation =
        comp do
          user <- DB.upsert(cs)
          return(user)
        end
        |> DB.Ecto.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Upserted"
    end

    test "delete with struct" do
      user = %TestUser{id: 1, name: "ToDelete"}

      computation =
        comp do
          result <- DB.delete(user)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {:ok, deleted} = Comp.run!(computation)
      assert deleted.id == 1
    end

    test "delete with ChangeEvent" do
      user = %TestUser{id: 1, name: "ToDelete"}
      cs = Ecto.Changeset.change(user)
      event = ChangeEvent.delete(cs)

      computation =
        comp do
          result <- DB.delete(event)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {:ok, deleted} = Comp.run!(computation)
      assert deleted.id == 1
    end
  end

  describe "bulk operations" do
    test "insert_all with changesets" do
      changesets = [
        TestUser.changeset(%{name: "User1"}),
        TestUser.changeset(%{name: "User2"}),
        TestUser.changeset(%{name: "User3"})
      ]

      computation =
        comp do
          result <- DB.insert_all(TestUser, changesets)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 3
    end

    test "insert_all with returning option" do
      changesets = [
        TestUser.changeset(%{name: "User1"}),
        TestUser.changeset(%{name: "User2"})
      ]

      computation =
        comp do
          result <- DB.insert_all(TestUser, changesets, returning: true)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, users} = Comp.run!(computation)
      assert count == 2
      assert length(users) == 2
      assert Enum.all?(users, &(&1.id != nil))
    end

    test "insert_all with ChangeEvents" do
      events = [
        ChangeEvent.insert(TestUser.changeset(%{name: "User1"})),
        ChangeEvent.insert(TestUser.changeset(%{name: "User2"}))
      ]

      computation =
        comp do
          result <- DB.insert_all(TestUser, events)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end

    test "insert_all with maps" do
      maps = [
        %{name: "User1"},
        %{name: "User2"}
      ]

      computation =
        comp do
          result <- DB.insert_all(TestUser, maps)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end

    test "insert_all with empty list" do
      computation =
        comp do
          result <- DB.insert_all(TestUser, [])
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 0
    end

    test "delete_all with structs" do
      users = [
        %TestUser{id: 1, name: "User1"},
        %TestUser{id: 2, name: "User2"}
      ]

      computation =
        comp do
          result <- DB.delete_all(TestUser, users)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end
  end

  describe "schema validation" do
    defmodule OtherSchema do
      use Ecto.Schema

      schema "other" do
        field(:value, :string)
      end

      def changeset(other \\ %__MODULE__{}, attrs) do
        Ecto.Changeset.cast(other, attrs, [:value])
      end
    end

    test "insert_all with mismatched schema throws" do
      other_cs = OtherSchema.changeset(%{value: "test"})

      computation =
        comp do
          result <- DB.insert_all(TestUser, [other_cs])
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: {:schema_mismatch, _}} = result
    end
  end

  describe "transaction operations" do
    test "transact commits on normal completion" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          result <-
            DB.transact(
              comp do
                user <- DB.insert(cs)
                return(user)
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Alice"
    end

    test "transact rolls back on explicit rollback" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          result <-
            DB.transact(
              comp do
                _user <- DB.insert(cs)
                _ <- DB.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)

      result = Comp.run!(computation)
      assert {:rolled_back, :test_reason} = result
    end

    test "transact rolls back on throw" do
      computation =
        comp do
          result <-
            DB.transact(
              comp do
                _ <- Throw.throw(:something_failed)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: :something_failed} = result
    end

    test "rollback outside transact raises" do
      computation =
        comp do
          _ <- DB.rollback(:outside_transact)
          return(:never_reached)
        end
        |> DB.Ecto.with_handler(MockRepo)

      assert_raise ArgumentError, ~r/DB\.rollback\/1 called outside of a transaction/, fn ->
        Comp.run!(computation)
      end
    end
  end

  describe "transactional state rollback" do
    alias Skuld.Effects.EventAccumulator
    alias Skuld.Effects.Writer

    test "explicit rollback restores env state to pre-transaction values" do
      computation =
        comp do
          # Emit an event before the transaction
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            DB.transact(
              comp do
                # Emit events inside the transaction
                _ <- EventAccumulator.emit(:inside_tx_1)
                _ <- EventAccumulator.emit(:inside_tx_2)
                _ <- DB.rollback(:test_reason)
                return(:never_reached)
              end
            )

          # Emit an event after rollback
          _ <- EventAccumulator.emit(:after_rollback)

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)
      assert {:rolled_back, :test_reason} = result
      # Events from inside the rolled-back transaction should be discarded
      assert events == [:before_tx, :after_rollback]
    end

    test "throw rollback restores env state to pre-transaction values" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            DB.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                _ <- Throw.throw(:something_failed)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Throw.with_handler()

      # The throw propagates through EventAccumulator's with_handler scope,
      # which runs the output function via leave_scope, producing {throw, events}.
      # Events from inside the rolled-back transaction should be discarded.
      {result, _env} = Comp.run(computation)
      assert {%Comp.Throw{error: :something_failed}, events} = result
      assert events == [:before_tx]
    end

    test "successful commit preserves env state from transaction" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            DB.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                user <- DB.insert(cs)
                return(user)
              end
            )

          _ <- EventAccumulator.emit(:after_tx)
          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {user, events} = Comp.run!(computation)
      assert user.name == "Alice"
      # Events from committed transaction should be preserved
      assert events == [:before_tx, :inside_tx, :after_tx]
    end

    test "preserve_state_on_rollback keeps specified keys on rollback" do
      metrics_key = Writer.state_key(:metrics)

      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)
          _ <- Writer.tell(:metrics, :metric_before)

          result <-
            DB.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                _ <- Writer.tell(:metrics, :metric_inside)
                _ <- DB.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo,
          preserve_state_on_rollback: [metrics_key]
        )
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Writer.with_handler([],
          tag: :metrics,
          output: fn {r, events}, metrics ->
            {r, events, Enum.reverse(metrics)}
          end
        )

      {result, events, metrics} = Comp.run!(computation)
      assert {:rolled_back, :test_reason} = result
      # EventAccumulator events rolled back (not in preserve list)
      assert events == [:before_tx]
      # Metrics preserved (in preserve list)
      assert metrics == [:metric_before, :metric_inside]
    end

    test "nested transaction rollback restores inner state only" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:outer_before)

          result <-
            DB.transact(
              comp do
                _ <- EventAccumulator.emit(:outer_inside)

                inner_result <-
                  DB.transact(
                    comp do
                      _ <- EventAccumulator.emit(:inner_tx)
                      _ <- DB.rollback(:inner_reason)
                      return(:never_reached)
                    end
                  )

                _ <- EventAccumulator.emit(:outer_after_inner)
                return({:outer_ok, inner_result})
              end
            )

          return(result)
        end
        |> DB.Ecto.with_handler(MockRepo)
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)
      assert {:outer_ok, {:rolled_back, :inner_reason}} = result
      # Inner transaction events discarded, outer preserved
      assert events == [:outer_before, :outer_inside, :outer_after_inner]
    end
  end

  describe "handler" do
    test "raises when handler not installed" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          user <- DB.insert(cs)
          return(user)
        end

      assert_raise ArgumentError, ~r/No handler installed for effect/, fn ->
        Comp.run!(computation)
      end
    end
  end
end
