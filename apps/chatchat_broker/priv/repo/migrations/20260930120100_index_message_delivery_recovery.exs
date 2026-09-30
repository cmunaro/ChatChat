defmodule ChatchatBroker.Repo.Migrations.IndexMessageDeliveryRecovery do
  use Ecto.Migration

  def change do
    create index(:messages, [:receiver_id, :message_id])
  end
end
