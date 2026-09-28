defmodule ChatchatWeb.Admin.MessageStream do
  @moduledoc false

  use GenServer

  @redis_channel "chatchat:admin:messages"
  @pubsub_topic "admin:messages"

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    with {:ok, pubsub} <- Redix.PubSub.start_link(redis_url()),
         {:ok, subscription} <- Redix.PubSub.subscribe(pubsub, @redis_channel, self()) do
      {:ok, %{pubsub: pubsub, subscription: subscription}}
    end
  end

  @impl true
  def handle_info(
        {:redix_pubsub, pubsub, subscription, :message,
         %{channel: @redis_channel, payload: payload}},
        %{pubsub: pubsub, subscription: subscription} = state
      ) do
    with {:ok, event} <- Jason.decode(payload),
         %{"message_id" => message_id, "sender_id" => sender_id, "recipient_id" => recipient_id}
         when is_binary(message_id) and is_integer(sender_id) and is_integer(recipient_id) <-
           event do
      Phoenix.PubSub.broadcast(
        ChatchatWeb.PubSub,
        @pubsub_topic,
        {:message_admitted,
         %{message_id: message_id, sender_id: sender_id, recipient_id: recipient_id}}
      )
    end

    {:noreply, state}
  end

  def handle_info({:redix_pubsub, _, _, _, _}, state), do: {:noreply, state}

  defp redis_url, do: Application.fetch_env!(:chatchat_web, :redis_url)
end
