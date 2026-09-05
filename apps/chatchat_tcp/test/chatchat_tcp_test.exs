defmodule ChatchatTcpTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.Presence

  test "authenticates with an HTTP access token and tracks socket presence" do
    user_id = 42
    %{access_token: token} = ChatchatAuth.issue(user_id)
    socket = connect()

    :ok = :gen_tcp.send(socket, Jason.encode!(%{type: "authenticate", token: token}) <> "\n")

    assert {:ok, response} = recv_json(socket)
    assert response == %{"type" => "authenticated", "user_id" => user_id}
    assert Presence.online?(user_id)

    :ok = :gen_tcp.close(socket)
    assert_eventually(fn -> not Presence.online?(user_id) end)
  end

  test "supports an authentication frame split across TCP packets" do
    %{access_token: token} = ChatchatAuth.issue(43)
    socket = connect()
    frame = Jason.encode!(%{type: "authenticate", token: token}) <> "\n"
    split_at = div(byte_size(frame), 2)
    <<first::binary-size(^split_at), second::binary>> = frame

    :ok = :gen_tcp.send(socket, first)
    :ok = :gen_tcp.send(socket, second)

    assert {:ok, %{"type" => "authenticated", "user_id" => 43}} = recv_json(socket)
    :ok = :gen_tcp.close(socket)
  end

  test "rejects an invalid token and closes the socket" do
    socket = connect()
    :ok = :gen_tcp.send(socket, ~s({"type":"authenticate","token":"invalid"}\n))

    assert {:ok, %{"type" => "error", "error" => "unauthorized"}} = recv_json(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "closes a socket which does not authenticate in time" do
    socket = connect()

    assert {:ok, %{"type" => "error", "error" => "authentication_timeout"}} =
             recv_json(socket)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "partial traffic does not reset the authentication deadline" do
    socket = connect()
    :ok = :gen_tcp.send(socket, ~s({"type":"authenticate"))

    assert {:ok, %{"type" => "error", "error" => "authentication_timeout"}} =
             recv_json(socket)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "rejects commands sent after authentication" do
    %{access_token: token} = ChatchatAuth.issue(44)
    socket = connect()
    :ok = :gen_tcp.send(socket, Jason.encode!(%{type: "authenticate", token: token}) <> "\n")
    assert {:ok, %{"type" => "authenticated"}} = recv_json(socket)

    :ok = :gen_tcp.send(socket, ~s({"type":"authenticate","token":"#{token}"}\n))

    assert {:ok, %{"type" => "error", "error" => "not handled"}} =
             recv_json(socket)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp connect do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", ChatchatTcp.port(), [:binary, active: false, packet: :raw])

    socket
  end

  defp recv_json(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 1_000),
         {:ok, payload} <- Jason.decode(String.trim_trailing(line, "\n")) do
      {:ok, payload}
    end
  end

  defp assert_eventually(predicate, attempts \\ 20)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not become true")
end
