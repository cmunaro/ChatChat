defmodule ChatchatClient.Store do
  @moduledoc "Transactional local ownership, one SQLite connection per run namespace."
  use GenServer

  alias Exqlite.Sqlite3

  @slots 256
  @operation_bytes 8_192
  @page_size 128

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  def handle(server \\ __MODULE__), do: GenServer.call(server, :handle)

  def put_outbox(store, user_id, receiver_id, payload, message_id \\ Ecto.UUID.generate()) do
    with :ok <- validate_message(user_id, receiver_id, message_id, payload) do
      submit(store, {:put_outbox, user_id, receiver_id, message_id, payload})
    end
  end

  def receive_message(store, user_id, sender_id, message_id, payload, inserted_at) do
    with :ok <- validate_message(sender_id, user_id, message_id, payload),
         true <- is_binary(inserted_at) and byte_size(inserted_at) <= 64,
         {:ok, _datetime, 0} <- DateTime.from_iso8601(inserted_at) do
      submit(store, {:receive, user_id, sender_id, message_id, payload, inserted_at})
    else
      _ -> {:error, :invalid_request}
    end
  end

  def pending(store, user_id, limit \\ @page_size) when limit > 0 and limit <= @page_size,
    do: submit(store, {:pending, user_id, limit})

  def inbox(store, user_id, after_identity \\ nil, limit \\ @page_size)
      when limit > 0 and limit <= @page_size,
      do: submit(store, {:inbox, user_id, after_identity, limit})

  def begin_attempt(store, user_id, message_id, request_id) do
    with {:ok, ^request_id} <- Ecto.UUID.cast(request_id) do
      submit(store, {:begin_attempt, user_id, message_id, request_id})
    else
      _ -> {:error, :invalid_request}
    end
  end

  def result(store, user_id, message_id, request_id, status, reason \\ nil)
      when status in [:ok, :failed, :rejected],
      do: submit(store, {:result, user_id, message_id, request_id, status, reason})

  def suspend(store, user_id, reason) when is_binary(reason) and byte_size(reason) <= 256,
    do: submit(store, {:suspend, user_id, reason})

  def suspension(store, user_id), do: submit(store, {:suspension, user_id})
  def resume(store, user_id), do: submit(store, {:resume, user_id})
  def load_shard(store), do: submit(store, :load_shard)

  def save_shard(store, shard) when is_integer(shard) and shard >= 0,
    do: submit(store, {:save_shard, shard})

  def outbox(store, user_id, after_id \\ "", limit \\ @page_size)
      when limit > 0 and limit <= @page_size,
      do: submit(store, {:outbox, user_id, after_id, limit})

  def validate_message(sender_id, receiver_id, message_id, payload) do
    with true <- valid_user?(sender_id) and valid_user?(receiver_id),
         {:ok, ^message_id} <- Ecto.UUID.cast(message_id),
         true <- is_binary(payload) and String.valid?(payload) and byte_size(payload) <= 4_096 do
      request = %{
        type: "send_message",
        request_id: message_id,
        message_id: message_id,
        user_id: receiver_id,
        message: payload
      }

      delivery = %{
        type: "message",
        message_id: message_id,
        from_user_id: 9_223_372_036_854_775_807,
        message: payload,
        inserted_at: "2026-10-09T00:00:00.000000Z",
        receipt_id: message_id
      }

      if byte_size(Jason.encode!(request)) <= 4_096 and
           byte_size(Jason.encode!(delivery)) <= 4_096, do: :ok, else: {:error, :invalid_request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_user?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  # Fixed-size permits reserve 8 KiB each: at most 256 operations / 2 MiB
  # before either metadata or payload enters the owner's mailbox.
  defp submit(%{pid: pid, gate: gate}, operation) do
    if :erlang.external_size(operation) <= @operation_bytes do
      reference = make_ref()
      entry = fn slot -> {slot, self(), reference, :pending} end
      slot = Enum.find(1..@slots, fn slot -> claim_slot(gate, entry.(slot)) end)

      if slot do
        with :ok <- GenServer.call(pid, {:reserve, slot, reference}, :infinity) do
          GenServer.call(pid, {:operation, reference, operation}, :infinity)
        end
      else
        {:error, :capacity}
      end
    else
      {:error, :capacity}
    end
  catch
    :exit, _ -> {:error, {:storage, :unavailable}}
    :error, :badarg -> {:error, {:storage, :unavailable}}
  end

  defp claim_slot(gate, entry) do
    slot = elem(entry, 0)

    case :ets.lookup(gate, slot) do
      [{^slot, pid, _reference, :pending} = abandoned] ->
        unless Process.alive?(pid), do: :ets.delete_object(gate, abandoned)

      _ ->
        :ok
    end

    :ets.insert_new(gate, entry)
  end

  @impl true
  def init(options) do
    root = Keyword.fetch!(options, :root) |> Path.expand()
    namespace = Keyword.fetch!(options, :namespace)

    unless is_binary(namespace) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, namespace) do
      raise ArgumentError, "invalid client state namespace"
    end

    with :ok <- File.mkdir_p(root),
         {:ok, db} <- Sqlite3.open(Path.join(root, namespace <> ".sqlite3")) do
      case initialize(db) do
        :ok ->
          gate = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
          {:ok, %{db: db, gate: gate, reservations: %{}}}

        {:error, reason} ->
          Sqlite3.close(db)
          {:stop, {:storage, reason}}
      end
    else
      {:error, reason} -> {:stop, {:storage, reason}}
    end
  end

  defp initialize(db) do
    with :ok <-
           Sqlite3.execute(db, """
           PRAGMA busy_timeout=1000;
           PRAGMA locking_mode=EXCLUSIVE;
           PRAGMA journal_mode=WAL;
           PRAGMA synchronous=FULL;
           BEGIN IMMEDIATE;
           CREATE TABLE IF NOT EXISTS outbox (
             user_id INTEGER NOT NULL, message_id TEXT NOT NULL,
             receiver_id INTEGER NOT NULL, payload BLOB NOT NULL,
             request_id TEXT, rejection TEXT, retry_at INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (user_id, message_id)
           );
           CREATE TABLE IF NOT EXISTS inbox (
             user_id INTEGER NOT NULL, sender_id INTEGER NOT NULL,
             message_id TEXT NOT NULL, payload BLOB NOT NULL, inserted_at TEXT NOT NULL,
             PRIMARY KEY (user_id, sender_id, message_id)
           );
           CREATE TABLE IF NOT EXISTS suspensions (user_id INTEGER PRIMARY KEY, reason TEXT NOT NULL);
           CREATE TABLE IF NOT EXISTS run_metadata (id INTEGER PRIMARY KEY CHECK(id=1), shard INTEGER NOT NULL);
           COMMIT;
           """),
         :ok <- upgrade_retry_columns(db) do
      Sqlite3.execute(
        db,
        "CREATE INDEX IF NOT EXISTS outbox_retry ON outbox(user_id,rejection,retry_at,message_id)"
      )
    end
  end

  defp upgrade_retry_columns(db) do
    safely(fn ->
      columns = query(db, "PRAGMA table_info(outbox)", []) |> Enum.map(&Enum.at(&1, 1))

      unless "retry_at" in columns,
        do: execute!(db, "ALTER TABLE outbox ADD COLUMN retry_at INTEGER NOT NULL DEFAULT 0")

      unless "failures" in columns,
        do: execute!(db, "ALTER TABLE outbox ADD COLUMN failures INTEGER NOT NULL DEFAULT 0")

      :ok
    end)
  end

  @impl true
  def handle_call(:handle, _from, state),
    do: {:reply, %{pid: self(), gate: state.gate}, state}

  def handle_call({:reserve, slot, reference}, {pid, _tag}, state) do
    case :ets.lookup(state.gate, slot) do
      [{^slot, ^pid, ^reference, :pending}] ->
        monitor = Process.monitor(pid)
        :ets.insert(state.gate, {slot, pid, reference, :active})
        reservation = %{slot: slot, pid: pid, monitor: monitor}

        {:reply, :ok,
         %{state | reservations: Map.put(state.reservations, reference, reservation)}}

      _ ->
        {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:operation, reference, operation}, {pid, _tag}, state) do
    case state.reservations[reference] do
      %{pid: ^pid} ->
        reply = safely(fn -> perform(state.db, operation) end)
        {:reply, reply, release(state, reference)}

      _ ->
        {:reply, {:error, :capacity}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.reservations, fn {_reference, value} -> value.monitor == monitor end) do
      {reference, _} -> {:noreply, release(state, reference)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  defp release(state, reference) do
    {reservation, reservations} = Map.pop(state.reservations, reference)
    Process.demonitor(reservation.monitor, [:flush])
    :ets.delete(state.gate, reservation.slot)
    %{state | reservations: reservations}
  end

  defp perform(db, {:put_outbox, user, receiver, id, payload}) do
    transaction(db, fn ->
      query(
        db,
        "INSERT OR IGNORE INTO outbox(user_id,message_id,receiver_id,payload) VALUES(?,?,?,?)",
        [user, id, receiver, {:blob, payload}]
      )

      case query(db, "SELECT receiver_id,payload FROM outbox WHERE user_id=? AND message_id=?", [
             user,
             id
           ]) do
        [[^receiver, ^payload]] -> {:ok, id}
        _ -> {:error, :identity_conflict}
      end
    end)
  end

  defp perform(db, {:receive, user, sender, id, payload, timestamp}) do
    transaction(db, fn ->
      existing =
        query(db, "SELECT payload FROM inbox WHERE user_id=? AND sender_id=? AND message_id=?", [
          user,
          sender,
          id
        ])

      case existing do
        [] ->
          query(
            db,
            "INSERT INTO inbox(user_id,sender_id,message_id,payload,inserted_at) VALUES(?,?,?,?,?)",
            [user, sender, id, {:blob, payload}, timestamp]
          )

          {:ok, :saved}

        [[^payload]] ->
          {:ok, :duplicate}

        _ ->
          {:error, :identity_conflict}
      end
    end)
  end

  defp perform(db, {:pending, user, limit}) do
    rows =
      query(
        db,
        """
        SELECT message_id,receiver_id,payload,request_id FROM outbox
        WHERE user_id=? AND rejection IS NULL AND retry_at<=?
        AND NOT EXISTS(SELECT 1 FROM suspensions WHERE user_id=?)
        ORDER BY retry_at,message_id LIMIT ?
        """,
        [user, System.system_time(:millisecond), user, limit]
      )

    {:ok,
     Enum.map(rows, fn [id, receiver, payload, request] ->
       %{message_id: id, receiver_id: receiver, payload: payload, request_id: request}
     end)}
  end

  defp perform(db, {:inbox, user, cursor, limit}) do
    {sender, id} = cursor || {0, ""}

    {:ok,
     query(
       db,
       """
       SELECT sender_id,message_id,payload,inserted_at FROM inbox
       WHERE user_id=? AND (sender_id>? OR (sender_id=? AND message_id>?))
       ORDER BY sender_id,message_id LIMIT ?
       """,
       [user, sender, sender, id, limit]
     )}
  end

  defp perform(db, {:outbox, user, cursor, limit}) do
    {:ok,
     query(
       db,
       "SELECT message_id,receiver_id,payload,rejection FROM outbox WHERE user_id=? AND message_id>? ORDER BY message_id LIMIT ?",
       [user, cursor, limit]
     )}
  end

  defp perform(db, {:begin_attempt, user, id, request}) do
    query(
      db,
      "UPDATE outbox SET request_id=?,retry_at=? WHERE user_id=? AND message_id=? AND rejection IS NULL AND NOT EXISTS(SELECT 1 FROM suspensions WHERE user_id=?)",
      [request, System.system_time(:millisecond) + 10_000, user, id, user]
    )

    case query(db, "SELECT request_id FROM outbox WHERE user_id=? AND message_id=?", [user, id]) do
      [[^request]] -> :ok
      _ -> {:error, :not_pending}
    end
  end

  defp perform(db, {:result, user, id, request, status, reason}) do
    transaction(db, fn ->
      case query(db, "SELECT request_id,failures FROM outbox WHERE user_id=? AND message_id=?", [
             user,
             id
           ]) do
        [[^request, failures]] when not is_nil(request) ->
          case status do
            :ok ->
              query(db, "DELETE FROM outbox WHERE user_id=? AND message_id=?", [user, id])

            :failed ->
              query(
                db,
                "UPDATE outbox SET request_id=NULL,retry_at=?,failures=? WHERE user_id=? AND message_id=?",
                [retry_at(failures), min(failures + 1, 6), user, id]
              )

            :rejected ->
              query(
                db,
                "UPDATE outbox SET request_id=NULL,rejection=? WHERE user_id=? AND message_id=?",
                [reason || "rejected", user, id]
              )
          end

          :ok

        _ ->
          {:error, :unmatched_result}
      end
    end)
  end

  defp perform(db, {:suspend, user, reason}) do
    query(
      db,
      "INSERT INTO suspensions(user_id,reason) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET reason=excluded.reason",
      [user, reason]
    )

    :ok
  end

  defp perform(db, {:suspension, user}) do
    case query(db, "SELECT reason FROM suspensions WHERE user_id=?", [user]) do
      [] -> {:ok, nil}
      [[reason]] -> {:ok, reason}
    end
  end

  defp perform(db, {:resume, user}) do
    query(db, "DELETE FROM suspensions WHERE user_id=?", [user])
    :ok
  end

  defp perform(db, :load_shard) do
    case query(db, "SELECT shard FROM run_metadata WHERE id=1", []) do
      [] -> {:ok, nil}
      [[shard]] -> {:ok, shard}
    end
  end

  defp perform(db, {:save_shard, shard}) do
    transaction(db, fn ->
      query(db, "INSERT OR IGNORE INTO run_metadata(id,shard) VALUES(1,?)", [shard])

      case query(db, "SELECT shard FROM run_metadata WHERE id=1", []) do
        [[^shard]] -> :ok
        _ -> {:error, :identity_conflict}
      end
    end)
  end

  defp retry_at(failures) do
    delay = min(1_000 * Integer.pow(2, min(failures, 5)), 30_000)
    System.system_time(:millisecond) + delay + :rand.uniform(max(div(delay, 5), 1)) - 1
  end

  defp transaction(db, operation) do
    execute!(db, "BEGIN IMMEDIATE")

    try do
      case operation.() do
        {:error, _} = error ->
          execute!(db, "ROLLBACK")
          error

        result ->
          execute!(db, "COMMIT")
          result
      end
    catch
      kind, reason ->
        Sqlite3.execute(db, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp safely(operation) do
    operation.()
  catch
    :throw, {:storage, reason} -> {:error, {:storage, reason}}
  end

  defp execute!(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> throw({:storage, reason})
    end
  end

  defp query(db, sql, parameters) do
    statement =
      case Sqlite3.prepare(db, sql) do
        {:ok, statement} -> statement
        {:error, reason} -> throw({:storage, reason})
      end

    try do
      with :ok <- Sqlite3.bind(statement, parameters),
           {:ok, rows} <- Sqlite3.fetch_all(db, statement) do
        rows
      else
        {:error, reason} -> throw({:storage, reason})
      end
    after
      Sqlite3.release(db, statement)
    end
  end
end
