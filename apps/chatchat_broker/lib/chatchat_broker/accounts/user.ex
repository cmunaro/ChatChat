defmodule ChatchatBroker.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @username_regex ~r/^[a-zA-Z0-9_]+$/

  schema "users" do
    field(:username, :string)
    field(:password_hash, :string, redact: true)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def registration_changeset(user, username) do
    user
    |> cast(%{username: username}, [:username])
    |> update_change(:username, &String.trim/1)
    |> validate_required(:username)
    |> validate_length(:username,
      min: 3,
      max: 32,
      message: "username must be from 3 to 32 chars long"
    )
    |> validate_format(:username, @username_regex, message: "invalid char in username")
    |> unique_constraint(:username, message: "username already taken")
  end
end
