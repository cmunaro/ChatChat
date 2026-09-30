defmodule ChatchatTcp.DeliveryQueue do
  @moduledoc "FIFO receiver scheduling with deduplication and recovery priority."

  def new, do: %{order: :queue.new(), entries: %{}}
  def size(queue), do: map_size(queue.entries)

  def put(queue, receiver, kind) do
    case queue.entries do
      %{^receiver => {existing, queued_at}} ->
        strongest = if kind == :recovery, do: :recovery, else: existing
        %{queue | entries: Map.put(queue.entries, receiver, {strongest, queued_at})}

      _ ->
        %{
          order: :queue.in(receiver, queue.order),
          entries: Map.put(queue.entries, receiver, {kind, System.monotonic_time()})
        }
    end
  end

  def pop(queue) do
    case :queue.out(queue.order) do
      {:empty, _} ->
        :empty

      {{:value, receiver}, order} ->
        {{kind, queued_at}, entries} = Map.pop!(queue.entries, receiver)
        {:ok, receiver, kind, queued_at, %{order: order, entries: entries}}
    end
  end
end
