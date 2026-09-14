defmodule ChatchatTcp.RequestHandler do
  alias ChatchatTcp.{Delivery, MessageAdmission, Presence}

  @spec handle(pos_integer(), binary(), map()) :: :ok | {:reply, map()} | {:error, binary()}
  def handle(_current_user_id, "is_online", %{"user_id" => user_id}) when is_integer(user_id) do
    {:reply, %{is_online: Presence.online?(user_id)}}
  end

  def handle(_current_user_id, "ping", _request), do: {:reply, %{type: "pong"}}

  def handle(
        current_user_id,
        "send_message",
        %{"request_id" => request_id, "user_id" => user_id, "message" => message}
      )
      when is_binary(request_id) and request_id != "" and byte_size(request_id) <= 128 and
             is_integer(user_id) and is_binary(message) do
    case MessageAdmission.prepare_message_sending(current_user_id, request_id, user_id, message) do
      {:ok, message_id} ->
        {:reply, %{type: "message_admitted", request_id: request_id, message_id: message_id}}

      {:error, :unavailable} ->
        {:reply, %{type: "error", error: "admission_unavailable"}}
    end
  end

  def handle(
        current_user_id,
        "message_accepted_ack",
        %{"request_id" => request_id, "message_id" => message_id}
      )
      when is_binary(request_id) and request_id != "" and is_binary(message_id) and
             message_id != "" do
    case MessageAdmission.confirm_message_id_attribution(current_user_id, request_id, message_id) do
      {:ok, ^message_id} ->
        :ok

      {:error, reason} ->
        {:reply, %{type: "error", error: reason}}
    end
  end

  def handle(
        current_user_id,
        "message_delivered_ack",
        %{"message_id" => message_id}
      )
      when is_binary(message_id) and message_id != "" do
    case Delivery.acknowledge(current_user_id, message_id) do
      :ok -> :ok
      {:error, reason} -> {:reply, %{type: "error", error: reason}}
    end
  end

  def handle(_current_user_id, _type, _request), do: {:error, "not handled"}
end
