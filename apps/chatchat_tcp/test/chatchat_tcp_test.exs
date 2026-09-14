defmodule ChatchatTcpTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.Presence
  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.{Message, User}

  setup do
    {:ok, "OK"} = Redix.command(ChatchatTcp.Redis, ["FLUSHDB"])
    :ok
  end

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

  test "reports a connected user as online" do
    user_id = 45
    socket = connect_and_authenticate(user_id)

    :ok = :gen_tcp.send(socket, Jason.encode!(%{type: "is_online", user_id: user_id}) <> "\n")

    assert {:ok, %{"is_online" => true}} = recv_json(socket)
    :ok = :gen_tcp.close(socket)
  end

  test "reports a user without a connection as offline" do
    socket = connect_and_authenticate(46)

    :ok = :gen_tcp.send(socket, Jason.encode!(%{type: "is_online", user_id: 47}) <> "\n")

    assert {:ok, %{"is_online" => false}} = recv_json(socket)
    :ok = :gen_tcp.close(socket)
  end

  test "admits and delivers a message to an online receiver" do
    sender = connect_and_authenticate(48)
    receiver = connect_and_authenticate(49)

    request = %{type: "send_message", request_id: "request-1", user_id: 49, message: "hello"}
    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok,
            %{
              "type" => "message_admitted",
              "request_id" => "request-1",
              "message_id" => message_id
            }} = recv_json(sender)

    ack = %{type: "message_accepted_ack", request_id: "request-1", message_id: message_id}
    :ok = :gen_tcp.send(sender, Jason.encode!(ack) <> "\n")

    assert_eventually(fn ->
      match?(
        {:ok, encoded} when is_binary(encoded),
        Redix.command(ChatchatTcp.Redis, ["GET", "chatchat:message:#{message_id}"])
      )
    end)

    assert {:ok, encoded} =
             Redix.command(ChatchatTcp.Redis, ["GET", "chatchat:message:#{message_id}"])

    assert %{
             "message_id" => ^message_id,
             "sender_id" => 48,
             "recipient_id" => 49,
             "message" => "hello"
           } = Jason.decode!(encoded)

    assert {:ok, score} =
             Redix.command(ChatchatTcp.Redis, [
               "ZSCORE",
               "chatchat:sending_deadlines",
               message_id
             ])

    assert is_binary(score)

    assert {:ok,
            %{
              "type" => "message",
              "message_id" => ^message_id,
              "from_user_id" => 48,
              "message" => "hello"
            }} = recv_json(receiver)

    :ok =
      :gen_tcp.send(
        receiver,
        Jason.encode!(%{type: "message_delivered_ack", message_id: message_id}) <> "\n"
      )

    assert_eventually(fn ->
      {:ok, [message, membership, deadline]} =
        Redix.pipeline(ChatchatTcp.Redis, [
          ["GET", "chatchat:message:#{message_id}"],
          ["SISMEMBER", "chatchat:sending:49", message_id],
          ["ZSCORE", "chatchat:sending_deadlines", message_id]
        ])

      is_nil(message) and membership == 0 and is_nil(deadline)
    end)

    :ok = :gen_tcp.close(sender)
    :ok = :gen_tcp.close(receiver)
  end

  test "repeating a pending request replaces it" do
    sender = connect_and_authenticate(50)
    request = %{type: "send_message", request_id: "request-2", user_id: 51, message: "hello"}

    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok, %{"type" => "message_admitted", "message_id" => message_id}} =
             recv_json(sender)

    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok, %{"type" => "message_admitted", "message_id" => replacement_id}} =
             recv_json(sender)

    refute replacement_id == message_id

    changed_request = %{request | message: "different"}
    :ok = :gen_tcp.send(sender, Jason.encode!(changed_request) <> "\n")

    assert {:ok, %{"type" => "message_admitted", "message_id" => changed_id}} = recv_json(sender)
    refute changed_id in [message_id, replacement_id]

    :ok = :gen_tcp.close(sender)
  end

  test "delivers a queued message when the receiver connects" do
    sender = connect_and_authenticate(55)
    request = %{type: "send_message", request_id: "request-4", user_id: 56, message: "later"}
    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok, %{"type" => "message_admitted", "message_id" => message_id}} =
             recv_json(sender)

    :ok =
      :gen_tcp.send(
        sender,
        Jason.encode!(%{
          type: "message_accepted_ack",
          request_id: "request-4",
          message_id: message_id
        }) <> "\n"
      )

    receiver = connect_and_authenticate(56)

    assert {:ok,
            %{
              "type" => "message",
              "message_id" => ^message_id,
              "from_user_id" => 55,
              "message" => "later"
            }} = recv_json(receiver)

    :ok = :gen_tcp.close(sender)
    :ok = :gen_tcp.close(receiver)
  end

  test "an expired pending message returns an error and can be resent with the same request id" do
    sender = connect_and_authenticate(52)
    other_user = connect_and_authenticate(53)

    request = %{type: "send_message", request_id: "request-3", user_id: 54, message: "hello"}
    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok, %{"type" => "message_admitted", "message_id" => message_id}} =
             recv_json(sender)

    ack = %{type: "message_accepted_ack", request_id: "request-3", message_id: message_id}
    :ok = :gen_tcp.send(other_user, Jason.encode!(ack) <> "\n")
    assert {:ok, %{"type" => "error", "error" => "unknown_message"}} = recv_json(other_user)

    Process.sleep(110)
    :ok = :gen_tcp.send(sender, Jason.encode!(ack) <> "\n")
    assert {:ok, %{"type" => "error", "error" => "unknown_message"}} = recv_json(sender)

    :ok = :gen_tcp.send(sender, Jason.encode!(request) <> "\n")

    assert {:ok,
            %{
              "type" => "message_admitted",
              "request_id" => "request-3",
              "message_id" => new_message_id
            }} = recv_json(sender)

    refute new_message_id == message_id

    :ok = :gen_tcp.close(sender)
    :ok = :gen_tcp.close(other_user)
  end

  test "persists an expired message and removes every related Redis entry" do
    now = DateTime.utc_now()
    suffix = System.unique_integer([:positive])

    sender =
      Repo.insert!(%User{
        username: "persistence-sender-#{suffix}",
        password_hash: "hash",
        inserted_at: now
      })

    receiver =
      Repo.insert!(%User{
        username: "persistence-receiver-#{suffix}",
        password_hash: "hash",
        inserted_at: now
      })

    message_id = Ecto.UUID.generate()

    encoded =
      Jason.encode!(%{
        message_id: message_id,
        sender_id: sender.id,
        recipient_id: receiver.id,
        message: "store me"
      })

    assert {:ok, _results} =
             Redix.pipeline(ChatchatTcp.Redis, [
               ["SET", "chatchat:message:#{message_id}", encoded],
               ["SADD", "chatchat:sending:#{receiver.id}", message_id],
               ["ZADD", "chatchat:sending_deadlines", 0, message_id]
             ])

    send(ChatchatTcp.Persistence, :persist)

    assert_eventually(fn -> Repo.get(Message, message_id) != nil end)

    assert %Message{
             sender_id: sender_id,
             receiver_id: receiver_id,
             payload: "store me"
           } = Repo.get!(Message, message_id)

    assert sender_id == sender.id
    assert receiver_id == receiver.id

    assert {:ok, [message, membership, deadline, persisting, claim]} =
             Redix.pipeline(ChatchatTcp.Redis, [
               ["GET", "chatchat:message:#{message_id}"],
               ["SISMEMBER", "chatchat:sending:#{receiver.id}", message_id],
               ["ZSCORE", "chatchat:sending_deadlines", message_id],
               ["GET", "chatchat:persisting:#{message_id}"],
               ["SISMEMBER", "chatchat:persisting", message_id]
             ])

    assert is_nil(message)
    assert membership == 0
    assert is_nil(deadline)
    assert is_nil(persisting)
    assert claim == 0

    Repo.delete_all(Message)
    Repo.delete!(sender)
    Repo.delete!(receiver)
  end

  test "delivers and acknowledges messages from Redis and PostgreSQL when receiver connects" do
    now = DateTime.utc_now()
    suffix = System.unique_integer([:positive])

    sender =
      Repo.insert!(%User{
        username: "delivery-sender-#{suffix}",
        password_hash: "hash",
        inserted_at: now
      })

    receiver =
      Repo.insert!(%User{
        username: "delivery-receiver-#{suffix}",
        password_hash: "hash",
        inserted_at: now
      })

    redis_message_id = Ecto.UUID.generate()
    stored_message_id = Ecto.UUID.generate()

    redis_message =
      Jason.encode!(%{
        message_id: redis_message_id,
        sender_id: sender.id,
        recipient_id: receiver.id,
        message: "from redis"
      })

    assert {:ok, _results} =
             Redix.pipeline(ChatchatTcp.Redis, [
               ["SET", "chatchat:message:#{redis_message_id}", redis_message],
               ["SADD", "chatchat:sending:#{receiver.id}", redis_message_id],
               ["ZADD", "chatchat:sending_deadlines", 9_999_999_999_999, redis_message_id]
             ])

    Repo.insert!(%Message{
      message_id: stored_message_id,
      sender_id: sender.id,
      receiver_id: receiver.id,
      payload: "from postgres",
      inserted_at: now
    })

    socket = connect_and_authenticate(receiver.id)

    assert {:ok, %{"type" => "message", "message_id" => ^stored_message_id}} = recv_json(socket)
    assert {:ok, %{"type" => "message", "message_id" => ^redis_message_id}} = recv_json(socket)

    for message_id <- [redis_message_id, stored_message_id] do
      :ok =
        :gen_tcp.send(
          socket,
          Jason.encode!(%{type: "message_delivered_ack", message_id: message_id}) <> "\n"
        )
    end

    assert_eventually(fn ->
      {:ok, redis_message} =
        Redix.command(ChatchatTcp.Redis, ["GET", "chatchat:message:#{redis_message_id}"])

      is_nil(redis_message) and is_nil(Repo.get(Message, stored_message_id))
    end)

    :ok = :gen_tcp.close(socket)
    Repo.delete!(sender)
    Repo.delete!(receiver)
  end

  defp connect do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", ChatchatTcp.port(), [:binary, active: false, packet: :raw])

    socket
  end

  defp connect_and_authenticate(user_id) do
    %{access_token: token} = ChatchatAuth.issue(user_id)
    socket = connect()
    :ok = :gen_tcp.send(socket, Jason.encode!(%{type: "authenticate", token: token}) <> "\n")
    assert {:ok, %{"type" => "authenticated", "user_id" => ^user_id}} = recv_json(socket)
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
