defmodule ChatchatBroker.Repo.Migrations.CompositeMessageIdentity do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE messages DROP CONSTRAINT messages_pkey"
    execute "ALTER TABLE messages ADD PRIMARY KEY (sender_id, message_id)"
    create index(:messages, [:receiver_id, :sender_id, :message_id])
  end

  def down do
    # Refuse rollback if equal UUIDs from different senders exist; never discard rows.
    execute "ALTER TABLE messages DROP CONSTRAINT messages_pkey"
    execute "ALTER TABLE messages ADD PRIMARY KEY (message_id)"
    drop index(:messages, [:receiver_id, :sender_id, :message_id])
  end
end
