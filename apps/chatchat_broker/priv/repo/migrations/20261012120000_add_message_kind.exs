defmodule ChatchatBroker.Repo.Migrations.AddMessageKind do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :kind, :string, null: false, default: "message"
    end

    create constraint(:messages, :messages_kind_check, check: "kind IN ('message', 'delete')")
  end
end
