defmodule ChatchatClient.StoreTest do
  use ExUnit.Case, async: true

  alias ChatchatClient.Store
  alias Exqlite.Sqlite3

  setup do
    options = [
      root: Path.join(System.tmp_dir!(), "chatchat-store-tests"),
      namespace: Ecto.UUID.generate(),
      name: nil
    ]

    pid = start_supervised!({Store, options})
    %{store: Store.handle(pid), pid: pid, options: options}
  end

  test "outbox commit survives owner restart and only a matching ok removes it", %{
    store: store,
    options: options
  } do
    assert {:ok, id} = Store.put_outbox(store, 1, 2, "durable")
    assert {:ok, [%{message_id: ^id}]} = Store.pending(store, 1)
    request = Ecto.UUID.generate()
    assert :ok = Store.begin_attempt(store, 1, id, request)
    assert {:error, :unmatched_result} = Store.result(store, 1, id, Ecto.UUID.generate(), :ok)
    assert :ok = Store.result(store, 1, id, request, :failed)
    stop_supervised!(Store)
    new_pid = start_supervised!({Store, options}, id: :reopened)
    reopened = Store.handle(new_pid)
    wait_until(fn -> match?({:ok, [_]}, Store.pending(reopened, 1)) end)
    assert {:ok, [%{message_id: ^id, payload: "durable"}]} = Store.pending(reopened, 1)
    request = Ecto.UUID.generate()
    assert :ok = Store.begin_attempt(reopened, 1, id, request)
    assert :ok = Store.result(reopened, 1, id, request, :ok)
    assert {:ok, []} = Store.pending(reopened, 1)
  end

  test "atomic inbox identity, duplicate receipt, and immutable conflict", %{
    store: store,
    options: options
  } do
    id = Ecto.UUID.generate()
    timestamp = "2026-10-09T10:00:00.000000Z"
    assert {:ok, :saved} = Store.receive_message(store, 2, 1, id, "hello", timestamp)

    assert {:ok, :duplicate} =
             Store.receive_message(store, 2, 1, id, "hello", "2026-10-10T10:00:00.000000Z")

    assert {:error, :identity_conflict} =
             Store.receive_message(store, 2, 1, id, "changed", timestamp)

    assert {:ok, :saved} = Store.receive_message(store, 2, 3, id, "other sender", timestamp)
    assert {:ok, rows} = Store.inbox(store, 2)
    assert length(rows) == 2
    stop_supervised!(Store)
    new_pid = start_supervised!({Store, options}, id: :reopened)

    assert {:ok, :duplicate} =
             Store.receive_message(Store.handle(new_pid), 2, 1, id, "hello", timestamp)
  end

  test "write failure permits neither outbox success nor durable receive", %{
    store: store,
    pid: pid
  } do
    %{db: db} = :sys.get_state(pid)
    assert :ok = Sqlite3.execute(db, "PRAGMA query_only=ON")
    assert {:error, {:storage, _}} = Store.put_outbox(store, 1, 2, "unsaved")

    assert {:error, {:storage, _}} =
             Store.receive_message(
               store,
               2,
               1,
               Ecto.UUID.generate(),
               "unsaved",
               "2026-10-09T10:00:00Z"
             )

    assert {:ok, []} = Store.pending(store, 1)
    assert {:ok, []} = Store.inbox(store, 2)
  end

  test "users and run namespaces are isolated; simultaneous namespace owners fail", %{
    store: store,
    options: options
  } do
    assert {:ok, _} = Store.put_outbox(store, 1, 2, "private")
    assert {:ok, []} = Store.pending(store, 2)
    assert {:error, _} = start_supervised({Store, options}, id: :duplicate)

    other =
      start_supervised!({Store, Keyword.put(options, :namespace, Ecto.UUID.generate())},
        id: :other_run
      )

    assert {:ok, []} = Store.pending(Store.handle(other), 1)
  end

  test "permanent rejection and user suspension retain entries across restart", %{
    store: store,
    options: options
  } do
    assert {:ok, id} = Store.put_outbox(store, 1, 2, "retained")
    request = Ecto.UUID.generate()
    assert :ok = Store.begin_attempt(store, 1, id, request)
    assert :ok = Store.result(store, 1, id, request, :rejected, "invalid_receiver")
    assert {:ok, []} = Store.pending(store, 1)
    assert {:ok, [[^id, 2, "retained", "invalid_receiver"]]} = Store.outbox(store, 1)
    assert {:ok, _} = Store.put_outbox(store, 2, 1, "suspended")
    assert :ok = Store.suspend(store, 2, "invalid_request")
    stop_supervised!(Store)
    new_pid = start_supervised!({Store, options}, id: :reopened)
    reopened = Store.handle(new_pid)
    assert {:ok, "invalid_request"} = Store.suspension(reopened, 2)
    assert {:ok, []} = Store.pending(reopened, 2)
    assert :ok = Store.resume(reopened, 2)
    assert {:ok, [_]} = Store.pending(reopened, 2)
  end

  test "invalid and JSON-escaped oversized content is rejected before storage", %{store: store} do
    assert {:error, :invalid_request} =
             Store.put_outbox(store, 1, 2, String.duplicate("\\", 2_000))

    assert {:error, :invalid_request} = Store.put_outbox(store, 1, 0, "hello")
    assert {:error, :invalid_request} = Store.put_outbox(store, 1, 2, <<255>>)
    assert {:ok, []} = Store.pending(store, 1)
  end

  test "admission bounds queued submissions before payload enqueue", %{store: store, pid: pid} do
    :ok = :sys.suspend(pid)
    tasks = for _ <- 1..260, do: Task.async(fn -> Store.put_outbox(store, 1, 2, "bounded") end)

    try do
      wait_until(fn -> :ets.info(store.gate, :size) == 256 end)
      assert :ets.info(store.gate, :size) == 256
      {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
      assert queued <= 256
    after
      :sys.resume(pid)
    end

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 256
    assert Enum.count(results, &(&1 == {:error, :capacity})) == 4
    assert :ets.info(store.gate, :size) == 0
    assert {:ok, entries} = Store.pending(store, 1)
    assert length(entries) == 128
  end

  test "caller death releases an acquired unused permit", %{store: store, pid: pid} do
    parent = self()
    reference = make_ref()

    caller =
      spawn(fn ->
        receive do
          :reserve ->
            assert :ok = GenServer.call(pid, {:reserve, 1, reference})
            send(parent, :reserved)

            receive do
              :never -> :ok
            end
        end
      end)

    :ets.insert(store.gate, {1, caller, reference, :pending})
    send(caller, :reserve)
    assert_receive :reserved
    Process.exit(caller, :kill)
    wait_until(fn -> :ets.info(store.gate, :size) == 0 end)
    assert {:ok, _} = Store.put_outbox(store, 1, 2, "after crash")
  end

  defp wait_until(condition, attempts \\ 200)
  defp wait_until(condition, 0), do: assert(condition.())

  defp wait_until(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, attempts - 1)
    end
  end
end
