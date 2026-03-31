defmodule Skuld.Effects.Port.Repo.InMemoryTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Port
  alias Skuld.Effects.Port.Repo
  alias Skuld.Effects.Port.Repo.InMemory
  alias Skuld.Effects.Throw
  alias Skuld.Comp.Throw, as: ThrowResult

  # -------------------------------------------------------------------
  # Test Schema
  # -------------------------------------------------------------------

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email, :age])
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
    end

    def changeset(post \\ %__MODULE__{}, attrs) do
      post
      |> Ecto.Changeset.cast(attrs, [:title, :body])
    end
  end

  # -------------------------------------------------------------------
  # Helper
  # -------------------------------------------------------------------

  defp with_in_memory(comp, initial \\ InMemory.new(), opts \\ []) do
    InMemory.with_handler(comp, initial, opts)
  end

  defp with_store_output(comp, initial \\ InMemory.new()) do
    InMemory.with_handler(comp, initial,
      output: fn result, state -> {result, state.handler_state} end
    )
  end

  # -------------------------------------------------------------------
  # seed/1 and new/1
  # -------------------------------------------------------------------

  describe "seed/1" do
    test "converts list of structs to nested state map" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}

      store = InMemory.seed([alice, bob])

      assert %{User => %{1 => ^alice, 2 => ^bob}} = store
    end

    test "handles multiple schema types" do
      user = %User{id: 1, name: "Alice"}
      post = %Post{id: 1, title: "Hello"}

      store = InMemory.seed([user, post])

      assert %{User => %{1 => ^user}, Post => %{1 => ^post}} = store
    end

    test "empty list returns empty map" do
      assert %{} = InMemory.seed([])
    end
  end

  describe "new/1" do
    test "returns empty state with no options" do
      assert %{} = InMemory.new()
    end

    test "seeds records via :seed option" do
      alice = %User{id: 1, name: "Alice"}
      state = InMemory.new(seed: [alice])
      assert %{User => %{1 => ^alice}} = state
    end

    test "stores fallback_fn via :fallback_fn option" do
      fallback = fn :all, [User], _state -> [] end
      state = InMemory.new(fallback_fn: fallback)
      assert %{__fallback_fn__: ^fallback} = state
    end

    test "combines seed and fallback_fn" do
      alice = %User{id: 1, name: "Alice"}
      fallback = fn :all, [User], _state -> [alice] end
      state = InMemory.new(seed: [alice], fallback_fn: fallback)
      assert %{User => %{1 => ^alice}, __fallback_fn__: ^fallback} = state
    end
  end

  # -------------------------------------------------------------------
  # Write Operations
  # -------------------------------------------------------------------

  describe "insert" do
    test "inserts a record and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      result =
        Repo.insert(cs)
        |> with_in_memory()
        |> Comp.run!()

      assert {:ok, %User{name: "Alice", email: "alice@example.com"}} = result
    end

    test "auto-assigns id when nil" do
      cs = User.changeset(%{name: "Alice"})

      {result, store} =
        Repo.insert(cs)
        |> with_store_output()
        |> Comp.run!()

      assert {:ok, %User{id: 1, name: "Alice"}} = result
      assert %{User => %{1 => %User{id: 1, name: "Alice"}}} = store
    end

    test "preserves explicit id" do
      cs = User.changeset(%User{id: 42}, %{name: "Alice"})

      {result, store} =
        Repo.insert(cs)
        |> with_store_output()
        |> Comp.run!()

      assert {:ok, %User{id: 42, name: "Alice"}} = result
      assert %{User => %{42 => %User{id: 42}}} = store
    end

    test "auto-id increments based on existing records" do
      initial = InMemory.new(seed: [%User{id: 5, name: "Existing"}])

      {result, _store} =
        comp do
          r <- Repo.insert(User.changeset(%{name: "New"}))
          r
        end
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, %User{id: 6, name: "New"}} = result
    end

    test "insert! unwraps the result" do
      cs = User.changeset(%{name: "Alice"})

      result =
        Repo.insert!(cs)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run!()

      assert %User{name: "Alice"} = result
    end
  end

  describe "update" do
    test "updates an existing record" do
      initial = InMemory.new(seed: [%User{id: 1, name: "Alice", email: "old@example.com"}])
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{email: "new@example.com"})

      {result, store} =
        Repo.update(cs)
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, %User{id: 1, email: "new@example.com"}} = result
      assert %{User => %{1 => %User{id: 1, email: "new@example.com"}}} = store
    end

    test "update! unwraps the result" do
      initial = InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{name: "Bob"})

      result =
        Repo.update!(cs)
        |> InMemory.with_handler(initial)
        |> Throw.with_handler()
        |> Comp.run!()

      assert %User{id: 1, name: "Bob"} = result
    end
  end

  describe "delete" do
    test "removes record from store" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.new(seed: [alice])

      {result, store} =
        Repo.delete(alice)
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, ^alice} = result
      # User schema map should be empty, no fallback_fn key
      assert store == %{User => %{}}
    end

    test "delete! unwraps the result" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.new(seed: [alice])

      result =
        Repo.delete!(alice)
        |> InMemory.with_handler(initial)
        |> Throw.with_handler()
        |> Comp.run!()

      assert ^alice = result
    end
  end

  # -------------------------------------------------------------------
  # PK Read Operations (3-stage)
  # -------------------------------------------------------------------

  describe "get (3-stage)" do
    test "returns record from state when found" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.new(seed: [alice])

      result =
        Repo.get(User, 1)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end

    test "errors when not found and no fallback" do
      {result, _env} =
        Repo.get(User, 999)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :get, %ArgumentError{}}} =
               result
    end

    test "falls through to fallback when not found in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn :get, [User, 99], _state -> bob end
        )

      result =
        comp do
          a <- Repo.get(User, 1)
          b <- Repo.get(User, 99)
          {a, b}
        end
        |> with_in_memory(state)
        |> Comp.run!()

      assert {%User{id: 1, name: "Alice"}, ^bob} = result
    end
  end

  describe "get! (3-stage)" do
    test "returns record from state when found" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.new(seed: [alice])

      result =
        Repo.get!(User, 1)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end

    test "errors when not found and no fallback" do
      {result, _env} =
        Repo.get!(User, 999)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :get!, %ArgumentError{}}} =
               result
    end
  end

  # -------------------------------------------------------------------
  # Non-PK Read Operations (2-stage)
  # -------------------------------------------------------------------

  describe "non-PK reads require fallback" do
    test "get_by dispatches to fallback" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

      state =
        InMemory.new(
          fallback_fn: fn
            :get_by, [User, [name: "Alice"]], _state -> alice
            :get_by, [User, [name: "Alice", email: "alice@example.com"]], _state -> alice
            :get_by, [User, %{name: "Alice"}], _state -> alice
            :get_by, [User, [name: "Nobody"]], _state -> nil
          end
        )

      result =
        comp do
          a <- Repo.get_by(User, name: "Alice")
          b <- Repo.get_by(User, name: "Alice", email: "alice@example.com")
          c <- Repo.get_by(User, %{name: "Alice"})
          d <- Repo.get_by(User, name: "Nobody")
          {a, b, c, d}
        end
        |> with_in_memory(state)
        |> Comp.run!()

      assert {^alice, ^alice, ^alice, nil} = result
    end

    test "get_by errors without fallback" do
      {result, _env} =
        Repo.get_by(User, name: "Alice")
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :get_by, %ArgumentError{}}} =
               result
    end

    test "one dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}
      state = InMemory.new(fallback_fn: fn :one, [User], _state -> alice end)

      result =
        Repo.one(User)
        |> with_in_memory(state)
        |> Comp.run!()

      assert ^alice = result
    end

    test "one errors without fallback" do
      {result, _env} =
        Repo.one(User)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :one, %ArgumentError{}}} =
               result
    end

    test "all dispatches to fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]
      state = InMemory.new(fallback_fn: fn :all, [User], _state -> users end)

      result =
        Repo.all(User)
        |> with_in_memory(state)
        |> Comp.run!()

      assert ^users = result
    end

    test "all errors without fallback" do
      {result, _env} =
        Repo.all(User)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :all, %ArgumentError{}}} =
               result
    end

    test "exists? dispatches to fallback" do
      state = InMemory.new(fallback_fn: fn :exists?, [User], _state -> true end)

      result =
        Repo.exists?(User)
        |> with_in_memory(state)
        |> Comp.run!()

      assert result == true
    end

    test "exists? errors without fallback" do
      {result, _env} =
        Repo.exists?(User)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{
               error: {:port_handler_error, Repo.Effectful, :exists?, %ArgumentError{}}
             } =
               result
    end

    test "aggregate dispatches to fallback" do
      state =
        InMemory.new(
          fallback_fn: fn
            :aggregate, [User, :count, :id], _state -> 3
            :aggregate, [User, :sum, :age], _state -> 55
            :aggregate, [User, :min, :age], _state -> 25
            :aggregate, [User, :max, :age], _state -> 30
          end
        )

      result =
        comp do
          a <- Repo.aggregate(User, :count, :id)
          b <- Repo.aggregate(User, :sum, :age)
          c <- Repo.aggregate(User, :min, :age)
          d <- Repo.aggregate(User, :max, :age)
          {a, b, c, d}
        end
        |> with_in_memory(state)
        |> Comp.run!()

      assert {3, 55, 25, 30} = result
    end

    test "aggregate errors without fallback" do
      {result, _env} =
        Repo.aggregate(User, :count, :id)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{
               error: {:port_handler_error, Repo.Effectful, :aggregate, %ArgumentError{}}
             } =
               result
    end
  end

  # -------------------------------------------------------------------
  # Bulk Operations (2-stage)
  # -------------------------------------------------------------------

  describe "bulk operations require fallback" do
    test "delete_all dispatches to fallback" do
      state = InMemory.new(fallback_fn: fn :delete_all, [User, []], _state -> {2, nil} end)

      result =
        Repo.delete_all(User, [])
        |> with_in_memory(state)
        |> Comp.run!()

      assert {2, nil} = result
    end

    test "delete_all errors without fallback" do
      {result, _env} =
        Repo.delete_all(User, [])
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{
               error: {:port_handler_error, Repo.Effectful, :delete_all, %ArgumentError{}}
             } =
               result
    end

    test "update_all dispatches to fallback" do
      state =
        InMemory.new(
          fallback_fn: fn :update_all, [User, [set: [name: "bulk"]], []], _state -> {3, nil} end
        )

      result =
        Repo.update_all(User, [set: [name: "bulk"]], [])
        |> with_in_memory(state)
        |> Comp.run!()

      assert {3, nil} = result
    end

    test "update_all errors without fallback" do
      {result, _env} =
        Repo.update_all(User, [set: [name: "bulk"]], [])
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{
               error: {:port_handler_error, Repo.Effectful, :update_all, %ArgumentError{}}
             } =
               result
    end
  end

  # -------------------------------------------------------------------
  # Read-after-Write Consistency (PK reads)
  # -------------------------------------------------------------------

  describe "read-after-write consistency (PK reads)" do
    test "insert then get returns the same record" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      result =
        comp do
          {:ok, user} <- Repo.insert(cs)
          found <- Repo.get(User, user.id)
          {user, found}
        end
        |> with_in_memory()
        |> Comp.run!()

      {inserted, found} = result
      assert inserted == found
      assert %User{name: "Alice", email: "alice@example.com"} = found
    end

    test "insert, update, then get returns updated record" do
      result =
        comp do
          {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
          {:ok, updated} <- Repo.update(User.changeset(user, %{name: "Alicia"}))
          found <- Repo.get(User, user.id)
          {updated, found}
        end
        |> with_in_memory()
        |> Comp.run!()

      {updated, found} = result
      assert updated == found
      assert %User{name: "Alicia"} = found
    end

    test "insert then delete then get errors (no fallback)" do
      cs = User.changeset(%{name: "Alice"})

      {result, _env} =
        comp do
          {:ok, user} <- Repo.insert(cs)
          _ <- Repo.delete(user)
          Repo.get(User, user.id)
        end
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run()

      assert %ThrowResult{error: {:port_handler_error, Repo.Effectful, :get, %ArgumentError{}}} =
               result
    end
  end

  # -------------------------------------------------------------------
  # Seeded State
  # -------------------------------------------------------------------

  describe "seeded initial state" do
    test "seeded records are available via PK read" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      initial = InMemory.new(seed: [alice, bob])

      result =
        comp do
          a <- Repo.get(User, 1)
          b <- Repo.get(User, 2)
          {a, b}
        end
        |> with_in_memory(initial)
        |> Comp.run!()

      assert {^alice, ^bob} = result
    end

    test "can add to seeded state and read back by PK" do
      initial = InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      cs = User.changeset(%{name: "Bob"})

      result =
        comp do
          {:ok, bob} <- Repo.insert(cs)
          alice <- Repo.get(User, 1)
          bob_found <- Repo.get(User, bob.id)
          {alice, bob_found}
        end
        |> with_in_memory(initial)
        |> Comp.run!()

      {alice, bob_found} = result
      assert %User{name: "Alice"} = alice
      assert %User{name: "Bob"} = bob_found
    end
  end

  # -------------------------------------------------------------------
  # Logging
  # -------------------------------------------------------------------

  describe "logging" do
    test "logs write and PK read operations" do
      cs = User.changeset(%{name: "Alice"})

      {_result, log} =
        comp do
          {:ok, user} <- Repo.insert(cs)
          Repo.get(User, user.id)
        end
        |> InMemory.with_handler(InMemory.new(),
          log: true,
          output: fn result, state -> {result, state.log} end
        )
        |> Comp.run!()

      assert length(log) == 2

      assert [{Repo.Effectful, :insert, _, {:ok, %User{}}}, {Repo.Effectful, :get, _, %User{}}] =
               log
    end
  end

  # -------------------------------------------------------------------
  # Composition with Other Effects
  # -------------------------------------------------------------------

  describe "composition" do
    test "composes with State effect" do
      alias Skuld.Effects.State

      initial = InMemory.new(seed: [%User{id: 1, name: "Alice"}])

      result =
        comp do
          user <- Repo.get(User, 1)
          count <- State.get()
          _ <- State.put(count + 1)
          {user, count}
        end
        |> with_in_memory(initial)
        |> State.with_handler(0)
        |> Comp.run!()

      assert {%User{name: "Alice"}, 0} = result
    end

    test "composes with other Port contracts" do
      defmodule OtherContract do
        use HexPort.Contract

        defport(do_thing(x :: term()) :: {:ok, term()} | {:error, term()})
      end

      defmodule OtherEffectful do
        use Skuld.Effects.Port.EffectfulContract, hex_port_contract: OtherContract
      end

      defmodule OtherFacade do
        use Skuld.Effects.Port.Facade, contract: OtherEffectful
      end

      defmodule OtherImpl do
        @behaviour OtherContract

        @impl true
        def do_thing(x), do: {:ok, {:did, x}}
      end

      initial = InMemory.new(seed: [%User{id: 1, name: "Alice"}])

      result =
        comp do
          user <- Repo.get(User, 1)
          thing <- OtherFacade.do_thing!(user)
          thing
        end
        |> with_in_memory(initial)
        |> Port.with_handler(%{OtherEffectful => OtherImpl})
        |> Throw.with_handler()
        |> Comp.run!()

      assert {:did, %User{name: "Alice"}} = result
    end
  end

  # -------------------------------------------------------------------
  # Multiple Schema Types
  # -------------------------------------------------------------------

  describe "multiple schema types" do
    test "different schemas are stored independently (PK reads)" do
      result =
        comp do
          {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
          {:ok, post} <- Repo.insert(Post.changeset(%{title: "Hello"}))
          found_user <- Repo.get(User, user.id)
          found_post <- Repo.get(Post, post.id)
          {found_user, found_post}
        end
        |> with_in_memory()
        |> Comp.run!()

      {user, post} = result
      assert %User{name: "Alice"} = user
      assert %Post{title: "Hello"} = post
    end
  end
end
