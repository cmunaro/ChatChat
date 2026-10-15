defmodule ChatchatBroker.Repo.Migrations.AddMessageEditKind do
  use Ecto.Migration

  def up do
    drop constraint(:messages, :messages_kind_check)

    create constraint(:messages, :messages_kind_check,
             check: "kind IN ('message', 'delete', 'edit')"
           )
  end

  def down do
    # Refuse rollback while pending edits exist rather than discard their content.
    drop constraint(:messages, :messages_kind_check)
    create constraint(:messages, :messages_kind_check, check: "kind IN ('message', 'delete')")
  end
end
