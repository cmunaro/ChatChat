defmodule ChatchatBroker.Storage.Schemas.Message do
  use Ecto.Schema

  @primary_key {:message_id, Ecto.UUID, autogenerate: false}
  schema "messages" do
    field :sender_id, :integer
    field :receiver_id, :integer
    field :payload, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
