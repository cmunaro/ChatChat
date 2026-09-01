defmodule ChatchatBroker.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:username])
  end
end
