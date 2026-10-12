defmodule ChatchatBroker.Storage.MessagesStore do
  import Ecto.Query

  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.Message

  @max_page 128
  @timeout 5_000

  @doc "Commits pending ownership, checking immutable content on identical retries."
  def insert_pending(attributes, timeout \\ @timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @timeout do
    insert_pending_before(attributes, System.monotonic_time(:millisecond) + timeout)
  end

  @doc "Commits within one absolute budget; expired work never starts a write."
  def insert_pending_before(attributes, deadline) when is_integer(deadline) do
    deadline = min(deadline, System.monotonic_time(:millisecond) + @timeout)

    if deadline <= System.monotonic_time(:millisecond),
      do: {:error, :deadline},
      else: insert_before(attributes, deadline)
  end

  defp insert_before(attributes, deadline) do
    attributes = Map.take(attributes, [:sender_id, :message_id, :receiver_id, :payload, :kind])
    attributes = Map.put_new(attributes, :kind, "message")
    attributes = Map.put(attributes, :inserted_at, DateTime.utc_now())

    Repo.transaction(
      fn ->
        Repo.insert_all(
          Message,
          [attributes],
          [on_conflict: :nothing, conflict_target: [:sender_id, :message_id]] ++
            write_options(deadline)
        )

        stored =
          Message
          |> where(
            [m],
            m.sender_id == ^attributes.sender_id and m.message_id == ^attributes.message_id
          )
          |> lock("FOR UPDATE")
          |> Repo.one!(write_options(deadline))

        cond do
          stored.receiver_id != attributes.receiver_id ->
            Repo.rollback(:identity_conflict)

          attributes.kind == "delete" ->
            stored
            |> Ecto.Changeset.change(kind: "delete", payload: "")
            |> Repo.update!(write_options(deadline))

          stored.kind == attributes.kind and stored.payload == attributes.payload ->
            stored

          true ->
            Repo.rollback(:identity_conflict)
        end
      end,
      timeout: max(deadline - System.monotonic_time(:millisecond), 1),
      deadline: deadline,
      queue: false
    )
  rescue
    error in Postgrex.Error ->
      if error.postgres[:constraint] == "messages_receiver_id_fkey",
        do: {:error, :invalid_receiver},
        else: {:error, :unavailable}

    _error in [DBConnection.ConnectionError, Ecto.NoResultsError] ->
      {:error, :unavailable}
  end

  defp write_options(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:deadline)
    [timeout: remaining, deadline: deadline, queue: false]
  end

  @doc "Bounded composite-identity page. Call with nil after an empty page to wrap."
  def pending_page(receiver_id, cursor \\ nil, limit \\ @max_page)
      when is_integer(receiver_id) and receiver_id > 0 and is_integer(limit) and limit > 0 and
             limit <= @max_page do
    query =
      from m in Message,
        where: m.receiver_id == ^receiver_id,
        order_by: [asc: m.sender_id, asc: m.message_id],
        limit: ^limit

    query =
      case cursor do
        nil ->
          query

        {sender_id, message_id} ->
          from m in query,
            where:
              m.sender_id > ^sender_id or
                (m.sender_id == ^sender_id and m.message_id > ^message_id)
      end

    Repo.all(query, timeout: @timeout)
  end

  def delete_for_receiver(receiver_id, sender_id, message_id, kind \\ "message") do
    from(m in Message,
      where:
        m.receiver_id == ^receiver_id and m.sender_id == ^sender_id and
          m.message_id == ^message_id and m.kind == ^kind
    )
    |> Repo.delete_all(timeout: @timeout)

    :ok
  end

  @spec count_undelivered() :: non_neg_integer()
  def count_undelivered, do: Repo.aggregate(Message, :count, :message_id)

  @spec count_undelivered(pos_integer()) :: non_neg_integer()
  def count_undelivered(timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @timeout,
      do: Repo.aggregate(Message, :count, :message_id, timeout: timeout)
end
