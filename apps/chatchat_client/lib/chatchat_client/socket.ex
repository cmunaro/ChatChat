defmodule ChatchatClient.Socket do
  def connect(token, observer \\ nil) do
    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: 4_097,
      send_timeout: 1_000,
      send_timeout_close: true
    ]

    started = System.monotonic_time(:millisecond)
    result = :gen_tcp.connect(host(), port(), options, timeout())
    record_timing(observer, :connect, started, result)

    case result do
      {:ok, socket} ->
        authenticate(socket, token, observer)

      {:error, reason} ->
        failure = if reason == :timeout, do: :connect_timeout, else: :connect_other
        record_failure(observer, failure)
        {:error, {:connect, reason}}
    end
  end

  def activate(socket), do: :inet.setopts(socket, active: :once)
  def request(nil, _request, _matcher, state), do: {:error, :disconnected, state}

  def request(socket, request, matcher, state) do
    case send_frame(socket, request) do
      :ok -> receive_response(socket, matcher, state, deadline())
      {:error, reason} -> {:error, reason, state}
    end
  end

  def send_frame(nil, _payload), do: {:error, :disconnected}

  def send_frame(socket, payload) do
    encoded = Jason.encode!(payload)

    if byte_size(encoded) <= 4_096,
      do: :gen_tcp.send(socket, encoded <> "\n"),
      else: {:error, :frame_too_large}
  end

  def handle_incoming(socket, line, state) do
    case decode(line) do
      {:ok, response} ->
        ChatchatClient.handle_response(socket, response, state)

      {:error, _reason} ->
        ChatchatClient.handle_response(
          socket,
          %{"type" => "error", "error" => "invalid_response"},
          state
        )
    end
  end

  def close(nil), do: :ok
  def close(socket), do: :gen_tcp.close(socket)

  defp authenticate(socket, token, observer) do
    started = System.monotonic_time(:millisecond)

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

    record_timing(observer, :authenticate, started, result)

    case result do
      {:error, {:authenticate, reason}} ->
        failure =
          case reason do
            :timeout ->
              :authenticate_timeout

            {:ok, %{"type" => "error", "error" => "already_connected"}} ->
              :already_connected

            {:ok, %{"type" => "error", "error" => "presence_unavailable"}} ->
              :presence_unavailable

            _ ->
              :authenticate_other
          end

        record_failure(observer, failure)

      _ ->
        :ok
    end

    if match?({:error, _}, result), do: close(socket)
    result
  end

  defp record_failure(observer, reason),
    do:
      ChatchatClient.ConnectionDiagnostics.emit(
        %{result_observer: observer},
        {:socket_failed, reason}
      )

  defp record_timing(observer, stage, started, result) do
    role =
      case {stage, result} do
        {:connect, {:ok, _}} -> :connect_ok
        {:connect, _} -> :connect_failed
        {:authenticate, {:ok, _, _}} -> :authenticate_ok
        {:authenticate, _} -> :authenticate_failed
      end

    ChatchatClient.ConnectionDiagnostics.emit_timing(
      observer,
      role,
      max(System.monotonic_time(:millisecond) - started, 0)
    )
  end

  defp receive_response(socket, matcher, state, deadline) do
    receive do
      {:tcp, ^socket, line} ->
        case decode(line) do
          {:ok, response} ->
            if matcher.(response) do
              case activate(socket) do
                :ok -> {:ok, response, state}
                {:error, reason} -> {:error, reason, state}
              end
            else
              case ChatchatClient.handle_response(socket, response, state) do
                {:ok, state} ->
                  case activate(socket) do
                    :ok -> receive_response(socket, matcher, state, deadline)
                    {:error, reason} -> {:error, reason, state}
                  end

                {:error, reason, state} ->
                  {:error, reason, state}
              end
            end

          {:error, _reason} ->
            ChatchatClient.handle_response(
              socket,
              %{"type" => "error", "error" => "invalid_response"},
              state
            )
        end

      {:tcp_closed, ^socket} ->
        {:error, :closed, state}

      {:tcp_error, ^socket, reason} ->
        {:error, reason, state}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout, state}
    end
  end

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
