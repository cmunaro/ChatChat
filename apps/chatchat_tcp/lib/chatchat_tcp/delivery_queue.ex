defmodule ChatchatTcp.DeliveryQueue do
  @moduledoc "FIFO inbox receiver scheduling with deduplicated wakeups."
  def new, do: %{order: :queue.new(), entries: %{}}
  def size(queue), do: map_size(queue.entries)

  def put(queue, receiver) do
    if Map.has_key?(queue.entries, receiver) do
      queue
    else
      %{
        order: :queue.in(receiver, queue.order),
        entries: Map.put(queue.entries, receiver, System.monotonic_time())
      }
    end
  end

  def pop(queue) do
    case :queue.out(queue.order) do
      {:empty, _} ->
        :empty

      {{:value, receiver}, order} ->
        {queued_at, entries} = Map.pop!(queue.entries, receiver)
        {:ok, receiver, queued_at, %{order: order, entries: entries}}
    end
  end
end
