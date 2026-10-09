defmodule ChatchatTcp.DeliveryQueueTest do
  use ExUnit.Case, async: true

  alias ChatchatTcp.DeliveryQueue

  test "keeps FIFO order and deduplicates receivers" do
    queue = DeliveryQueue.new()
    queue = DeliveryQueue.put(queue, 10)
    queue = DeliveryQueue.put(queue, 11)
    queue = DeliveryQueue.put(queue, 10)

    assert DeliveryQueue.size(queue) == 2
    assert {:ok, 10, _, queue} = DeliveryQueue.pop(queue)
    assert {:ok, 11, _, queue} = DeliveryQueue.pop(queue)
    assert :empty = DeliveryQueue.pop(queue)
  end
end
