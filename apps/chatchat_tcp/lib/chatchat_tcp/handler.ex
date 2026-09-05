defmodule ChatchatTcp.Handler do
  use ThousandIsland.Handler

  alias ChatchatTcp.Presence
  alias ThousandIsland.Socket

  @impl ThousandIsland.Handler
  def handle_connection(_socket, options) do
    authentication_timeout = Keyword.fetch!(options, :authentication_timeout)

    state = %{
      buffer: "",
      user_id: nil,
      max_frame_size: Keyword.fetch!(options, :max_frame_size),
      authentication_deadline: System.monotonic_time(:millisecond) + authentication_timeout
    }

    {:continue, state, authentication_timeout}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > state.max_frame_size and not String.contains?(buffer, "\n") do
      close_with_error(socket, state, "frame_too_large")
    else
      process_frames(buffer, socket, %{state | buffer: ""})
    end
  end

  @impl ThousandIsland.Handler
  def handle_timeout(socket, %{user_id: nil}) do
    send_json(socket, %{type: "error", error: "authentication_timeout"})
    Socket.close(socket)
  end

  def handle_timeout(socket, _state) do
    Socket.close(socket)
  end

  defp process_frames(buffer, socket, state) do
    case :binary.split(buffer, "\n") do
      [partial_data] ->
        continue(%{state | buffer: partial_data})

      [frame, rest] when byte_size(frame) <= state.max_frame_size ->
        case process_frame(frame, socket, state) do
          {:continue, next_state} -> process_frames(rest, socket, next_state)
          result -> result
        end

      [_frame, _rest] ->
        close_with_error(socket, state, "frame_too_large")
    end
  end

  defp process_frame(frame, socket, %{user_id: nil} = state) do
    with {:ok, %{"type" => "authenticate", "token" => token}} when is_binary(token) <-
           Jason.decode(frame),
         true <- token != "",
         {:ok, user_id} <- ChatchatAuth.verify(token),
         {:ok, _} <- Presence.register(user_id) do
      send_json(socket, %{type: "authenticated", user_id: user_id})
      {:continue, %{state | user_id: user_id}}
    else
      _ -> close_with_error(socket, state, "unauthorized")
    end
  end

  defp process_frame(_frame, socket, state) do
    close_with_error(socket, state, "not handled")
  end

  defp continue(%{user_id: nil, authentication_deadline: deadline} = state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    {:continue, state, remaining}
  end

  defp continue(state), do: {:continue, state}

  defp close_with_error(socket, state, reason) do
    send_json(socket, %{type: "error", error: reason})
    {:close, state}
  end

  defp send_json(socket, payload) do
    Socket.send(socket, Jason.encode!(payload) <> "\n")
  end
end
