defmodule ChatchatBroker.Storage.MessagesStoreTest do
  use ExUnit.Case, async: false

  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatBroker.Storage.Schemas.User
  alias ChatchatBroker.Storage.Schemas.Message
  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    users =
      for _ <- 1..3 do
        Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"}).id
      end

    [sender, receiver, other] = users

    %{
      message: %{
        sender_id: sender,
        receiver_id: receiver,
        message_id: Ecto.UUID.generate(),
        payload: "hello"
      },
      other: other
    }
  end

  test "identical retry preserves backend timestamp and immutable content", %{
    message: message,
    other: other
  } do
    assert {:ok, stored} = MessagesStore.insert_pending(message)

    assert {:ok, retry} =
             MessagesStore.insert_pending(
               Map.put(message, :inserted_at, ~U[2000-01-01 00:00:00Z])
             )

    assert stored == retry

    assert {:error, :identity_conflict} =
             MessagesStore.insert_pending(%{message | payload: "changed"})

    assert {:error, :identity_conflict} =
             MessagesStore.insert_pending(%{message | receiver_id: other})

    assert [^stored] = MessagesStore.pending_page(message.receiver_id)
  end

  test "equal UUIDs from different senders remain separate and deletes are scoped", %{
    message: message,
    other: other
  } do
    assert {:ok, first} = MessagesStore.insert_pending(message)
    assert {:ok, second} = MessagesStore.insert_pending(%{message | sender_id: other})

    assert :ok = MessagesStore.delete_for_receiver(other, message.sender_id, message.message_id)
    assert length(MessagesStore.pending_page(message.receiver_id)) == 2

    assert :ok =
             MessagesStore.delete_for_receiver(
               message.receiver_id,
               message.sender_id,
               message.message_id
             )

    assert [^second] = MessagesStore.pending_page(message.receiver_id)

    assert :ok =
             MessagesStore.delete_for_receiver(
               message.receiver_id,
               first.sender_id,
               first.message_id
             )
  end

  test "deletion replaces content, rejects receiver changes and resends, and scopes cleanup", %{
    message: message,
    other: other
  } do
    assert {:ok, _} = MessagesStore.insert_pending(message)
    deletion = Map.merge(message, %{kind: "delete", payload: ""})

    assert {:error, :identity_conflict} =
             MessagesStore.insert_pending(%{deletion | receiver_id: other})

    assert {:ok, deleted} = MessagesStore.insert_pending(deletion)
    assert deleted.kind == "delete"
    assert deleted.payload == ""
    assert {:ok, ^deleted} = MessagesStore.insert_pending(deletion)
    assert {:error, :identity_conflict} = MessagesStore.insert_pending(message)

    assert :ok =
             MessagesStore.delete_for_receiver(
               message.receiver_id,
               message.sender_id,
               message.message_id
             )

    assert [^deleted] = MessagesStore.pending_page(message.receiver_id)

    assert :ok =
             MessagesStore.delete_for_receiver(
               message.receiver_id,
               message.sender_id,
               message.message_id,
               "delete"
             )

    assert [] = MessagesStore.pending_page(message.receiver_id)
  end

  test "pages are bounded and wrap can revisit unacknowledged rows", %{message: message} do
    for _ <- 1..129 do
      assert {:ok, _} =
               MessagesStore.insert_pending(%{message | message_id: Ecto.UUID.generate()})
    end

    page = MessagesStore.pending_page(message.receiver_id)
    assert length(page) == 128
    last = List.last(page)

    assert [tail] =
             MessagesStore.pending_page(message.receiver_id, {last.sender_id, last.message_id})

    assert [] = MessagesStore.pending_page(message.receiver_id, {tail.sender_id, tail.message_id})
    assert page == MessagesStore.pending_page(message.receiver_id)

    assert_raise FunctionClauseError, fn ->
      MessagesStore.pending_page(message.receiver_id, nil, 129)
    end
  end

  test "expired persistence budget never starts a write", %{message: message} do
    assert {:error, :deadline} =
             MessagesStore.insert_pending_before(message, System.monotonic_time(:millisecond) - 1)

    assert Repo.get_by(Message, sender_id: message.sender_id, message_id: message.message_id) ==
             nil
  end

  test "busy pool refuses checkout immediately and the same identity succeeds after release" do
    with_budget_repo(1, fn repo, message ->
      parent = self()

      lock =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.checkout(fn ->
            send(parent, :pool_owned)

            receive do
              :release -> :ok
            after
              2_000 -> :ok
            end
          end)
        end)

      assert_receive :pool_owned
      started = System.monotonic_time(:millisecond)

      try do
        assert {:error, :unavailable} = MessagesStore.insert_pending_before(message, started + 30)
        assert System.monotonic_time(:millisecond) - started < 500
      after
        send(lock.pid, :release)
        Task.await(lock)
      end

      assert Repo.get_by(Message, sender_id: message.sender_id, message_id: message.message_id) ==
               nil

      assert {:ok, first} = MessagesStore.insert_pending(message)
      assert {:ok, ^first} = MessagesStore.insert_pending(message)
    end)
  end

  @tag capture_log: true
  test "statement timeout rolls back unconfirmed work and leaves retry identity usable" do
    with_budget_repo(2, fn repo, message ->
      parent = self()

      lock =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(repo, "LOCK TABLE messages IN SHARE MODE", [])
            send(parent, :table_locked)

            receive do
              :release -> :ok
            after
              2_000 -> :ok
            end
          end)
        end)

      assert_receive :table_locked

      try do
        assert {:error, reason} =
                 MessagesStore.insert_pending_before(
                   message,
                   System.monotonic_time(:millisecond) + 30
                 )

        assert reason in [:unavailable, :deadline]
      after
        send(lock.pid, :release)
        Task.await(lock)
      end

      assert Repo.get_by(Message, sender_id: message.sender_id, message_id: message.message_id) ==
               nil

      assert {:ok, _} = MessagesStore.insert_pending(message)
    end)
  end

  defp with_budget_repo(size, operation) do
    # These tests exercise real pool ownership and commits. Release the setup
    # sandbox transaction so its table locks cannot obstruct the test lock.
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)

    repo =
      start_supervised!(
        {Repo, name: __MODULE__.BudgetRepo, pool: DBConnection.ConnectionPool, pool_size: size}
      )

    previous = Repo.put_dynamic_repo(repo)

    users =
      for _ <- 1..2,
          do: Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"})

    [sender, receiver] = users

    message = %{
      sender_id: sender.id,
      receiver_id: receiver.id,
      message_id: Ecto.UUID.generate(),
      payload: "budget"
    }

    try do
      operation.(repo, message)
    after
      Repo.delete_all(from m in Message, where: m.sender_id == ^sender.id)
      Enum.each(users, &Repo.delete!/1)
      Repo.put_dynamic_repo(previous)
    end
  end

  test "independent concurrent transactions confirm one committed row" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      sender = Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"})
      receiver = Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"})

      message = %{
        sender_id: sender.id,
        receiver_id: receiver.id,
        message_id: Ecto.UUID.generate(),
        payload: "concurrent"
      }

      try do
        results =
          1..8
          |> Task.async_stream(
            fn _ ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                MessagesStore.insert_pending(message)
              end)
            end,
            max_concurrency: 8
          )
          |> Enum.map(fn {:ok, {:ok, stored}} -> stored end)

        assert length(Enum.uniq(results)) == 1
        assert [hd(results)] == MessagesStore.pending_page(receiver.id)

        variants = [%{message | payload: "changed"}, %{message | receiver_id: sender.id}]

        for variant <- variants do
          assert {:error, :identity_conflict} = MessagesStore.insert_pending(variant)
        end
      after
        Repo.delete_all(from m in Message, where: m.sender_id == ^sender.id)
        Repo.delete!(sender)
        Repo.delete!(receiver)
      end
    end)
  end
end
