defmodule ChatchatBroker.Storage.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:username, :string)
    field(:password_hash, :string, redact: true)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec create_changeset(String.t(), String.t()) :: Ecto.Changeset.t()
  def create_changeset(username, password_hash) do
    %__MODULE__{}
    |> change(username: username, password_hash: password_hash)
    |> validate_required([:username, :password_hash])
    |> unique_constraint(:username, message: "username already taken")
  end
end
