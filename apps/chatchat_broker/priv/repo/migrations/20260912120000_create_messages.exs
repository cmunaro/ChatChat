defmodule ChatchatBroker.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :message_id, :uuid, primary_key: true
      add :sender_id, references(:users, on_delete: :delete_all), null: false
      add :receiver_id, references(:users, on_delete: :delete_all), null: false
      add :payload, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:receiver_id, :inserted_at, :message_id])
  end
end
