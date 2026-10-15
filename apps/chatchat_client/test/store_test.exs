defmodule ChatchatClient.StoreTest do
  use ExUnit.Case, async: true
  alias ChatchatClient.Store

  test "edits replace pending content and invalidate old results without changing destination" do
    {:ok, id, store} = Store.put_outbox(Store.new(1), 2, "original")
    request = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(store, id, request)
    assert {:error, :identity_conflict} = Store.put_edit(store, 3, id, "wrong receiver")
    assert {:error, :invalid_request} = Store.put_edit(store, 2, id, <<255>>)
    assert {:ok, ^id, store} = Store.put_edit(store, 2, id, "edited")
    assert [%{kind: "edit", payload: "edited", request_id: nil}] = Store.pending(store)
    assert {:error, :unmatched_result} = Store.result(store, id, request, :ok)
    next = Ecto.UUID.generate()
    assert {:ok, store} = Store.begin_attempt(store, id, next)
    assert {:ok, store} = Store.result(store, id, next, :failed)
    assert Store.outbox(store) == [[id, 2, "edited", nil]]
    assert {:ok, ^id, store} = Store.put_edit(store, 2, id, "edited again")
    assert [%{kind: "edit", payload: "edited again"}] = Store.pending(store)
  end

  test "replacing an entry works at capacity; a new edit remains bounded" do
    store =
      Enum.reduce(1..128, Store.new(1), fn _, store ->
        {:ok, _, store} = Store.put_outbox(store, 2, "original")
        store
      end)

    [entry | _] = Store.pending(store)
    assert {:ok, _, store} = Store.put_edit(store, 2, entry.message_id, "edited")
    assert length(Store.outbox(store)) == 128
    assert {:error, :capacity} = Store.put_edit(store, 2, Ecto.UUID.generate(), "new")
  end

  test "pure outbox transitions keep identity and only a matching ok removes it" do
    store = Store.new(1)
    assert {:ok, id, store} = Store.put_outbox(store, 2, "hello")
    assert {:ok, ^id, ^store} = Store.put_outbox(store, 2, "hello", id)
    assert {:error, :identity_conflict} = Store.put_outbox(store, 3, "hello", id)
    request = Ecto.UUID.generate()
    assert {:ok, store} = Store.begin_attempt(store, id, request)
    assert Store.pending(store) == []
    assert {:error, :unmatched_result} = Store.result(store, id, Ecto.UUID.generate(), :ok)
    assert {:ok, store} = Store.result(store, id, request, :failed)
    assert Store.outbox(store) == [[id, 2, "hello", nil]]
    assert Store.pending(store) == []
    assert {:ok, store} = Store.begin_attempt(store, id, Ecto.UUID.generate())
    [{^id, entry}] = :gb_trees.to_list(store.outbox)
    assert {:ok, store} = Store.result(store, id, entry.request_id, :ok)
    assert Store.outbox(store) == []
    assert Store.pending(store) == []
  end

  test "inbox deduplicates by sender and identity and rejects changed content" do
    store = Store.new(2)
    id = Ecto.UUID.generate()
    timestamp = "2026-10-09T10:00:00Z"
    assert {:ok, :saved, store} = Store.receive_message(store, 1, id, "hello", timestamp)
    assert {:ok, :duplicate, ^store} = Store.receive_message(store, 1, id, "hello", timestamp)

    assert {:error, :identity_conflict} =
             Store.receive_message(store, 1, id, "changed", timestamp)

    assert {:ok, :saved, store} = Store.receive_message(store, 3, id, "other", timestamp)
    assert length(Store.inbox(store)) == 2
    assert Store.inbox(Store.new(2)) == []
  end

  test "outbox admission is bounded per client and confirmation frees capacity" do
    store =
      Enum.reduce(1..128, Store.new(1), fn _, store ->
        {:ok, _id, store} = Store.put_outbox(store, 2, "bounded")
        store
      end)

    assert {:error, :capacity} = Store.put_outbox(store, 2, "full")
    assert {:ok, _, _} = Store.put_outbox(Store.new(3), 2, "independent")
    [entry | _] = Store.pending(store)
    request = Ecto.UUID.generate()
    assert {:ok, store} = Store.begin_attempt(store, entry.message_id, request)
    assert {:ok, store} = Store.result(store, entry.message_id, request, :ok)
    assert {:ok, _, _} = Store.put_outbox(store, 2, "available")
  end

  test "ordered cursor pages and retry index track updates" do
    ids = Enum.sort(for _ <- 1..128, do: Ecto.UUID.generate())

    store =
      Enum.reduce(ids, Store.new(1), fn id, store ->
        {:ok, ^id, store} = Store.put_outbox(store, 2, "paged", id)

        {:ok, :saved, store} =
          Store.receive_message(store, 2, id, "paged", "2026-10-09T10:00:00Z")

        store
      end)

    rows = Store.outbox(store, "", 16)
    assert Enum.map(rows, &hd/1) == Enum.take(ids, 16)
    cursor = Enum.at(ids, 15)
    assert Enum.map(Store.outbox(store, cursor), &hd/1) == Enum.drop(ids, 16)
    assert Enum.map(Store.inbox(store, {2, cursor}), &Enum.at(&1, 1)) == Enum.drop(ids, 16)
    id = hd(ids)
    request = Ecto.UUID.generate()
    assert {:ok, store} = Store.begin_attempt(store, id, request)
    refute Enum.any?(Store.pending(store), &(&1.message_id == id))
    assert {:ok, store} = Store.result(store, id, request, :rejected, "invalid_receiver")
    refute Enum.any?(Store.pending(store), &(&1.message_id == id))
    assert Store.outbox(store, "", 1) == [[id, 2, "paged", "invalid_receiver"]]
  end

  test "suspension stops attempts until resume and rejection retains content" do
    {:ok, id, store} = Store.put_outbox(Store.new(1), 2, "retained")
    store = Store.suspend(store, "invalid_request")
    assert Store.pending(store) == []
    assert {:error, :not_pending} = Store.begin_attempt(store, id, Ecto.UUID.generate())
    store = Store.resume(store)
    assert length(Store.pending(store)) == 1
    request = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(store, id, request)
    {:ok, store} = Store.result(store, id, request, :rejected, "invalid_receiver")
    assert Store.pending(store) == []
    assert Store.outbox(store) == [[id, 2, "retained", "invalid_receiver"]]
  end

  test "invalid and encoded oversized content never enters state" do
    store = Store.new(1)
    assert {:error, :invalid_request} = Store.put_outbox(store, 2, String.duplicate("\\", 2_000))
    assert {:error, :invalid_request} = Store.put_outbox(store, 0, "hello")
    assert {:error, :invalid_request} = Store.put_outbox(store, 2, <<255>>)

    assert {:error, :invalid_request} =
             Store.receive_message(store, 2, Ecto.UUID.generate(), "hello", "invalid")
  end
end
