defmodule ChatchatClient.Store do
  @moduledoc "Pure per-client retry and deduplication state. No process or shared storage."

  @page_size 128
  @outbox_limit 128

  def new(user_id) do
    %{
      user_id: user_id,
      outbox: :gb_trees.empty(),
      pending: :gb_trees.empty(),
      inbox: :gb_trees.empty(),
      suspension: nil
    }
  end

  def put_outbox(store, receiver, payload, id \\ Ecto.UUID.generate()) do
    with :ok <- validate_message(store.user_id, receiver, id, payload) do
      case :gb_trees.lookup(id, store.outbox) do
        :none ->
          entry = %{
            message_id: id,
            receiver_id: receiver,
            payload: payload,
            request_id: nil,
            rejection: nil,
            retry_at: 0,
            failures: 0
          }

          if :gb_trees.size(store.outbox) < @outbox_limit,
            do: {:ok, id, put_entry(store, entry)},
            else: {:error, :capacity}

        {:value, %{receiver_id: ^receiver, payload: ^payload}} ->
          {:ok, id, store}

        _ ->
          {:error, :identity_conflict}
      end
    end
  end

  def receive_message(store, sender, id, payload, timestamp) do
    with :ok <- validate_message(sender, store.user_id, id, payload),
         true <- is_binary(timestamp) and byte_size(timestamp) <= 64,
         {:ok, _datetime, 0} <- DateTime.from_iso8601(timestamp) do
      key = {sender, id}

      case :gb_trees.lookup(key, store.inbox) do
        :none ->
          inbox = :gb_trees.insert(key, [sender, id, payload, timestamp], store.inbox)
          {:ok, :saved, %{store | inbox: inbox}}

        {:value, [^sender, ^id, ^payload, _]} ->
          {:ok, :duplicate, store}

        _ ->
          {:error, :identity_conflict}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  def pending(store, limit \\ @page_size) when limit > 0 and limit <= @page_size do
    if store.suspension do
      []
    else
      store.pending
      |> :gb_trees.iterator()
      |> page(limit, fn {time, _id} -> time <= System.system_time(:millisecond) end)
    end
  end

  def begin_attempt(store, id, request) do
    with {:ok, ^request} <- Ecto.UUID.cast(request),
         nil <- store.suspension,
         {:value, %{rejection: nil} = entry} <- :gb_trees.lookup(id, store.outbox) do
      entry = %{entry | request_id: request, retry_at: System.system_time(:millisecond) + 10_000}
      {:ok, put_entry(store, entry)}
    else
      _ -> {:error, :not_pending}
    end
  end

  def result(store, id, request, status, reason \\ nil)
      when status in [:ok, :failed, :rejected] do
    case :gb_trees.lookup(id, store.outbox) do
      {:value, %{request_id: ^request} = entry} when not is_nil(request) ->
        store =
          case status do
            :ok ->
              delete_entry(store, entry)

            :failed ->
              put_entry(store, %{
                entry
                | request_id: nil,
                  retry_at: retry_at(entry.failures),
                  failures: min(entry.failures + 1, 6)
              })

            :rejected ->
              put_entry(store, %{entry | request_id: nil, rejection: reason || "rejected"})
          end

        {:ok, store}

      _ ->
        {:error, :unmatched_result}
    end
  end

  def suspend(store, reason) when is_binary(reason) and byte_size(reason) <= 256,
    do: %{store | suspension: reason}

  def resume(store), do: %{store | suspension: nil}

  def outbox(store, cursor \\ "", limit \\ @page_size) when limit > 0 and limit <= @page_size do
    store.outbox
    |> after_page(cursor, limit)
    |> Enum.map(fn entry ->
      [entry.message_id, entry.receiver_id, entry.payload, entry.rejection]
    end)
  end

  def inbox(store, cursor \\ nil, limit \\ @page_size) when limit > 0 and limit <= @page_size,
    do: after_page(store.inbox, cursor || {0, ""}, limit)

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

  defp put_entry(store, entry) do
    store =
      case :gb_trees.lookup(entry.message_id, store.outbox) do
        {:value, previous} -> delete_entry(store, previous)
        :none -> store
      end

    pending =
      if is_nil(entry.rejection),
        do: :gb_trees.enter({entry.retry_at, entry.message_id}, entry, store.pending),
        else: store.pending

    %{store | outbox: :gb_trees.enter(entry.message_id, entry, store.outbox), pending: pending}
  end

  defp delete_entry(store, entry) do
    %{
      store
      | outbox: :gb_trees.delete_any(entry.message_id, store.outbox),
        pending: :gb_trees.delete_any({entry.retry_at, entry.message_id}, store.pending)
    }
  end

  defp after_page(tree, cursor, limit) do
    iterator = :gb_trees.iterator_from(cursor, tree)

    iterator =
      case :gb_trees.next(iterator) do
        {^cursor, _value, rest} -> rest
        _ -> iterator
      end

    page(iterator, limit, fn _key -> true end)
  end

  defp page(_iterator, 0, _eligible), do: []

  defp page(iterator, limit, eligible) do
    case :gb_trees.next(iterator) do
      :none ->
        []

      {key, value, rest} ->
        if eligible.(key), do: [value | page(rest, limit - 1, eligible)], else: []
    end
  end

  defp retry_at(failures) do
    delay = min(1_000 * Integer.pow(2, min(failures, 5)), 30_000)
    System.system_time(:millisecond) + delay + :rand.uniform(max(div(delay, 5), 1)) - 1
  end
end
