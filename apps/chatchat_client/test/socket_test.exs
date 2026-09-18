defmodule ChatchatClient.SocketTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ChatchatClient.Socket

  test "waits for the response matching the current request" do
    {client, server} = connected_sockets()
    :ok = Socket.activate(client)

    server_task =
      Task.async(fn ->
        assert {:ok, request_line} = :gen_tcp.recv(server, 0, 1_000)
        assert %{"request_id" => "current-request"} = Jason.decode!(request_line)

        :ok = send_json(server, %{type: "error", error: "unknown_message"})

        :ok =
          send_json(server, %{
            type: "message_admitted",
            request_id: "current-request",
            message_id: "message-1"
          })
      end)

    matcher = &match?(%{"type" => "message_admitted", "request_id" => "current-request"}, &1)

    log =
      capture_log(fn ->
        assert {:ok,
                %{
                  "type" => "message_admitted",
                  "request_id" => "current-request",
                  "message_id" => "message-1"
                }} =
                 Socket.request(
                   client,
                   %{type: "send_message", request_id: "current-request"},
                   matcher
                 )
      end)

    assert log =~ "unknown_message"
    Task.await(server_task)
    :ok = Socket.close(client)
    :ok = Socket.close(server)
  end

  test "handles delivered messages while waiting for a correlated response" do
    {client, server} = connected_sockets()
    :ok = Socket.activate(client)

    server_task =
      Task.async(fn ->
        assert {:ok, _request_line} = :gen_tcp.recv(server, 0, 1_000)

        :ok =
          send_json(server, %{
            type: "message",
            message_id: "delivered-message",
            from_user_id: 42,
            message: "hello"
          })

        assert {:ok, acknowledgement_line} = :gen_tcp.recv(server, 0, 1_000)

        assert %{
                 "type" => "message_delivered_ack",
                 "message_id" => "delivered-message"
               } = Jason.decode!(acknowledgement_line)

        send_json(server, %{type: "pong"})
      end)

    assert {:ok, %{"type" => "pong"}} =
             Socket.request(client, %{type: "ping"}, &match?(%{"type" => "pong"}, &1))

    Task.await(server_task)
    :ok = Socket.close(client)
    :ok = Socket.close(server)
  end

  defp connected_sockets do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()

    accept_task =
      Task.async(fn ->
        {:ok, server} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.controlling_process(server, owner)
        {:ok, server}
      end)

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])

    {:ok, server} = Task.await(accept_task)
    :ok = :gen_tcp.close(listener)
    {client, server}
  end

  defp send_json(socket, payload), do: :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")
end
