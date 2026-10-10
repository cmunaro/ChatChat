defmodule ChatchatClient do
  use GenServer

  alias ChatchatClient.{Api, Socket, Store}

  @ping_interval 30_000
  @reconnect_interval 1_000

  @spec run(binary()) :: pid()
  def run(username, options \\ []) when is_binary(username) do
    with :ok <- Api.register(username),
         {:ok, token} <- Api.login(username),
         {:ok, socket, user_id} <- Socket.connect(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             result_observer: Keyword.get(options, :result_observer),
             username: username,
             user_id: user_id,
             token: token,
             socket: socket
           }),
         :ok <- :gen_tcp.controlling_process(socket, pid),
         :ok <- GenServer.call(pid, :activate_socket) do
      pid
    else
      {:error, reason} -> raise "could not start client: #{inspect(reason)}"
    end
  end

  @spec run_preprovisioned(binary(), pos_integer()) :: pid()
  def run_preprovisioned(username, user_id, options \\ [])
      when is_binary(username) and is_integer(user_id) and user_id > 0 do
    token = ChatchatAuth.issue(user_id).access_token

    with {:ok, socket, ^user_id} <- Socket.connect(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             result_observer: Keyword.get(options, :result_observer),
             username: username,
             user_id: user_id,
             token: token,
             socket: socket,
             preprovisioned: true
           }),
         :ok <- :gen_tcp.controlling_process(socket, pid),
         :ok <- GenServer.call(pid, :activate_socket) do
      pid
    else
      {:error, reason} -> raise "could not start preprovisioned client: #{inspect(reason)}"
    end
  end

  @spec simulate(map()) :: pid()
  def simulate(options), do: ChatchatClient.Simulator.start(options)

  @spec stop_simulation(pid()) :: :ok
  def stop_simulation(simulation), do: GenServer.stop(simulation)

  @spec simulation_status(pid()) :: map()
  def simulation_status(simulation), do: GenServer.call(simulation, :status)

  @spec start_simulation_activity(pid()) :: :ok | {:error, atom()}
  def start_simulation_activity(simulation), do: GenServer.call(simulation, :start_activity)

  @spec disconnect(pid()) :: :ok
  def disconnect(client), do: GenServer.cast(client, :disconnect)

  def outbox(client, cursor \\ "", limit \\ 128)
      when is_integer(limit) and limit > 0 and limit <= 128,
      do: GenServer.call(client, {:outbox, cursor, limit})

  def inbox(client, cursor \\ nil, limit \\ 128)
      when is_integer(limit) and limit > 0 and limit <= 128,
      do: GenServer.call(client, {:inbox, cursor, limit})

  def resume(client), do: GenServer.call(client, :resume)

  def search(client, name: name), do: GenServer.call(client, {:search, name})

  def is_online(client, user_id) when is_integer(user_id) do
    GenServer.call(client, {:is_online, user_id})
  end

  @spec send_message(from :: pid(), to :: pid(), message :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(from, to, message) when is_pid(from) and is_pid(to) and is_binary(message) do
    user_id = GenServer.call(to, :user_id, call_timeout())
    GenServer.call(from, {:send_message, user_id, message}, call_timeout())
  end

  @spec send_message(from :: pid(), to :: integer(), message :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(from, to, message)
      when is_pid(from) and is_integer(to) and is_binary(message) do
    GenServer.call(from, {:send_message, to, message}, call_timeout())
  end

  def send_message(_, _, _), do: {:error, :invalid_params}

  @impl true
  def init(state) do
    state = Map.merge(%{preprovisioned: false}, state)

    state =
      Map.merge(state, %{
        ping_timer: nil,
        reconnect_timer: nil,
        retry_timer: nil,
        inflight: %{},
        store: Store.new(state.user_id)
      })

    send(self(), :retry_outbox)
    {:ok, schedule_initial_ping(state)}
  end

  @impl true
  def handle_call({:search, name}, _from, state) do
    {:reply, Api.search(state.token, name), state}
  end

  def handle_call(:user_id, _from, state), do: {:reply, state.user_id, state}

  def handle_call(:activate_socket, _from, state) do
    {:reply, Socket.activate(state.socket), state}
  end

  def handle_call({:is_online, user_id}, _from, state) do
    response_matcher = fn response -> is_boolean(response["is_online"]) end

    case Socket.request(
           state.socket,
           %{type: "is_online", user_id: user_id},
           response_matcher,
           state
         ) do
      {:ok, %{"is_online" => online}, state} ->
        {:reply, {:ok, online}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, close_and_reconnect(state)}
    end
  end

  def handle_call({:send_message, user_id, message}, _from, state) do
    case Store.put_outbox(state.store, user_id, message) do
      {:ok, id, store} ->
        send(self(), :retry_outbox)
        {:reply, {:ok, id}, %{state | store: store}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:outbox, cursor, limit}, _from, state),
    do: {:reply, Store.outbox(state.store, cursor, limit), state}

  def handle_call({:inbox, cursor, limit}, _from, state),
    do: {:reply, Store.inbox(state.store, cursor, limit), state}

  def handle_call(:resume, _from, state),
    do: {:reply, :ok, %{state | store: Store.resume(state.store)}}

  @impl true
  def handle_cast(:disconnect, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast(:disconnect, state), do: {:noreply, close_and_reconnect(state)}

  @impl true
  def handle_info(:ping, state) do
    state = %{state | ping_timer: nil}
    response_matcher = &match?(%{"type" => "pong"}, &1)

    case Socket.request(state.socket, %{type: "ping"}, response_matcher, state) do
      {:ok, %{"type" => "pong"}, state} ->
        {:noreply, schedule_ping(state)}

      {:error, _reason, state} ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case Socket.handle_incoming(socket, line, state) do
      {:ok, state} ->
        case Socket.activate(socket) do
          :ok -> {:noreply, state}
          {:error, _reason} -> {:noreply, close_and_reconnect(state)}
        end

      {:error, {:protocol_suspended, _}, state} ->
        {:noreply, close_and_reconnect(state)}

      {:error, {:receive_storage, _} = reason, state} ->
        {:stop, reason, state}

      {:error, _reason, state} ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info(:retry_outbox, state) do
    cancel_timer(state.retry_timer)
    state = %{state | retry_timer: Process.send_after(self(), :retry_outbox, 1_000)}

    state =
      if state.socket && map_size(state.inflight) < 16 do
        state.store
        |> Store.pending()
        |> Enum.reject(&Map.has_key?(state.inflight, &1.message_id))
        |> Enum.take(16 - map_size(state.inflight))
        |> Enum.reduce(state, &send_entry/2)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:send_timeout, id, request}, state) do
    {:noreply, finish_attempt(state, id, request, :failed)}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, close_and_reconnect(state)}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:noreply, close_and_reconnect(state)}

  def handle_info({:tcp, _stale_socket, _line}, state), do: {:noreply, state}
  def handle_info({:tcp_closed, _stale_socket}, state), do: {:noreply, state}
  def handle_info({:tcp_error, _stale_socket, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{socket: nil} = state) do
    state = %{state | reconnect_timer: nil}

    with {:ok, token} <- reconnect_token(state),
         {:ok, socket, _user_id} <- Socket.connect(token),
         :ok <- Socket.activate(socket) do
      state = %{state | token: token, socket: socket}
      {:noreply, schedule_ping(state)}
    else
      _ ->
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, %{state | reconnect_timer: nil}}

  defp reconnect_token(%{preprovisioned: true, user_id: user_id}) do
    {:ok, ChatchatAuth.issue(user_id).access_token}
  end

  defp reconnect_token(state), do: Api.login(state.username)

  @impl true
  def terminate(_reason, %{socket: socket} = state) do
    cancel_timer(state.ping_timer)
    cancel_timer(state.reconnect_timer)
    cancel_timer(state.retry_timer)
    Enum.each(state.inflight, fn {_id, {_request, timer}} -> cancel_timer(timer) end)
    Socket.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  defp close_and_reconnect(state) do
    cancel_timer(state.ping_timer)
    cancel_timer(state.reconnect_timer)
    Socket.close(state.socket)

    state =
      Enum.reduce(state.inflight, state, fn {id, {request, _timer}}, state ->
        finish_attempt(state, id, request, :failed)
      end)

    state
    |> Map.merge(%{socket: nil, ping_timer: nil, reconnect_timer: nil})
    |> schedule_reconnect()
  end

  defp finish_attempt(state, id, request, status, reason \\ nil) do
    case state.inflight[id] do
      {^request, timer} ->
        cancel_timer(timer)
        {:ok, store} = Store.result(state.store, id, request, status, reason)
        %{state | store: store, inflight: Map.delete(state.inflight, id)}

      _ ->
        state
    end
  end

  def handle_response(
        socket,
        %{
          "type" => "message",
          "message_id" => id,
          "from_user_id" => sender,
          "message" => payload,
          "inserted_at" => timestamp,
          "receipt_id" => receipt
        } = message,
        state
      ) do
    with {:ok, ^receipt} <- Ecto.UUID.cast(receipt),
         {:ok, saved_or_duplicate, store} <-
           Store.receive_message(state.store, sender, id, payload, timestamp) do
      state = %{state | store: store}

      if saved_or_duplicate == :saved && !Map.get(state, :result_observer),
        do: IO.puts("#{state.username} received message: #{inspect(message, pretty: true)}")

      case Socket.send_frame(socket, %{
             type: "message_delivered_ack",
             from_user_id: sender,
             message_id: id,
             receipt_id: receipt
           }) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      error -> {:error, {:receive_storage, error}, state}
    end
  end

  def handle_response(_socket, %{"type" => "message_result"} = response, state) do
    valid =
      match?({:ok, _}, Ecto.UUID.cast(response["request_id"])) and
        match?({:ok, _}, Ecto.UUID.cast(response["message_id"])) and
        (response["status"] == "ok" or
           (response["status"] == "failed" and response["reason"] in ["capacity", "unavailable"]) or
           (response["status"] == "rejected" and
              response["reason"] in ["invalid_request", "invalid_receiver", "identity_conflict"]))

    if valid do
      id = response["message_id"]
      request = response["request_id"]

      status =
        case response["status"] do
          "ok" -> :ok
          "failed" -> :failed
          "rejected" -> :rejected
        end

      if match?({^request, _timer}, state.inflight[id]) do
        state = finish_attempt(state, id, request, status, response["reason"])

        if observer = Map.get(state, :result_observer),
          do: send(observer, {:delivery_result, status}),
          else: IO.puts("#{state.username} delivery result: #{inspect(response, pretty: true)}")

        {:ok, state}
      else
        {:ok, state}
      end
    else
      suspend(state, "invalid_response")
    end
  end

  def handle_response(_socket, %{"type" => "error", "error" => reason}, state) do
    reason =
      if is_binary(reason) and byte_size(reason) <= 128, do: reason, else: "invalid_response"

    suspend(state, reason)
  end

  def handle_response(_socket, %{"type" => "pong"}, state), do: {:ok, state}

  def handle_response(_socket, %{"is_online" => value}, state) when is_boolean(value),
    do: {:ok, state}

  def handle_response(_socket, _response, state), do: suspend(state, "invalid_response")

  defp suspend(state, reason),
    do:
      {:error, {:protocol_suspended, reason},
       %{state | store: Store.suspend(state.store, reason)}}

  defp send_entry(_entry, %{socket: nil} = state), do: state

  defp send_entry(entry, state) do
    request = Ecto.UUID.generate()

    {:ok, store} = Store.begin_attempt(state.store, entry.message_id, request)
    state = %{state | store: store}
    timer = Process.send_after(self(), {:send_timeout, entry.message_id, request}, 10_000)
    state = %{state | inflight: Map.put(state.inflight, entry.message_id, {request, timer})}

    case Socket.send_frame(state.socket, %{
           type: "send_message",
           request_id: request,
           message_id: entry.message_id,
           user_id: entry.receiver_id,
           message: entry.payload
         }) do
      :ok -> state
      {:error, _reason} -> close_and_reconnect(state)
    end
  end

  defp schedule_ping(%{ping_timer: nil} = state) do
    %{state | ping_timer: Process.send_after(self(), :ping, @ping_interval)}
  end

  defp schedule_ping(state), do: state

  defp schedule_initial_ping(%{ping_timer: nil} = state) do
    %{state | ping_timer: Process.send_after(self(), :ping, :rand.uniform(@ping_interval))}
  end

  defp schedule_reconnect(%{reconnect_timer: nil} = state) do
    %{state | reconnect_timer: Process.send_after(self(), :reconnect, @reconnect_interval)}
  end

  defp schedule_reconnect(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp call_timeout do
    Application.get_env(:chatchat_client, :request_timeout, 10_000) + 5_000
  end
end
