defmodule ChatchatClient.Socket do
  require Logger

  @host ~c"localhost"
  @port 4040
  @timeout 10_000

  @spec connect(binary()) :: {:ok, port(), pos_integer()} | {:error, term()}
  def connect(token) do
    case :gen_tcp.connect(@host, @port, [:binary, active: false, packet: :line], @timeout) do
      {:ok, socket} -> authenticate(socket, token)
      error -> error
    end
  end

  @spec activate(port()) :: :ok | {:error, term()}
  def activate(socket), do: :inet.setopts(socket, active: :once)

  @spec request(port() | nil, map()) :: {:ok, map()} | {:error, term()}
  def request(nil, _request), do: {:error, :disconnected}

  def request(socket, request) do
    with :ok <- send_frame(socket, request),
         {:ok, response} <- receive_response(socket) do
      {:ok, response}
    end
  end

  @spec send_frame(port(), map()) :: :ok | {:error, term()}
  def send_frame(socket, payload), do: :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")

  @spec handle_incoming(port(), binary()) :: :ok
  def handle_incoming(socket, line) do
    case decode(line) do
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

    :ok
  end

  @spec close(port() | nil) :: :ok
  def close(nil), do: :ok
  def close(socket), do: :gen_tcp.close(socket)

  defp authenticate(socket, token) do
    result =
      with :ok <- send_frame(socket, %{type: "authenticate", token: token}),
           {:ok, %{"type" => "authenticated", "user_id" => user_id}} <- receive_frame(socket) do
        {:ok, socket, user_id}
      end

    if match?({:error, _reason}, result), do: close(socket)
    result
  end

  defp receive_response(socket) do
    receive do
      {:tcp, ^socket, line} ->
        :ok = activate(socket)

        case decode(line) do
          {:ok, %{"type" => "message"} = message} ->
            acknowledge_message(socket, message)
            receive_response(socket)

          response ->
            response
        end

      {:tcp_closed, ^socket} ->
        {:error, :closed}

      {:tcp_error, ^socket, reason} ->
        {:error, reason}
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp acknowledge_message(socket, message) do
    Logger.info("Message from #{message["from_user_id"]}: #{message["message"]}")
    send_frame(socket, %{type: "message_delivered_ack", message_id: message["message_id"]})
  end

  defp receive_frame(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout), do: decode(line)
  end

  defp decode(line), do: Jason.decode(String.trim_trailing(line, "\n"))
end
