defmodule ChatchatClient do
  use GenServer

  alias ChatchatClient.{Api, Socket, Store}

  @ping_interval 30_000
  @reconnect_interval 1_000

  @spec run(binary()) :: pid()
  def run(username, options \\ []) when is_binary(username) do
    store = Store.handle(Keyword.get(options, :store_server, Store))

    with :ok <- Api.register(username),
         {:ok, token} <- Api.login(username),
         {:ok, socket, user_id} <- Socket.connect(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             store_server: Keyword.get(options, :store_server, Store),
             store: store,
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
    store = Store.handle(Keyword.get(options, :store_server, Store))
    token = ChatchatAuth.issue(user_id).access_token

    with {:ok, socket, ^user_id} <- Socket.connect(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             store_server: Keyword.get(options, :store_server, Store),
             store: store,
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
      Map.merge(state, %{ping_timer: nil, reconnect_timer: nil, retry_timer: nil, inflight: %{}})

    state =
      if Map.has_key?(state, :store),
        do: state,
        else: Map.put(state, :store, Store.handle(Map.get(state, :store_server, Store)))

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
           context(state)
         ) do
      {:ok, %{"is_online" => online}} ->
        {:reply, {:ok, online}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, close_and_reconnect(state)}

      response ->
        {:reply, {:error, {:unexpected_response, response}}, close_and_reconnect(state)}
    end
  end

  def handle_call({:send_message, user_id, message}, _from, state) do
    case Store.put_outbox(state.store, state.user_id, user_id, message) do
      {:ok, id} ->
        send(self(), :retry_outbox)
        {:reply, {:ok, id}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:disconnect, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast(:disconnect, state), do: {:noreply, close_and_reconnect(state)}

  @impl true
  def handle_info(:ping, state) do
    state = %{state | ping_timer: nil}
    response_matcher = &match?(%{"type" => "pong"}, &1)

    case Socket.request(state.socket, %{type: "ping"}, response_matcher, context(state)) do
      {:ok, %{"type" => "pong"}} ->
        {:noreply, schedule_ping(state)}

      _ ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case Socket.handle_incoming(socket, line, context(state)) do
      :ok ->
        case Socket.activate(socket) do
          :ok -> {:noreply, state}
          {:error, _reason} -> {:noreply, close_and_reconnect(state)}
        end

      {:error, {:protocol_suspended, _}} ->
        {:noreply, close_and_reconnect(state)}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info(:retry_outbox, state) do
    cancel_timer(state.retry_timer)
    state = %{state | retry_timer: Process.send_after(self(), :retry_outbox, 1_000)}

    if state.socket && map_size(state.inflight) < 16 do
      case Store.pending(state.store, state.user_id, 128) do
        {:ok, entries} ->
          state =
            entries
            |> Enum.reject(&Map.has_key?(state.inflight, &1.message_id))
            |> Enum.take(16 - map_size(state.inflight))
            |> Enum.reduce(state, &send_entry/2)

          {:noreply, state}

        {:error, :capacity} ->
          {:noreply, state}

        {:error, reason} ->
          {:stop, reason, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:send_timeout, id, request}, state) do
    case state.inflight[id] do
      {^request, _timer} ->
        case Store.result(state.store, state.user_id, id, request, :failed) do
          :ok -> {:noreply, %{state | inflight: Map.delete(state.inflight, id)}}
          error -> {:stop, error, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:message_result, response}, state) do
    id = response["message_id"]
    request = response["request_id"]

    status =
      case response["status"] do
        "ok" -> :ok
        "failed" -> :failed
        "rejected" -> :rejected
        _ -> nil
      end

    if status && is_binary(request) && match?({^request, _timer}, state.inflight[id]) do
      {_request, timer} = state.inflight[id]
      cancel_timer(timer)

      case Store.result(state.store, state.user_id, id, request, status, response["reason"]) do
        :ok ->
          if observer = Map.get(state, :result_observer) do
            send(observer, {:delivery_result, status})
          else
            IO.puts("#{state.username} delivery result: #{inspect(response, pretty: true)}")
          end

          {:noreply, %{state | inflight: Map.delete(state.inflight, id)}}

        error ->
          {:stop, error, state}
      end
    else
      {:noreply, state}
    end
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

    Enum.each(state.inflight, fn {id, {request, timer}} ->
      cancel_timer(timer)

      case Store.result(state.store, state.user_id, id, request, :failed) do
        :ok -> :ok
        {:error, :unmatched_result} -> :ok
        error -> exit({:outbox_storage, error})
      end
    end)

    state
    |> Map.merge(%{socket: nil, ping_timer: nil, reconnect_timer: nil, inflight: %{}})
    |> schedule_reconnect()
  end

  defp context(state) do
    owner = self()

    %{
      store: state.store,
      user_id: state.user_id,
      on_result: fn response -> send(owner, {:message_result, response}) end,
      on_message: fn message ->
        unless Map.get(state, :result_observer),
          do: IO.puts("#{state.username} received message: #{inspect(message, pretty: true)}")
      end
    }
  end

  defp send_entry(entry, state) do
    request = Ecto.UUID.generate()

    with :ok <- Store.begin_attempt(state.store, state.user_id, entry.message_id, request),
         :ok <-
           Socket.send_frame(state.socket, %{
             type: "send_message",
             request_id: request,
             message_id: entry.message_id,
             user_id: entry.receiver_id,
             message: entry.payload
           }) do
      timer = Process.send_after(self(), {:send_timeout, entry.message_id, request}, 10_000)
      %{state | inflight: Map.put(state.inflight, entry.message_id, {request, timer})}
    else
      {:error, :not_pending} -> state
      {:error, :capacity} -> state
      {:error, reason} -> exit({:send_failed, reason})
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
