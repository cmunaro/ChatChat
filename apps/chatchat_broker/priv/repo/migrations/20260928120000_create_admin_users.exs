defmodule ChatchatBroker.Repo.Migrations.CreateAdminUsers do
  use Ecto.Migration

  def change do
    create table(:admin_users, primary_key: false) do
      add(:user_id, references(:users, on_delete: :delete_all), primary_key: true)
    end
  end
end
