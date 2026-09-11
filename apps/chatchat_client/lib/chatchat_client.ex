defmodule ChatchatClient do
  use GenServer
  import Bitwise
  require Logger

  @http_url "http://localhost:4000"
  @tcp_host ~c"localhost"
  @tcp_port 4040
  @password "chatchat-client-password"
  @poll_interval 250
  @ping_interval 30_000
  @reconnect_interval 1_000
  @timeout 10_000

  @spec run(binary()) :: pid()
  def run(username) when is_binary(username) do
    with :ok <- register(username),
         {:ok, token} <- login(username),
         {:ok, socket, user_id} <- open_socket(token),
         {:ok, pid} <-
           GenServer.start(__MODULE__, %{
             username: username,
             user_id: user_id,
             token: token,
             socket: socket
           }) do
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
    poll()
    ping()
    {:ok, state}
  end

  @impl true
  def handle_call({:search, name}, _from, state) do
    {:reply, search_users(state.token, name), state}
  end

  def handle_call(:user_id, _from, state), do: {:reply, state.user_id, state}

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
    request_id = uuid4()

    request = %{
      type: "send_message",
      request_id: request_id,
      user_id: user_id,
      message: message
    }

    case socket_request(state.socket, request) do
      {:ok,
       %{
         "type" => "message_admitted",
         "request_id" => ^request_id,
         "message_id" => message_id
       }} ->
        ack = %{
          type: "message_accepted_ack",
          request_id: request_id,
          message_id: message_id
        }

        case socket_request(state.socket, ack) do
          {:ok, %{"type" => "message_accepted_ack_confirmed", "message_id" => ^message_id}} ->
            {:reply, :ok, state}

          {:ok, %{"type" => "error", "error" => error}} ->
            {:reply, {:error, error}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          response ->
            {:reply, {:error, {:unexpected_response, response}}, state}
        end

      {:ok, %{"type" => "error", "error" => error}} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      response ->
        {:reply, {:error, {:unexpected_response, response}}, state}
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
        handle_incoming(socket, line)
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
      {:ok,
       %{
         "type" => "message",
         "message_id" => message_id,
         "from_user_id" => user_id,
         "message" => message
       }} ->
        Logger.info("Message from #{user_id}: #{message}")
        send_frame(socket, %{type: "message_delivered_ack", message_id: message_id})
        receive_response(socket)

      response ->
        response
    end
  end

  defp handle_incoming(socket, line) do
    case Jason.decode(String.trim_trailing(line, "\n")) do
      {:ok,
       %{
         "type" => "message",
         "message_id" => message_id,
         "from_user_id" => user_id,
         "message" => message
       }} ->
        Logger.info("Message from #{user_id}: #{message}")
        send_frame(socket, %{type: "message_delivered_ack", message_id: message_id})

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

  defp uuid4 do
    <<a::48, version, middle, variant, rest::56>> = :crypto.strong_rand_bytes(16)

    bytes =
      <<a::48, (version &&& 0x0F) ||| 0x40, middle, (variant &&& 0x3F) ||| 0x80, rest::56>>

    hex = Base.encode16(bytes, case: :lower)

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4), p5::binary>> =
      hex

    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp ping, do: Process.send_after(self(), :ping, @ping_interval)
  defp poll, do: Process.send_after(self(), :poll, @poll_interval)
  defp reconnect, do: Process.send_after(self(), :reconnect, @reconnect_interval)
end
