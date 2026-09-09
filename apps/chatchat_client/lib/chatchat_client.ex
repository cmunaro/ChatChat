defmodule ChatchatClient do
  use GenServer
  require Logger

  @http_url "http://localhost:4000"
  @tcp_host ~c"localhost"
  @tcp_port 4040
  @password "chatchat-client-password"
  @poll_interval 250
  @ping_interval 30_000
  @reconnect_interval 1_000
  @timeout 10_000

  def run(username) when is_binary(username) do
    with :ok <- register(username),
         {:ok, token} <- login(username),
         {:ok, socket, _user_id} <- open_socket(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{username: username, token: token, socket: socket}) do
      pid
    else
      {:error, reason} -> raise "could not start client: #{inspect(reason)}"
    end
  end

  def search(client, name: name), do: GenServer.call(client, {:search, name})

  def is_online(client, user_id) when is_integer(user_id) do
    GenServer.call(client, {:is_online, user_id})
  end

  def send_message(client, user_id, message) when is_integer(user_id) and is_binary(message) do
    GenServer.call(client, {:send_message, user_id, message})
  end

  @impl true
  def init(state) do
    poll()
    ping()
    {:ok, state}
  end

  @impl true
  def handle_call({:search, name}, _from, state) do
    {:reply, search_users(state.token, name), state}
  end

  def handle_call({:is_online, user_id}, _from, state) do
    case socket_request(state.socket, %{type: "is_online", user_id: user_id}) do
      {:ok, %{"is_online" => online}} ->
        {:reply, {:ok, online}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, close_and_reconnect(state)}

      response ->
        {:reply, {:error, {:unexpected_response, response}}, close_and_reconnect(state)}
    end
  end

  def handle_call({:send_message, user_id, message}, _from, state) do
    request = %{type: "send_message", user_id: user_id, message: message}

    case socket_request(state.socket, request) do
      {:ok, %{"type" => "message_sent", "delivered" => delivered}} ->
        {:reply, {:ok, delivered}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, close_and_reconnect(state)}

      response ->
        {:reply, {:error, {:unexpected_response, response}}, close_and_reconnect(state)}
    end
  end

  @impl true
  def handle_info(:ping, state) do
    case socket_request(state.socket, %{type: "ping"}) do
      {:ok, %{"type" => "pong"}} ->
        ping()
        {:noreply, state}

      _ ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info(:poll, %{socket: socket} = state) when not is_nil(socket) do
    case :gen_tcp.recv(socket, 0, 0) do
      {:ok, line} ->
        log_message(line)
        poll()
        {:noreply, state}

      {:error, :timeout} ->
        poll()
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, close_and_reconnect(state)}
    end
  end

  def handle_info(:poll, state) do
    poll()
    {:noreply, state}
  end

  def handle_info(:reconnect, %{socket: nil} = state) do
    with {:ok, token} <- login(state.username),
         {:ok, socket, _user_id} <- open_socket(token) do
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
  def terminate(_reason, %{socket: socket}) when not is_nil(socket), do: :gen_tcp.close(socket)
  def terminate(_reason, _state), do: :ok

  defp register(username) do
    case post("/api/register", %{username: username, password: @password}) do
      {:ok, 204, _body} -> :ok
      {:ok, 422, _body} -> :ok
      error -> error
    end
  end

  defp login(username) do
    with {:ok, 200, body} <- post("/api/login", %{username: username, password: @password}),
         {:ok, %{"access_token" => token}} <- Jason.decode(body) do
      {:ok, token}
    end
  end

  defp search_users(token, name) do
    query = URI.encode_query(%{name: name})
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    with {:ok, {{_version, 200, _phrase}, _headers, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist("#{@http_url}/api/user/search?#{query}"), headers},
             [timeout: @timeout],
             body_format: :binary
           ) do
      Jason.decode(body)
    end
  end

  defp post(path, payload) do
    request = {
      String.to_charlist(@http_url <> path),
      [{~c"accept", ~c"application/json"}],
      ~c"application/json",
      Jason.encode!(payload)
    }

    case :httpc.request(:post, request, [timeout: @timeout], body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, body}} -> {:ok, status, body}
      error -> error
    end
  end

  defp open_socket(token) do
    case :gen_tcp.connect(@tcp_host, @tcp_port, [:binary, active: false, packet: :line], @timeout) do
      {:ok, socket} -> authenticate(socket, token)
      error -> error
    end
  end

  defp authenticate(socket, token) do
    result =
      with :ok <- send_frame(socket, %{type: "authenticate", token: token}),
           {:ok, %{"type" => "authenticated", "user_id" => user_id}} <- receive_frame(socket) do
        {:ok, socket, user_id}
      end

    if match?({:error, _reason}, result), do: :gen_tcp.close(socket)
    result
  end

  defp socket_request(nil, _request), do: {:error, :disconnected}

  defp socket_request(socket, request) do
    with :ok <- send_frame(socket, request),
         {:ok, response} <- receive_response(socket) do
      {:ok, response}
    end
  end

  defp receive_response(socket) do
    case receive_frame(socket) do
      {:ok, %{"type" => "message", "from_user_id" => user_id, "message" => message}} ->
        Logger.info("Message from #{user_id}: #{message}")
        receive_response(socket)

      response ->
        response
    end
  end

  defp log_message(line) do
    case Jason.decode(String.trim_trailing(line, "\n")) do
      {:ok, %{"type" => "message", "from_user_id" => user_id, "message" => message}} ->
        Logger.info("Message from #{user_id}: #{message}")

      {:ok, response} ->
        Logger.warning("Unexpected response: #{inspect(response)}")

      {:error, reason} ->
        Logger.warning("Invalid response: #{inspect(reason)}")
    end
  end

  defp send_frame(socket, request) do
    :gen_tcp.send(socket, Jason.encode!(request) <> "\n")
  end

  defp receive_frame(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout),
         {:ok, response} <- Jason.decode(String.trim_trailing(line, "\n")) do
      {:ok, response}
    end
  end

  defp close_and_reconnect(state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    reconnect()
    %{state | socket: nil}
  end

  defp ping, do: Process.send_after(self(), :ping, @ping_interval)
  defp poll, do: Process.send_after(self(), :poll, @poll_interval)
  defp reconnect, do: Process.send_after(self(), :reconnect, @reconnect_interval)
end
