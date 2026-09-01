defmodule ChatchatBroker.Accounts do
  import Ecto.Changeset

  alias ChatchatBroker.Accounts.User
  alias ChatchatBroker.Repo

  @password_min_length 8
  @password_max_length 128

  @spec register_user(term(), term()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(username, password) do
    changeset =
      %User{}
      |> User.registration_changeset(username)
      |> validate_password(password)

    if changeset.valid? do
      changeset
      |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
      |> Repo.insert()
    else
      {:error, changeset}
    end
  end

  @spec authenticate_user(term(), term()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(username, password) when is_binary(username) and is_binary(password) do
    case Repo.get_by(User, username: String.trim(username)) do
      %User{} = user -> verify_password(user, password)
      nil -> {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_username, _password) do
    Argon2.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp validate_password(changeset, password) when is_binary(password) do
    if String.length(password) in @password_min_length..@password_max_length do
      changeset
    else
      add_error(
        changeset,
        :password,
        "password must be from #{@password_min_length} to #{@password_max_length} chars long"
      )
    end
  end

  defp validate_password(changeset, _password) do
    add_error(
      changeset,
      :password,
      "password must be from #{@password_min_length} to #{@password_max_length} chars long"
    )
  end

  @spec verify_password(User.t(), binary()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  defp verify_password(user, password) do
    if Argon2.verify_pass(password, user.password_hash) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end
end
