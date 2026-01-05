defmodule Skuld.Effects.DBTransaction.NoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.DBTransaction
  alias Skuld.Effects.DBTransaction.Noop, as: NoopTx
  alias Skuld.Effects.Throw

  describe "with_handler/1" do
    test "normal completion returns result" do
      computation =
        comp do
          x = 1 + 2
          return(x)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == 3
    end

    test "allows multiple operations before return" do
      computation =
        comp do
          a = 10
          b = 20
          return(a + b)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == 30
    end
  end

  describe "rollback/1" do
    test "returns {:rolled_back, reason}" do
      computation =
        comp do
          _ <- DBTransaction.rollback(:test_reason)
          return(:never_reached)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, :test_reason}
    end

    test "rollback with complex reason" do
      computation =
        comp do
          _ <- DBTransaction.rollback({:validation_failed, %{field: :email}})
          return(:never_reached)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, {:validation_failed, %{field: :email}}}
    end

    test "conditional rollback - rollback branch" do
      computation =
        comp do
          x = -5

          result <-
            if x < 0 do
              DBTransaction.rollback({:negative, x})
            else
              Comp.return({:ok, x})
            end

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, {:negative, -5}}
    end

    test "conditional rollback - success branch" do
      computation =
        comp do
          x = 5

          result <-
            if x < 0 do
              DBTransaction.rollback({:negative, x})
            else
              Comp.return({:ok, x})
            end

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:ok, 5}
    end
  end

  describe "interaction with Throw effect" do
    test "throw propagates through noop handler as sentinel" do
      computation =
        comp do
          _ <- Throw.throw(:error_value)
          return(:never_reached)
        end
        |> NoopTx.with_handler()
        |> Throw.with_handler()

      # Throw propagates through Noop as a sentinel
      {result, _env} = Comp.run(computation)
      assert %Skuld.Comp.Throw{error: :error_value} = result
    end

    test "catch inside comp handles throw" do
      computation =
        comp do
          _ <- Throw.throw(:caught_error)
          return(:never_reached)
        catch
          err -> return({:caught, err})
        end
        |> NoopTx.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, :caught_error}
    end

    test "catch_error inside noop catches throws" do
      computation =
        Throw.catch_error(
          comp do
            _ <- Throw.throw(:inner_error)
            return(:never_reached)
          end,
          fn err -> Comp.return({:recovered, err}) end
        )
        |> Throw.with_handler()
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:recovered, :inner_error}
    end
  end
end
