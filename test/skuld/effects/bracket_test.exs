defmodule Skuld.Effects.BracketTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Bracket
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "bracket/3" do
    test "acquires, uses, and releases resource on success" do
      # Track operations via State
      comp =
        Bracket.bracket(
          # Acquire
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:acquired | log]), fn _ ->
              Comp.pure(:resource)
            end)
          end),
          # Release
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              State.put([:released | log])
            end)
          end,
          # Use
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              Comp.bind(State.put([:used | log]), fn _ ->
                Comp.pure(:result)
              end)
            end)
          end
        )
        |> Comp.bind(fn result ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({result, Enum.reverse(log)})
          end)
        end)
        |> State.with_handler([])

      assert Comp.run!(comp) == {:result, [:acquired, :used, :released]}
    end

    test "releases resource when use throws" do
      comp =
        Bracket.bracket(
          # Acquire
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:acquired | log]), fn _ ->
              Comp.pure(:resource)
            end)
          end),
          # Release
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              State.put([:released | log])
            end)
          end,
          # Use - throws
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              Comp.bind(State.put([:used | log]), fn _ ->
                Throw.throw(:use_error)
              end)
            end)
          end
        )
        |> Throw.catch_error(fn error ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({:caught, error, Enum.reverse(log)})
          end)
        end)
        |> Throw.with_handler()
        |> State.with_handler([])

      assert Comp.run!(comp) == {:caught, :use_error, [:acquired, :used, :released]}
    end

    test "propagates release error when use succeeds" do
      comp =
        Bracket.bracket(
          Comp.pure(:resource),
          # Release throws
          fn :resource -> Throw.throw(:release_error) end,
          # Use succeeds
          fn :resource -> Comp.pure(:result) end
        )
        |> Throw.catch_error(fn error ->
          Comp.pure({:caught, error})
        end)
        |> Throw.with_handler()

      assert Comp.run!(comp) == {:caught, :release_error}
    end

    test "preserves use error when release also throws" do
      comp =
        Bracket.bracket(
          Comp.pure(:resource),
          # Release throws
          fn :resource -> Throw.throw(:release_error) end,
          # Use throws
          fn :resource -> Throw.throw(:use_error) end
        )
        |> Throw.catch_error(fn error ->
          Comp.pure({:caught, error})
        end)
        |> Throw.with_handler()

      # Original use error should be preserved, release error suppressed
      assert Comp.run!(comp) == {:caught, :use_error}
    end

    test "nested brackets release in LIFO order" do
      comp =
        Bracket.bracket(
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:outer_acquired | log]), fn _ ->
              Comp.pure(:outer)
            end)
          end),
          fn :outer ->
            Comp.bind(State.get(), fn log ->
              State.put([:outer_released | log])
            end)
          end,
          fn :outer ->
            Bracket.bracket(
              Comp.bind(State.get(), fn log ->
                Comp.bind(State.put([:inner_acquired | log]), fn _ ->
                  Comp.pure(:inner)
                end)
              end),
              fn :inner ->
                Comp.bind(State.get(), fn log ->
                  State.put([:inner_released | log])
                end)
              end,
              fn :inner ->
                Comp.bind(State.get(), fn log ->
                  Comp.bind(State.put([:both_used | log]), fn _ ->
                    Comp.pure(:result)
                  end)
                end)
              end
            )
          end
        )
        |> Comp.bind(fn result ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({result, Enum.reverse(log)})
          end)
        end)
        |> State.with_handler([])

      assert Comp.run!(comp) ==
               {:result,
                [:outer_acquired, :inner_acquired, :both_used, :inner_released, :outer_released]}
    end

    test "nested brackets release inner on inner throw" do
      comp =
        Bracket.bracket(
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:outer_acquired | log]), fn _ ->
              Comp.pure(:outer)
            end)
          end),
          fn :outer ->
            Comp.bind(State.get(), fn log ->
              State.put([:outer_released | log])
            end)
          end,
          fn :outer ->
            Bracket.bracket(
              Comp.bind(State.get(), fn log ->
                Comp.bind(State.put([:inner_acquired | log]), fn _ ->
                  Comp.pure(:inner)
                end)
              end),
              fn :inner ->
                Comp.bind(State.get(), fn log ->
                  State.put([:inner_released | log])
                end)
              end,
              fn :inner ->
                Comp.bind(State.get(), fn log ->
                  Comp.bind(State.put([:inner_used | log]), fn _ ->
                    Throw.throw(:inner_error)
                  end)
                end)
              end
            )
          end
        )
        |> Throw.catch_error(fn error ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({:caught, error, Enum.reverse(log)})
          end)
        end)
        |> Throw.with_handler()
        |> State.with_handler([])

      # Both inner and outer should be released
      assert Comp.run!(comp) ==
               {:caught, :inner_error,
                [:outer_acquired, :inner_acquired, :inner_used, :inner_released, :outer_released]}
    end
  end

  describe "bracket_/3" do
    test "works with direct resource value" do
      comp =
        Bracket.bracket_(
          :resource,
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              State.put([:released | log])
            end)
          end,
          fn :resource ->
            Comp.bind(State.get(), fn log ->
              Comp.bind(State.put([:used | log]), fn _ ->
                Comp.pure(:result)
              end)
            end)
          end
        )
        |> Comp.bind(fn result ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({result, Enum.reverse(log)})
          end)
        end)
        |> State.with_handler([])

      assert Comp.run!(comp) == {:result, [:used, :released]}
    end
  end

  describe "finally/2" do
    test "runs cleanup on success" do
      comp =
        Bracket.finally(
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:main | log]), fn _ ->
              Comp.pure(:result)
            end)
          end),
          Comp.bind(State.get(), fn log ->
            State.put([:cleanup | log])
          end)
        )
        |> Comp.bind(fn result ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({result, Enum.reverse(log)})
          end)
        end)
        |> State.with_handler([])

      assert Comp.run!(comp) == {:result, [:main, :cleanup]}
    end

    test "runs cleanup on throw" do
      comp =
        Bracket.finally(
          Comp.bind(State.get(), fn log ->
            Comp.bind(State.put([:main | log]), fn _ ->
              Throw.throw(:error)
            end)
          end),
          Comp.bind(State.get(), fn log ->
            State.put([:cleanup | log])
          end)
        )
        |> Throw.catch_error(fn error ->
          Comp.bind(State.get(), fn log ->
            Comp.pure({:caught, error, Enum.reverse(log)})
          end)
        end)
        |> Throw.with_handler()
        |> State.with_handler([])

      assert Comp.run!(comp) == {:caught, :error, [:main, :cleanup]}
    end

    test "propagates cleanup error when main succeeds" do
      comp =
        Bracket.finally(
          Comp.pure(:result),
          Throw.throw(:cleanup_error)
        )
        |> Throw.catch_error(fn error ->
          Comp.pure({:caught, error})
        end)
        |> Throw.with_handler()

      assert Comp.run!(comp) == {:caught, :cleanup_error}
    end

    test "preserves main error when cleanup also throws" do
      comp =
        Bracket.finally(
          Throw.throw(:main_error),
          Throw.throw(:cleanup_error)
        )
        |> Throw.catch_error(fn error ->
          Comp.pure({:caught, error})
        end)
        |> Throw.with_handler()

      assert Comp.run!(comp) == {:caught, :main_error}
    end
  end
end
