defmodule ChatchatTcp.RequestHandler do
  alias ChatchatTcp.{MessageDelivery, Presence, Protocol}

  def handle(_user, _session, "ping", _request), do: {:reply, %{type: "pong"}}

  def handle(_user, _session, "is_online", %{"user_id" => receiver}) do
    if Protocol.user?(receiver) do
      {:reply, %{is_online: match?({:ok, _}, Presence.route(receiver))}}
    else
      {:error, "invalid_request"}
    end
  end

  def handle(user, session, "send_message", request) do
    if Protocol.uuid?(request["request_id"]) and Protocol.uuid?(request["message_id"]) do
      case MessageDelivery.submit(user, session, request) do
        {:accepted, reference} ->
          {:accepted, reference}

        {:error, :invalid_request} ->
          {:reply,
           Protocol.result(
             request["request_id"],
             request["message_id"],
             :rejected,
             :invalid_request
           )}

        {:error, reason} ->
          {:reply, Protocol.result(request["request_id"], request["message_id"], :failed, reason)}
      end
    else
      {:error, "invalid_request"}
    end
  end

  def handle(user, session, "message_delivered_ack", request),
    do: MessageDelivery.acknowledge(user, session, request)

  def handle(_user, _session, _type, _request), do: {:error, "invalid_request"}
end
