defmodule ChatchatTcp.Handler do
  use ThousandIsland.Handler

  alias ChatchatTcp.{Delivery, Diagnostics, Presence, PresenceRouting, RequestHandler}
  alias ThousandIsland.Socket

  @impl ThousandIsland.Handler
  def handle_connection(_socket, options) do
    :telemetry.execute([:chatchat, :tcp, :connection, :opened], %{count: 1}, %{})

    authentication_timeout = Keyword.fetch!(options, :authentication_timeout)

    state = %{
      buffer: "",
      user_id: nil,
      close_reason: nil,
      presence_deadline: nil,
      presence_failures: 0,
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
    Diagnostics.connection_closed(:authentication_timeout)
    send_json(socket, %{type: "error", error: "authentication_timeout"})
    Socket.close(socket)
  end

  def handle_timeout(socket, state) do
    Diagnostics.connection_closed(:idle_timeout)
    unregister(state)
    Socket.close(socket)
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Diagnostics.connection_closed(state.close_reason || :peer_close)
    unregister(state)
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    fallback =
      if reason in [:closed, :econnreset, :etimedout, :econnaborted, :enotconn, :timeout],
        do: :socket_error,
        else: :other

    Diagnostics.connection_closed(state.close_reason || fallback)
    unregister(state)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    Diagnostics.connection_closed(state.close_reason || :shutdown)
    unregister(state)
  end

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
         {:ok, _} <- Presence.register(user_id),
         :ok <- live_deadline(lease_deadline) do
      send_json(socket, %{type: "authenticated", user_id: user_id})
      presence_timer = schedule_presence_renewal(lease_deadline)
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
        if type in ["send_message", "delete_message"] and
             (state.presence_failures > 0 or MapSet.size(state.pending_sends) >= 16) and
             ChatchatTcp.Protocol.uuid?(request["request_id"]) and
             ChatchatTcp.Protocol.uuid?(request["message_id"]) do
          {:reply,
           ChatchatTcp.Protocol.result(
             request["request_id"],
             request["message_id"],
             :failed,
             if(state.presence_failures > 0, do: :unavailable, else: :capacity)
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

    close_reason =
      cond do
        reason == "presence_unavailable" -> :presence_unavailable
        is_nil(state.user_id) -> :authentication_rejection
        true -> :protocol_error
      end

    {:close, %{state | close_reason: close_reason}}
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
    if state.presence_timer, do: Process.cancel_timer(state.presence_timer)
    deadline = System.monotonic_time(:millisecond) + PresenceRouting.heartbeat_ttl()

    with true <- lease_live?(state),
         :ok <- Presence.renew(user_id),
         true <- lease_live?(state),
         :ok <- live_deadline(deadline) do
      timer = schedule_presence_renewal(deadline)

      {:noreply,
       {socket,
        %{state | presence_deadline: deadline, presence_timer: timer, presence_failures: 0}}}
    else
      {:error, :presence_unavailable} -> retry_presence(socket, state)
      _ -> close_presence(socket, state)
    end
  end

  def handle_info(:idle_timeout, {socket, state}) do
    if System.monotonic_time(:millisecond) >= state.idle_deadline do
      unregister(state)
      Socket.close(socket)
      {:stop, :normal, {socket, %{state | close_reason: :idle_timeout}}}
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
          {:stop, :normal, {socket, %{state | close_reason: :socket_error}}}
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

  defp retry_presence(socket, state) do
    if lease_live?(state) do
      delay = PresenceRouting.retry_delay(state.presence_deadline, state.presence_failures)
      timer = Process.send_after(self(), :renew_presence, delay)

      {:noreply,
       {socket,
        %{state | presence_timer: timer, presence_failures: min(state.presence_failures + 1, 3)}}}
    else
      close_presence(socket, state)
    end
  end

  defp close_presence(socket, state) do
    unregister(state)
    Socket.close(socket)
    {:stop, :normal, {socket, %{state | close_reason: :presence_unavailable}}}
  end

  defp schedule_presence_renewal(deadline) do
    Process.send_after(self(), :renew_presence, PresenceRouting.renewal_delay(deadline))
  end

  defp live_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :presence_unavailable}
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
