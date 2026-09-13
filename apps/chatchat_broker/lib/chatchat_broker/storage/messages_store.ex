defmodule ChatchatBroker.Storage.MessagesStore do
  import Ecto.Query

  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.Message

  @spec insert_all([map()]) :: :ok
  def insert_all(messages) do
    Repo.insert_all(Message, messages,
      on_conflict: :nothing,
      conflict_target: [:message_id]
    )

    :ok
  end

  @spec for_receiver(pos_integer()) :: [struct()]
  def for_receiver(receiver_id) do
    Message
    |> where([message], message.receiver_id == ^receiver_id)
    |> order_by([message], asc: message.inserted_at, asc: message.message_id)
    |> Repo.all()
  end

  @spec delete_for_receiver(pos_integer(), Ecto.UUID.t()) :: :ok | {:error, :unknown_message}
  def delete_for_receiver(receiver_id, message_id) do
    {deleted, _messages} =
      Message
      |> where([message], message.receiver_id == ^receiver_id)
      |> where([message], message.message_id == ^message_id)
      |> Repo.delete_all()

    if deleted == 1, do: :ok, else: {:error, :unknown_message}
  end
end
