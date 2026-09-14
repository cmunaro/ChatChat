defmodule ChatchatClient do
  use GenServer

  alias ChatchatClient.{Api, Socket}

  @ping_interval 30_000
  @reconnect_interval 1_000

  @spec run(binary()) :: pid()
  def run(username) when is_binary(username) do
    with :ok <- Api.register(username),
         {:ok, token} <- Api.login(username),
         {:ok, socket, user_id} <- Socket.connect(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
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

  def search(client, name: name), do: GenServer.call(client, {:search, name})

  def is_online(client, user_id) when is_integer(user_id) do
    GenServer.call(client, {:is_online, user_id})
  end

  @spec send_message(from :: pid(), to :: pid(), message :: String.t()) ::
          :ok | {:error, term()}
  def send_message(from, to, message) when is_pid(from) and is_pid(to) and is_binary(message) do
    user_id = GenServer.call(to, :user_id)
    GenServer.call(from, {:send_message, user_id, message})
  end

  @spec send_message(from :: pid(), to :: integer(), message :: String.t()) ::
          :ok | {:error, term()}
  def send_message(from, to, message)
      when is_pid(from) and is_integer(to) and is_binary(message) do
    GenServer.call(from, {:send_message, to, message})
  end

  def send_message(_, _, _), do: {:error, :invalid_params}

  @impl true
  def init(state) do
    ping()
    {:ok, state}
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
    case Socket.request(state.socket, %{type: "is_online", user_id: user_id}) do
      {:ok, %{"is_online" => online}} ->
        {:reply, {:ok, online}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, close_and_reconnect(state)}

      response ->
        {:reply, {:error, {:unexpected_response, response}}, close_and_reconnect(state)}
    end
  end

  def handle_call({:send_message, user_id, message}, _from, state) do
    {:reply, perform_send(state.socket, user_id, message), state}
  end

  @impl true
  def handle_info(:ping, state) do
    case Socket.request(state.socket, %{type: "ping"}) do
      {:ok, %{"type" => "pong"}} ->
        ping()
        {:noreply, state}

      _ ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    Socket.handle_incoming(socket, line)

    case Socket.activate(socket) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, close_and_reconnect(state)}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:noreply, close_and_reconnect(state)}

  def handle_info(:reconnect, %{socket: nil} = state) do
    with {:ok, token} <- Api.login(state.username),
         {:ok, socket, _user_id} <- Socket.connect(token),
         :ok <- Socket.activate(socket) do
      ping()
      {:noreply, %{state | token: token, socket: socket}}
    else
      _ ->
        reconnect()
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}), do: Socket.close(socket)
  def terminate(_reason, _state), do: :ok

  defp close_and_reconnect(state) do
    Socket.close(state.socket)
    reconnect()
    %{state | socket: nil}
  end

  defp perform_send(socket, user_id, message) do
    request_id = Ecto.UUID.generate()

    request = %{
      type: "send_message",
      request_id: request_id,
      user_id: user_id,
      message: message
    }

    with {:ok,
          %{
            "type" => "message_admitted",
            "request_id" => ^request_id,
            "message_id" => message_id
          }} <- Socket.request(socket, request),
         :ok <-
           Socket.send_frame(socket, %{
             type: "message_accepted_ack",
             request_id: request_id,
             message_id: message_id
           }) do
      :ok
    else
      {:ok, %{"type" => "error", "error" => error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
      response -> {:error, {:unexpected_response, response}}
    end
  end

  defp ping, do: Process.send_after(self(), :ping, @ping_interval)
  defp reconnect, do: Process.send_after(self(), :reconnect, @reconnect_interval)
end
