defmodule ChatchatWeb.Admin.MessageStream do
  @moduledoc "Local-node confirmed-result metadata. Fleet counters come from Prometheus."
  use GenServer

  @handler {__MODULE__, :results}
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok =
      :telemetry.attach(@handler, [:chatchat, :message, :result], &__MODULE__.broadcast/4, nil)

    {:ok, nil}
  end

  def broadcast(
        _event,
        _measurements,
        %{status: :ok, message_id: id, sender_id: sender, recipient_id: receiver} = metadata,
        _config
      )
      when is_binary(id) and is_integer(sender) and is_integer(receiver) do
    Phoenix.PubSub.broadcast(ChatchatWeb.PubSub, "admin:messages", {:message_result, metadata})
  end

  def broadcast(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler)
end
