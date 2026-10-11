defmodule ChatchatTcp.ClusterDeliveryTest do
  use ExUnit.Case, async: false

  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.{MessagesStore, Schemas.Message, Schemas.User}

  setup do
    unless Node.alive?(), do: {:ok, _} = Node.start(:"chatchat_tests@127.0.0.1", :longnames)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    users =
      for _ <- 1..2,
          do: Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"})

    arguments =
      [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())] ++
        Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, remote} =
      :peer.start(%{
        name: :chatchat_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: arguments
      })

    for application <- [:chatchat_broker, :chatchat_tcp, :chatchat_auth, :logger],
        {key, value} <- Application.get_all_env(application) do
      :ok = :peer.call(peer, Application, :put_env, [application, key, value, [persistent: true]])
    end

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:chatchat_tcp])
    :ok = :peer.call(peer, Ecto.Adapters.SQL.Sandbox, :mode, [Repo, :auto])
    assert Node.connect(remote)
    port = :peer.call(peer, ChatchatTcp, :port, [])

    on_exit(fn ->
      if Process.alive?(peer), do: :peer.stop(peer)
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Enum.each(users, &Repo.delete!/1) end)
    end)

    [sender, receiver] = users
    %{peer: peer, remote: remote, port: port, sender: sender, receiver: receiver}
  end

  test "cross-node online receipt returns ok without a message write", context do
    from = connect(context.sender.id, ChatchatTcp.port())
    to = connect(context.receiver.id, context.port)
    request = request(context.receiver.id)
    send_json(from, request)
    assert {:ok, frame} = recv(to)

    send_json(to, %{
      type: "message_delivered_ack",
      message_id: frame["message_id"],
      from_user_id: frame["from_user_id"],
      receipt_id: frame["receipt_id"]
    })

    assert {:ok, %{"status" => "ok"}} = recv(from)

    assert Repo.get_by(Message, sender_id: context.sender.id, message_id: request.message_id) ==
             nil

    assert {:ok, nil} =
             Redix.command(ChatchatTcp.Redis.Heartbeat, [
               "GET",
               "chatchat:message:#{request.message_id}"
             ])
  end

  test "sender-node death after commit leaves safe retry ownership", context do
    from = connect(context.sender.id, context.port)
    request = request(context.receiver.id)
    send_json(from, request)
    assert {:ok, %{"status" => "ok"}} = recv(from)
    stored = Repo.get_by!(Message, sender_id: context.sender.id, message_id: request.message_id)
    :peer.stop(context.peer)
    # Retries are safe even if the original sender never observed the result.
    assert {:ok, retry} =
             MessagesStore.insert_pending(%{
               sender_id: context.sender.id,
               receiver_id: context.receiver.id,
               message_id: request.message_id,
               payload: "cluster"
             })

    assert retry.inserted_at == stored.inserted_at
    to = connect(context.receiver.id, ChatchatTcp.port())
    assert {:ok, %{"message_id" => id}} = recv(to)
    assert id == request.message_id
  end

  test "receiver-node death and stale route use finite committed fallback", context do
    from = connect(context.sender.id, ChatchatTcp.port())
    to = connect(context.receiver.id, context.port)
    request = request(context.receiver.id)
    send_json(from, request)
    assert {:ok, _frame} = recv(to)
    :peer.stop(context.peer)
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert Repo.get_by(Message, sender_id: context.sender.id, message_id: request.message_id)
    # Expire this fixture's unavailable session lease, then recover on this node.
    Redix.command(ChatchatTcp.Redis.Heartbeat, [
      "PEXPIRE",
      ChatchatTcp.RedisKeys.presence_route(context.receiver.id),
      1
    ])

    Process.sleep(10)
    recovered = connect(context.receiver.id, ChatchatTcp.port())
    assert {:ok, %{"message_id" => id}} = recv(recovered)
    assert id == request.message_id
  end

  defp request(receiver),
    do: %{
      type: "send_message",
      request_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      user_id: receiver,
      message: "cluster"
    }

  defp connect(user, port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :line])
    send_json(socket, %{type: "authenticate", token: ChatchatAuth.issue(user).access_token})
    assert {:ok, %{"type" => "authenticated"}} = recv(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp send_json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")

  defp recv(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000), do: Jason.decode(line)
  end
end
