defmodule ChatchatBroker.Repo.Migrations.RemoveUpdateTimeFromUser do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :updated_at, :utc_datetime_usec
    end
  end
end
