defmodule ChatchatTcp.Protocol do
  @moduledoc "Validation and encoding at the authenticated TCP boundary."
  @max_frame 4_096
  @max_user 9_223_372_036_854_775_807

  def uuid?(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  def user?(value), do: is_integer(value) and value > 0 and value <= @max_user

  def validate_send(sender, request) do
    with true <- uuid?(request["request_id"]) and uuid?(request["message_id"]),
         true <- user?(sender) and user?(request["user_id"]),
         false <- Map.has_key?(request, "sender_id") or Map.has_key?(request, "from_user_id"),
         payload when is_binary(payload) <- request["message"],
         true <- String.valid?(payload) and byte_size(payload) <= @max_frame,
         {:ok, _} <-
           encode(
             delivery(
               @max_user,
               request["message_id"],
               payload,
               ~U[2026-10-09 00:00:00.000000Z],
               request["message_id"],
               if(request["type"] == "edit_message", do: "edit", else: "message")
             )
           ) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def validate_delete(sender, request) do
    if uuid?(request["request_id"]) and uuid?(request["message_id"]) and
         user?(sender) and user?(request["user_id"]) and
         not Map.has_key?(request, "sender_id") and not Map.has_key?(request, "from_user_id"),
       do: :ok,
       else: {:error, :invalid_request}
  end

  def stored_delivery(%{kind: "delete"} = message, receipt) do
    %{
      type: "message_deleted",
      from_user_id: message.sender_id,
      message_id: message.message_id,
      receipt_id: receipt
    }
  end

  def stored_delivery(message, receipt),
    do:
      delivery(
        message.sender_id,
        message.message_id,
        message.payload,
        message.inserted_at,
        receipt,
        message.kind
      )

  def delivery(sender, id, payload, timestamp, receipt, kind \\ "message") do
    %{
      type: if(kind == "edit", do: "edit_message", else: "message"),
      from_user_id: sender,
      message_id: id,
      message: payload,
      inserted_at: DateTime.to_iso8601(timestamp),
      receipt_id: receipt
    }
  end

  def encode(frame) do
    encoded = Jason.encode!(frame)

    if byte_size(encoded) <= @max_frame,
      do: {:ok, encoded <> "\n"},
      else: {:error, :invalid_request}
  end

  def result(request, message, status, reason \\ nil) do
    frame = %{type: "message_result", request_id: request, message_id: message, status: status}
    if reason, do: Map.put(frame, :reason, reason), else: frame
  end
end
