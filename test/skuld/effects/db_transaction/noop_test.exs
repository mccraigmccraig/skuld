defmodule Skuld.Effects.DBTransaction.NoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.DBTransaction
  alias Skuld.Effects.DBTransaction.Noop, as: NoopTx
  alias Skuld.Effects.Throw

  describe "transact/1 with Noop handler" do
    test "normal completion returns result" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                x = 1 + 2
                return(x)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == 3
    end

    test "allows multiple operations before return" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                a = 10
                b = 20
                return(a + b)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == 30
    end

    test "operations outside transact work normally" do
      computation =
        comp do
          x = 5

          result <-
            DBTransaction.transact(
              comp do
                return(x * 2)
              end
            )

          return(result + 1)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == 11
    end
  end

  describe "rollback/1 inside transact" do
    test "returns {:rolled_back, reason}" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                _ <- DBTransaction.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, :test_reason}
    end

    test "rollback with complex reason" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                _ <- DBTransaction.rollback({:validation_failed, %{field: :email}})
                return(:never_reached)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, {:validation_failed, %{field: :email}}}
    end

    test "conditional rollback - rollback branch" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                x = -5

                inner_result <-
                  if x < 0 do
                    DBTransaction.rollback({:negative, x})
                  else
                    Comp.return({:ok, x})
                  end

                return(inner_result)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:rolled_back, {:negative, -5}}
    end

    test "conditional rollback - success branch" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                x = 5

                inner_result <-
                  if x < 0 do
                    DBTransaction.rollback({:negative, x})
                  else
                    Comp.return({:ok, x})
                  end

                return(inner_result)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:ok, 5}
    end
  end

  describe "rollback/1 outside transact" do
    test "raises error when called outside transact" do
      computation =
        comp do
          _ <- DBTransaction.rollback(:outside_transact)
          return(:never_reached)
        end
        |> NoopTx.with_handler()

      # The ArgumentError from the handler is wrapped in a RuntimeError by Comp.run!
      error =
        assert_raise RuntimeError, fn ->
          Comp.run!(computation)
        end

      # Verify the error message contains the expected text
      assert error.message =~ "outside of a transaction"
      assert error.message =~ "ArgumentError"
    end
  end

  describe "nested transact" do
    test "nested transact calls work" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                x = 10

                inner_result <-
                  DBTransaction.transact(
                    comp do
                      return(x * 2)
                    end
                  )

                return({:outer, inner_result})
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:outer, 20}
    end

    test "inner rollback only affects inner transact" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                inner_result <-
                  DBTransaction.transact(
                    comp do
                      _ <- DBTransaction.rollback(:inner_rollback)
                      return(:never_reached)
                    end
                  )

                return({:outer_completed, inner_result})
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()

      assert Comp.run!(computation) == {:outer_completed, {:rolled_back, :inner_rollback}}
    end
  end

  describe "interaction with Throw effect" do
    test "throw inside transact propagates as sentinel" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                _ <- Throw.throw(:error_value)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()
        |> Throw.with_handler()

      # Throw propagates through Noop as a sentinel
      {result, _env} = Comp.run(computation)
      assert %Skuld.Comp.Throw{error: :error_value} = result
    end

    test "catch inside transact handles throw" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              comp do
                _ <- Throw.throw(:caught_error)
                return(:never_reached)
              catch
                err -> return({:caught, err})
              end
            )

          return(result)
        end
        |> NoopTx.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, :caught_error}
    end

    test "catch_error inside transact catches throws" do
      computation =
        comp do
          result <-
            DBTransaction.transact(
              Throw.catch_error(
                comp do
                  _ <- Throw.throw(:inner_error)
                  return(:never_reached)
                end,
                fn err -> Comp.return({:recovered, err}) end
              )
            )

          return(result)
        end
        |> NoopTx.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:recovered, :inner_error}
    end
  end
end
