defmodule ChatchatClient.Socket do
  alias ChatchatClient.Store

  def connect(token) do
    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: 4_097,
      send_timeout: 1_000,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(host(), port(), options, timeout()) do
      {:ok, socket} -> authenticate(socket, token)
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  def activate(socket), do: :inet.setopts(socket, active: :once)
  def request(socket, request, matcher, context \\ nil)
  def request(nil, _request, _matcher, _context), do: {:error, :disconnected}

  def request(socket, request, matcher, context) do
    with :ok <- send_frame(socket, request),
         do: receive_response(socket, matcher, context, deadline())
  end

  def send_frame(nil, _payload), do: {:error, :disconnected}

  def send_frame(socket, payload) do
    encoded = Jason.encode!(payload)

    if byte_size(encoded) <= 4_096,
      do: :gen_tcp.send(socket, encoded <> "\n"),
      else: {:error, :frame_too_large}
  end

  def handle_incoming(socket, line, context) do
    case decode(line) do
      {:ok, response} -> handle_decoded(socket, response, context)
      {:error, _reason} -> suspend_invalid(context)
    end
  end

  def close(nil), do: :ok
  def close(socket), do: :gen_tcp.close(socket)

  defp authenticate(socket, token) do
    result =
      with :ok <- send_frame(socket, %{type: "authenticate", token: token}),
           {:ok, line} <- :gen_tcp.recv(socket, 0, timeout()),
           {:ok, %{"type" => "authenticated", "user_id" => user}} <- decode(line),
           true <- is_integer(user) and user > 0 do
        {:ok, socket, user}
      else
        {:error, reason} -> {:error, {:authenticate, reason}}
        response -> {:error, {:authenticate, response}}
      end

    if match?({:error, _}, result), do: close(socket)
    result
  end

  defp receive_response(socket, matcher, context, deadline) do
    receive do
      {:tcp, ^socket, line} ->
        with {:ok, response} <- decode(line) do
          if matcher.(response) do
            with :ok <- activate(socket), do: {:ok, response}
          else
            with :ok <- handle_decoded(socket, response, context),
                 :ok <- activate(socket) do
              receive_response(socket, matcher, context, deadline)
            end
          end
        end

      {:tcp_closed, ^socket} ->
        {:error, :closed}

      {:tcp_error, ^socket, reason} ->
        {:error, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end

  defp handle_decoded(
         socket,
         %{
           "type" => "message",
           "message_id" => id,
           "from_user_id" => sender,
           "message" => payload,
           "inserted_at" => timestamp,
           "receipt_id" => receipt
         } = message,
         %{store: store, user_id: user} = context
       ) do
    with {:ok, ^receipt} <- Ecto.UUID.cast(receipt),
         {:ok, saved_or_duplicate} <-
           Store.receive_message(store, user, sender, id, payload, timestamp) do
      if saved_or_duplicate == :saved && Map.has_key?(context, :on_message),
        do: context.on_message.(message)

      send_frame(socket, %{
        type: "message_delivered_ack",
        from_user_id: sender,
        message_id: id,
        receipt_id: receipt
      })
    else
      error -> {:error, {:receive_storage, error}}
    end
  end

  defp handle_decoded(_socket, %{"type" => "message_result"} = response, %{
         on_result: callback,
         store: store,
         user_id: user
       }) do
    valid =
      match?({:ok, _}, Ecto.UUID.cast(response["request_id"])) and
        match?({:ok, _}, Ecto.UUID.cast(response["message_id"])) and
        (response["status"] == "ok" or
           (response["status"] == "failed" and response["reason"] in ["capacity", "unavailable"]) or
           (response["status"] == "rejected" and
              response["reason"] in ["invalid_request", "invalid_receiver", "identity_conflict"]))

    if valid do
      callback.(response)
      :ok
    else
      suspend_invalid(%{store: store, user_id: user})
    end
  end

  defp handle_decoded(_socket, %{"type" => "error", "error" => reason}, %{
         store: store,
         user_id: user
       }) do
    reason =
      if is_binary(reason) and byte_size(reason) <= 128, do: reason, else: "invalid_response"

    case Store.suspend(store, user, reason) do
      :ok -> {:error, {:protocol_suspended, reason}}
      error -> {:error, {:suspension_storage, error}}
    end
  end

  defp handle_decoded(_socket, %{"type" => "pong"}, _context), do: :ok
  defp handle_decoded(_socket, %{"is_online" => value}, _context) when is_boolean(value), do: :ok
  defp handle_decoded(_socket, _response, context), do: suspend_invalid(context)

  defp suspend_invalid(%{store: store, user_id: user}) do
    handle_decoded(nil, %{"type" => "error", "error" => "invalid_response"}, %{
      store: store,
      user_id: user
    })
  end

  defp suspend_invalid(_context), do: {:error, :invalid_response}

  defp decode(line) do
    if byte_size(line) <= 4_097 do
      case Jason.decode(String.trim_trailing(line, "\n")) do
        {:ok, response} when is_map(response) -> {:ok, response}
        _ -> {:error, :invalid_response}
      end
    else
      {:error, :frame_too_large}
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + timeout()
  defp host, do: Application.get_env(:chatchat_client, :tcp_host, "localhost") |> to_charlist()
  defp port, do: Application.get_env(:chatchat_client, :tcp_port, 4040)
  defp timeout, do: Application.get_env(:chatchat_client, :request_timeout, 10_000)
end
