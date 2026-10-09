defmodule ChatchatTcp.Handler do
  use ThousandIsland.Handler

  alias ChatchatTcp.{Delivery, Presence, PresenceRouting, RequestHandler}
  alias ThousandIsland.Socket

  @impl ThousandIsland.Handler
  def handle_connection(_socket, options) do
    :telemetry.execute([:chatchat, :tcp, :connection, :opened], %{count: 1}, %{})

    authentication_timeout = Keyword.fetch!(options, :authentication_timeout)

    state = %{
      buffer: "",
      user_id: nil,
      presence_deadline: nil,
      session: nil,
      pending_sends: MapSet.new(),
      presence_timer: nil,
      idle_timer: nil,
      idle_deadline: nil,
      idle_timeout:
        Application.fetch_env!(:chatchat_tcp, :server) |> Keyword.fetch!(:read_timeout),
      max_frame_size: Keyword.fetch!(options, :max_frame_size),
      authentication_deadline: System.monotonic_time(:millisecond) + authentication_timeout
    }

    {:continue, state, authentication_timeout}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    state = touch_idle(state)
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

  def handle_timeout(socket, state) do
    unregister(state)
    Socket.close(socket)
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state), do: unregister(state)

  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, state), do: unregister(state)

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state), do: unregister(state)

  defp process_frames(buffer, socket, state) do
    case :binary.split(buffer, "\n") do
      [partial_data] when byte_size(partial_data) > state.max_frame_size ->
        close_with_error(socket, state, "frame_too_large")

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
    lease_deadline = System.monotonic_time(:millisecond) + PresenceRouting.heartbeat_ttl()

    with {:ok, %{"type" => "authenticate", "token" => token}} when is_binary(token) <-
           Jason.decode(frame),
         true <- token != "",
         {:ok, user_id}
         when is_integer(user_id) and user_id > 0 and user_id <= 9_223_372_036_854_775_807 <-
           ChatchatAuth.verify(token),
         {:ok, _} <- Presence.register(user_id) do
      send_json(socket, %{type: "authenticated", user_id: user_id})
      presence_timer = schedule_presence_renewal()
      Delivery.wake(user_id)
      [{_pid, route}] = Presence.get_connections(user_id)

      {:continue,
       touch_idle(%{
         state
         | user_id: user_id,
           presence_deadline: lease_deadline,
           session: route["session"],
           presence_timer: presence_timer
       })}
    else
      {:error, reason} when reason in [:already_connected, :presence_unavailable] ->
        close_with_error(socket, state, Atom.to_string(reason))

      _ ->
        close_with_error(socket, state, "unauthorized")
    end
  end

  defp process_frame(frame, socket, %{user_id: user_id} = state) do
    with true <- lease_live?(state),
         {:ok, %{"type" => type} = request} <- Jason.decode(frame) do
      result =
        if type == "send_message" and MapSet.size(state.pending_sends) >= 16 and
             ChatchatTcp.Protocol.uuid?(request["request_id"]) and
             ChatchatTcp.Protocol.uuid?(request["message_id"]) do
          {:reply,
           ChatchatTcp.Protocol.result(
             request["request_id"],
             request["message_id"],
             :failed,
             :capacity
           )}
        else
          RequestHandler.handle(user_id, state.session, type, request)
        end

      case result do
        {:accepted, reference} ->
          continue(%{state | pending_sends: MapSet.put(state.pending_sends, reference)})

        result ->
          case handle_request(socket, result) do
            :ok -> continue(state)
            {:error, reason} -> close_with_error(socket, state, reason)
          end
      end
    else
      false -> close_with_error(socket, state, "presence_unavailable")
      _ -> close_with_error(socket, state, "invalid_request")
    end
  end

  defp process_frame(_frame, socket, state) do
    close_with_error(socket, state, "invalid_request")
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

  defp handle_request(_socket, :ok), do: :ok

  defp handle_request(socket, {:reply, response}) do
    send_json(socket, response)
    :ok
  end

  defp handle_request(_socket, {:error, reason}), do: {:error, reason}

  defp unregister(%{user_id: user_id} = state) when is_integer(user_id) do
    if state.presence_timer, do: Process.cancel_timer(state.presence_timer)
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    Presence.unregister(user_id)
  end

  defp unregister(_state), do: :ok

  @impl GenServer
  def handle_info(:renew_presence, {socket, %{user_id: user_id} = state}) do
    deadline = System.monotonic_time(:millisecond) + PresenceRouting.heartbeat_ttl()

    case lease_live?(state) && Presence.renew(user_id) do
      :ok ->
        timer = schedule_presence_renewal()
        {:noreply, {socket, %{state | presence_deadline: deadline, presence_timer: timer}}}

      _ ->
        unregister(state)
        Socket.close(socket)
        {:stop, :normal, {socket, state}}
    end
  end

  def handle_info(:idle_timeout, {socket, state}) do
    if System.monotonic_time(:millisecond) >= state.idle_deadline do
      unregister(state)
      Socket.close(socket)
      {:stop, :normal, {socket, state}}
    else
      {:noreply, {socket, state}}
    end
  end

  def handle_info({:delivery_frame, session, receipt, encoded}, {socket, state}) do
    if session == state.session and lease_live?(state) and byte_size(encoded) <= 4_097 and
         ChatchatTcp.MessageDelivery.authorize_frame(state.user_id, session, receipt) do
      result = Socket.send(socket, encoded)
      ChatchatTcp.MessageDelivery.frame_consumed(receipt)

      case result do
        :ok ->
          {:noreply, {socket, state}}

        _ ->
          ChatchatTcp.MessageDelivery.release_receipt(receipt)
          unregister(state)
          {:stop, :normal, {socket, state}}
      end
    else
      ChatchatTcp.MessageDelivery.frame_consumed(receipt)
      ChatchatTcp.MessageDelivery.release_receipt(receipt)
      {:noreply, {socket, state}}
    end
  end

  def handle_info({:message_result, reference, result}, {socket, state}) do
    send_json(socket, result)
    {:noreply, {socket, %{state | pending_sends: MapSet.delete(state.pending_sends, reference)}}}
  end

  def handle_info({reference, _late_reply}, {socket, state}) when is_reference(reference),
    do: {:noreply, {socket, state}}

  defp schedule_presence_renewal do
    interval =
      Application.fetch_env!(:chatchat_tcp, :presence_routing)
      |> Keyword.fetch!(:heartbeat_interval)

    Process.send_after(self(), :renew_presence, interval)
  end

  defp touch_idle(%{user_id: nil} = state), do: state

  defp touch_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    %{
      state
      | idle_deadline: System.monotonic_time(:millisecond) + state.idle_timeout,
        idle_timer: Process.send_after(self(), :idle_timeout, state.idle_timeout)
    }
  end

  defp lease_live?(%{presence_deadline: deadline}) do
    is_integer(deadline) and System.monotonic_time(:millisecond) < deadline
  end
end
