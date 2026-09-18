defmodule ChatchatTcp.Persistence do
  use GenServer

  alias ChatchatTcp.MessagePersistence

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(nil) do
    case MessagePersistence.load_script() do
      :ok ->
        send(self(), :persist)
        {:ok, nil}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info(:persist, state) do
    started_at = System.monotonic_time()
    persisted = MessagePersistence.persist_batch()
    ChatchatTcp.Telemetry.persistence_stop(started_at, persisted)
    Process.send_after(self(), :persist, MessagePersistence.next_run_in(persisted))
    {:noreply, state}
  end
end
