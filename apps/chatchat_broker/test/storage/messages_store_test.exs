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
