defmodule ChatchatBroker.Storage.AccountsStore do
  alias ChatchatBroker.Domain.User
  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.User, as: UserRecord

  @spec insert_user(String.t(), String.t()) :: {:ok, User.t()} | {:error, [String.t()]}
  def insert_user(username, password_hash) do
    username
    |> UserRecord.create_changeset(password_hash)
    |> Repo.insert()
    |> case do
      {:ok, record} -> {:ok, to_domain(record)}
      {:error, changeset} -> {:error, error_messages(changeset)}
    end
  end

  @spec fetch_credentials(String.t()) :: {:ok, User.t(), String.t()} | :error
  def fetch_credentials(username) do
    case Repo.get_by(UserRecord, username: username) do
      %UserRecord{} = record -> {:ok, to_domain(record), record.password_hash}
      nil -> :error
    end
  end

  defp to_domain(record) do
    %User{
      id: record.id,
      username: record.username,
      inserted_at: record.inserted_at
    }
  end

  defp error_messages(changeset) do
    Enum.map(changeset.errors, fn {_field, {message, _options}} -> message end)
  end
end
