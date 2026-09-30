defmodule ChatchatTcp.DeliveryQueueTest do
  use ExUnit.Case, async: true

  alias ChatchatTcp.DeliveryQueue

  test "keeps FIFO order and deduplicates receivers" do
    queue = DeliveryQueue.new()
    queue = DeliveryQueue.put(queue, 10, :realtime)
    queue = DeliveryQueue.put(queue, 11, :realtime)
    queue = DeliveryQueue.put(queue, 10, :recovery)

    assert DeliveryQueue.size(queue) == 2
    assert {:ok, 10, :recovery, _, queue} = DeliveryQueue.pop(queue)
    assert {:ok, 11, :realtime, _, queue} = DeliveryQueue.pop(queue)
    assert :empty = DeliveryQueue.pop(queue)
  end
end
