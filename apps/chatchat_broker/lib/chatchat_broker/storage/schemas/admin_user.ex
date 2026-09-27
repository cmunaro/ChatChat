defmodule ChatchatBroker.Storage.Schemas.AdminUser do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:user_id, :id, autogenerate: false}
  schema "admin_users" do
  end
end
