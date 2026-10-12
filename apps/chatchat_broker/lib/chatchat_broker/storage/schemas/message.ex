defmodule ChatchatBroker.Storage.Schemas.Message do
  use Ecto.Schema

  @primary_key false
  schema "messages" do
    field :message_id, Ecto.UUID, primary_key: true
    field :sender_id, :integer, primary_key: true
    field :receiver_id, :integer
    field :kind, :string, default: "message"
    field :payload, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
