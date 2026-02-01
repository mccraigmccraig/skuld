defmodule Skuld.Effects.ChannelTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  describe "basic operations" do
    test "create channel and put/take single item" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :item)
          Channel.take(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {:ok, :item} = result
    end

    test "put multiple items and take them in order" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, 1)
          _ <- Channel.put(ch, 2)
          _ <- Channel.put(ch, 3)

          r1 <- Channel.take(ch)
          r2 <- Channel.take(ch)
          r3 <- Channel.take(ch)

          {r1, r2, r3}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {{:ok, 1}, {:ok, 2}, {:ok, 3}} = result
    end

    test "peek returns item without removing it" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :item)

          p1 <- Channel.peek(ch)
          p2 <- Channel.peek(ch)
          t1 <- Channel.take(ch)

          {p1, p2, t1}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {{:ok, :item}, {:ok, :item}, {:ok, :item}} = result
    end

    test "peek on empty channel returns :empty" do
      result =
        comp do
          ch <- Channel.new(10)
          Channel.peek(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert :empty = result
    end
  end

  describe "backpressure" do
    test "put suspends when buffer is full" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(2)

          # Producer - puts more items than capacity
          producer <-
            FiberPool.submit(
              comp do
                _ <- Channel.put(ch, 1)
                _ = send(test_pid, {:put, 1})
                _ <- Channel.put(ch, 2)
                _ = send(test_pid, {:put, 2})
                # This should suspend until consumer takes
                _ <- Channel.put(ch, 3)
                _ = send(test_pid, {:put, 3})
                :producer_done
              end
            )

          # Consumer - takes items to free space
          consumer <-
            FiberPool.submit(
              comp do
                # Small delay to let producer fill buffer
                r1 <- Channel.take(ch)
                _ = send(test_pid, {:take, r1})
                r2 <- Channel.take(ch)
                _ = send(test_pid, {:take, r2})
                r3 <- Channel.take(ch)
                _ = send(test_pid, {:take, r3})
                :consumer_done
              end
            )

          FiberPool.await_all([producer, consumer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [:producer_done, :consumer_done] = result

      # Verify ordering: puts 1 and 2 happen first, then takes allow put 3
      assert_received {:put, 1}
      assert_received {:put, 2}
      # At this point buffer is full, consumer should start taking
      assert_received {:take, {:ok, 1}}
      assert_received {:put, 3}
      assert_received {:take, {:ok, 2}}
      assert_received {:take, {:ok, 3}}
    end

    test "take suspends when buffer is empty" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(10)

          # Consumer starts first on empty buffer
          consumer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :consumer_waiting)
                r <- Channel.take(ch)
                _ = send(test_pid, {:got, r})
                :consumer_done
              end
            )

          # Producer puts item later
          producer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :producer_putting)
                _ <- Channel.put(ch, :item)
                _ = send(test_pid, :producer_put)
                :producer_done
              end
            )

          FiberPool.await_all([consumer, producer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [:consumer_done, :producer_done] = result

      # Consumer should wait, then producer puts, then consumer gets
      assert_received :consumer_waiting
      assert_received :producer_putting
      assert_received :producer_put
      assert_received {:got, {:ok, :item}}
    end
  end

  describe "direct handoff" do
    test "put hands off directly to waiting taker" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(10)

          # Consumer waits on empty channel
          consumer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :consumer_waiting)
                r <- Channel.take(ch)
                _ = send(test_pid, {:consumer_got, r})
                r
              end
            )

          # Producer puts - should hand off directly
          producer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :producer_putting)
                result <- Channel.put(ch, :direct_handoff)
                _ = send(test_pid, {:producer_result, result})
                result
              end
            )

          results <- FiberPool.await_all([consumer, producer])
          # Check buffer is empty after handoff
          peek_result <- Channel.peek(ch)
          {results, peek_result}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      {[consumer_result, producer_result], peek_result} = result

      assert {:ok, :direct_handoff} = consumer_result
      assert :ok = producer_result
      # Buffer should be empty - item went directly to consumer
      assert :empty = peek_result

      assert_received :consumer_waiting
      assert_received :producer_putting
      assert_received {:producer_result, :ok}
      assert_received {:consumer_got, {:ok, :direct_handoff}}
    end

    test "take gets directly from waiting putter" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(1)

          # Fill the buffer
          _ <- Channel.put(ch, :first)

          # Producer tries to put more - should suspend
          producer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :producer_waiting)
                result <- Channel.put(ch, :from_putter)
                _ = send(test_pid, {:producer_result, result})
                result
              end
            )

          # Consumer takes - should get from buffer, then putter adds item
          consumer <-
            FiberPool.submit(
              comp do
                r1 <- Channel.take(ch)
                _ = send(test_pid, {:consumer_got_1, r1})
                r2 <- Channel.take(ch)
                _ = send(test_pid, {:consumer_got_2, r2})
                {r1, r2}
              end
            )

          FiberPool.await_all([producer, consumer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [:ok, {{:ok, :first}, {:ok, :from_putter}}] = result

      assert_received :producer_waiting
      assert_received {:consumer_got_1, {:ok, :first}}
      assert_received {:producer_result, :ok}
      assert_received {:consumer_got_2, {:ok, :from_putter}}
    end
  end

  describe "close" do
    test "close prevents new puts" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :before_close)
          _ <- Channel.close(ch)
          put_result <- Channel.put(ch, :after_close)
          take_result <- Channel.take(ch)
          {put_result, take_result}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {{:error, :closed}, {:ok, :before_close}} = result
    end

    test "take returns :closed when buffer empty and channel closed" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :item)
          _ <- Channel.close(ch)

          r1 <- Channel.take(ch)
          r2 <- Channel.take(ch)
          {r1, r2}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {{:ok, :item}, :closed} = result
    end

    test "close wakes waiting takers with :closed" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(10)

          # Consumer waits on empty channel
          consumer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :consumer_waiting)
                r <- Channel.take(ch)
                _ = send(test_pid, {:consumer_got, r})
                r
              end
            )

          # Close the channel - should wake consumer
          closer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :closing)
                _ <- Channel.close(ch)
                _ = send(test_pid, :closed)
                :closer_done
              end
            )

          FiberPool.await_all([consumer, closer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [:closed, :closer_done] = result

      assert_received :consumer_waiting
      assert_received :closing
      assert_received :closed
      assert_received {:consumer_got, :closed}
    end

    test "peek returns :closed when buffer empty and channel closed" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.close(ch)
          Channel.peek(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert :closed = result
    end

    test "close is idempotent" do
      result =
        comp do
          ch <- Channel.new(10)
          r1 <- Channel.close(ch)
          r2 <- Channel.close(ch)
          {r1, r2}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {:ok, :ok} = result
    end
  end

  describe "error propagation" do
    test "error prevents new puts" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :before_error)
          _ <- Channel.error(ch, :test_error)
          put_result <- Channel.put(ch, :after_error)
          {put_result}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {{:error, :test_error}} = result
    end

    test "error is sticky - take always returns error after error" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.put(ch, :item)
          _ <- Channel.error(ch, :sticky_error)

          r1 <- Channel.take(ch)
          r2 <- Channel.take(ch)
          r3 <- Channel.take(ch)
          {r1, r2, r3}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # All takes return the error, even though there was an item in buffer
      assert {{:error, :sticky_error}, {:error, :sticky_error}, {:error, :sticky_error}} = result
    end

    test "error wakes waiting takers with error" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(10)

          # Multiple consumers wait
          c1 <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, {:c1, :waiting})
                r <- Channel.take(ch)
                _ = send(test_pid, {:c1, :got, r})
                r
              end
            )

          c2 <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, {:c2, :waiting})
                r <- Channel.take(ch)
                _ = send(test_pid, {:c2, :got, r})
                r
              end
            )

          # Error the channel - should wake all consumers
          errorer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :erroring)
                _ <- Channel.error(ch, :propagated_error)
                _ = send(test_pid, :errored)
                :errorer_done
              end
            )

          FiberPool.await_all([c1, c2, errorer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [{:error, :propagated_error}, {:error, :propagated_error}, :errorer_done] = result

      assert_received {:c1, :waiting}
      assert_received {:c2, :waiting}
      assert_received :erroring
      assert_received :errored
      assert_received {:c1, :got, {:error, :propagated_error}}
      assert_received {:c2, :got, {:error, :propagated_error}}
    end

    test "error wakes waiting putters with error" do
      test_pid = self()

      result =
        comp do
          ch <- Channel.new(1)

          # Fill the buffer
          _ <- Channel.put(ch, :fill)

          # Putter waits
          putter <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :putter_waiting)
                r <- Channel.put(ch, :more)
                _ = send(test_pid, {:putter_got, r})
                r
              end
            )

          # Error the channel
          errorer <-
            FiberPool.submit(
              comp do
                _ = send(test_pid, :erroring)
                _ <- Channel.error(ch, :putter_error)
                _ = send(test_pid, :errored)
                :errorer_done
              end
            )

          FiberPool.await_all([putter, errorer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [{:error, :putter_error}, :errorer_done] = result

      assert_received :putter_waiting
      assert_received :erroring
      assert_received :errored
      assert_received {:putter_got, {:error, :putter_error}}
    end

    test "first error wins" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.error(ch, :first_error)
          _ <- Channel.error(ch, :second_error)
          Channel.take(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {:error, :first_error} = result
    end

    test "peek returns error" do
      result =
        comp do
          ch <- Channel.new(10)
          _ <- Channel.error(ch, :peek_error)
          Channel.peek(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {:error, :peek_error} = result
    end
  end

  describe "inspection" do
    test "closed? returns correct state" do
      result =
        comp do
          ch <- Channel.new(10)
          before <- Channel.closed?(ch)
          _ <- Channel.close(ch)
          after_close <- Channel.closed?(ch)
          {before, after_close}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {false, true} = result
    end

    test "errored? returns correct state" do
      result =
        comp do
          ch <- Channel.new(10)
          before <- Channel.errored?(ch)
          _ <- Channel.error(ch, :test)
          after_error <- Channel.errored?(ch)
          {before, after_error}
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert {false, true} = result
    end

    test "stats returns channel information" do
      result =
        comp do
          ch <- Channel.new(5)
          _ <- Channel.put(ch, 1)
          _ <- Channel.put(ch, 2)
          Channel.stats(ch)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert %{capacity: 5, buffer_size: 2, status: :open} = result
    end
  end

  describe "producer-consumer pattern" do
    test "producer sends stream of items to consumer" do
      result =
        comp do
          ch <- Channel.new(5)

          producer <-
            FiberPool.submit(
              comp do
                # Use simple recursion for iteration
                put_items(ch, 1, 10)
              end
            )

          consumer <-
            FiberPool.submit(
              comp do
                take_items(ch, [])
              end
            )

          FiberPool.await_all([producer, consumer])
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [:producer_done, items] = result
      assert items == Enum.to_list(1..10)
    end
  end

  # Helper computations for producer-consumer test
  defp put_items(ch, current, max) when current > max do
    comp do
      _ <- Channel.close(ch)
      :producer_done
    end
  end

  defp put_items(ch, current, max) do
    comp do
      _ <- Channel.put(ch, current)
      put_items(ch, current + 1, max)
    end
  end

  defp take_items(ch, acc) do
    comp do
      result <- Channel.take(ch)

      case result do
        {:ok, item} ->
          take_items(ch, acc ++ [item])

        :closed ->
          Comp.pure(acc)

        {:error, reason} ->
          Comp.pure({:error, reason, acc})
      end
    end
  end
end
