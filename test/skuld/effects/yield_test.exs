defmodule Skuld.Effects.YieldTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.{Yield, State, Reader, Throw}

  describe "yield" do
    test "suspends computation" do
      comp = Yield.yield(:hello)

      {result, _env} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      assert %Comp.Suspend{value: :hello, resume: resume} = result
      assert is_function(resume, 1)
    end

    test "resume continues computation" do
      comp =
        Comp.bind(Yield.yield(:first), fn x ->
          Comp.pure({:got, x})
        end)

      {%Comp.Suspend{value: :first, resume: resume}, _suspended_env} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      assert {{:got, :input_value}, _} = resume.(:input_value)
    end

    test "multiple yields" do
      comp =
        Comp.bind(Yield.yield(1), fn a ->
          Comp.bind(Yield.yield(2), fn b ->
            Comp.bind(Yield.yield(3), fn c ->
              Comp.pure(a + b + c)
            end)
          end)
        end)

      {%Comp.Suspend{value: 1, resume: r1}, _e1} =
        comp
        |> Yield.with_handler()
        |> Comp.run()

      {%Comp.Suspend{value: 2, resume: r2}, _e2} = r1.(10)
      {%Comp.Suspend{value: 3, resume: r3}, _e3} = r2.(20)
      # 10 + 20 + 30
      {60, _} = r3.(30)
    end
  end

  describe "collect" do
    test "gathers all yields" do
      comp =
        Comp.bind(Yield.yield(:a), fn _ ->
          Comp.bind(Yield.yield(:b), fn _ ->
            Comp.bind(Yield.yield(:c), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)
        |> Yield.with_handler()

      assert {:done, :done, [:a, :b, :c], _} = Yield.collect(comp)
    end
  end

  describe "feed" do
    test "provides inputs to yields" do
      comp =
        Comp.bind(Yield.yield(:want_x), fn x ->
          Comp.bind(Yield.yield(:want_y), fn y ->
            Comp.pure(x * y)
          end)
        end)
        |> Yield.with_handler()

      assert {:done, 12, [:want_x, :want_y], _} = Yield.feed(comp, [3, 4])
    end

    test "stops when inputs exhausted" do
      comp =
        Comp.bind(Yield.yield(1), fn _ ->
          Comp.bind(Yield.yield(2), fn _ ->
            Comp.bind(Yield.yield(3), fn _ ->
              Comp.pure(:done)
            end)
          end)
        end)
        |> Yield.with_handler()

      {:suspended, 2, _resume, [1], _env} = Yield.feed(comp, [:a])
    end
  end

  describe "respond" do
    test "handles single yield" do
      result =
        comp do
          Yield.respond(
            comp do
              x <- Yield.yield(:get_value)
              x * 2
            end,
            fn :get_value -> Comp.pure(21) end
          )
        end
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "handles multiple yields" do
      result =
        comp do
          Yield.respond(
            comp do
              x <- Yield.yield(:get_x)
              y <- Yield.yield(:get_y)
              x + y
            end,
            fn
              :get_x -> Comp.pure(10)
              :get_y -> Comp.pure(20)
            end
          )
        end
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == 30
    end

    test "responder can use State effect" do
      result =
        comp do
          Yield.respond(
            comp do
              x <- Yield.yield(:get_state)
              _ <- Yield.yield({:add, 10})
              y <- Yield.yield(:get_state)
              {x, y}
            end,
            fn
              :get_state -> State.get()
              {:add, n} -> State.modify(&(&1 + n))
            end
          )
        end
        |> State.with_handler(5)
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == {5, 15}
    end

    test "responder can use Reader effect" do
      result =
        comp do
          Yield.respond(
            comp do
              x <- Yield.yield(:get_config)
              x * 2
            end,
            fn :get_config -> Reader.ask() end
          )
        end
        |> Reader.with_handler(21)
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "unhandled yields propagate to outer handler (re-yield)" do
      {result, _env} =
        comp do
          Yield.respond(
            comp do
              x <- Yield.yield(:handled)
              y <- Yield.yield(:not_handled)
              x + y
            end,
            fn
              :handled -> Comp.pure(10)
              other -> Yield.yield(other)
            end
          )
        end
        |> Yield.with_handler()
        |> Comp.run()

      # Should suspend on :not_handled
      assert %Comp.Suspend{value: :not_handled, resume: resume} = result

      # Resume should complete the computation
      {final, _} = resume.(20)
      assert final == 30
    end

    test "inner computation throwing propagates" do
      {result, _env} =
        comp do
          Yield.respond(
            comp do
              _ <- Yield.yield(:before_throw)
              _ <- Throw.throw(:inner_error)
              Yield.yield(:after_throw)
            end,
            fn _ -> Comp.pure(:ok) end
          )
        end
        |> Yield.with_handler()
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: :inner_error} = result
    end

    test "responder throwing propagates" do
      {result, _env} =
        comp do
          Yield.respond(
            comp do
              Yield.yield(:trigger_throw)
            end,
            fn :trigger_throw -> Throw.throw(:responder_error) end
          )
        end
        |> Yield.with_handler()
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: :responder_error} = result
    end

    test "no yields passes through" do
      result =
        comp do
          Yield.respond(
            comp do
              42
            end,
            fn _ -> Comp.pure(:should_not_be_called) end
          )
        end
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "nested respond" do
      result =
        comp do
          Yield.respond(
            comp do
              Yield.respond(
                comp do
                  x <- Yield.yield(:inner)
                  y <- Yield.yield(:outer)
                  x + y
                end,
                fn
                  :inner -> Comp.pure(10)
                  other -> Yield.yield(other)
                end
              )
            end,
            fn :outer -> Comp.pure(20) end
          )
        end
        |> Yield.with_handler()
        |> Comp.run!()

      assert result == 30
    end
  end
end
