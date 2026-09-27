defmodule ChatchatBroker.Storage.AccountsStore do
  import Ecto.Query

  alias ChatchatBroker.Domain.User
  alias ChatchatBroker.Domain.UserSearchResult
  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.AdminUser
  alias ChatchatBroker.Storage.Schemas.User, as: UserRecord

  @spec insert_user(String.t(), String.t()) :: {:ok, User.t()} | {:error, [String.t()]}
  def insert_user(username, password_hash) do
    username
    |> UserRecord.create_changeset(password_hash)
    |> Repo.insert()
    |> case do
      {:ok, record} -> {:ok, to_user_domain(record)}
      {:error, changeset} -> {:error, error_messages(changeset)}
    end
  end

  @spec insert_admin(String.t(), String.t()) :: {:ok, User.t()} | {:error, [String.t()]}
  def insert_admin(username, password_hash) do
    Repo.transaction(fn ->
      case insert_user(username, password_hash) do
        {:ok, user} ->
          Repo.insert!(%AdminUser{user_id: user.id})
          user

        {:error, errors} ->
          Repo.rollback(errors)
      end
    end)
  end

  @spec fetch_credentials(String.t()) :: {:ok, User.t(), String.t()} | :error
  def fetch_credentials(username) do
    case Repo.get_by(UserRecord, username: username) do
      %UserRecord{} = record -> {:ok, to_user_domain(record), record.password_hash}
      nil -> :error
    end
  end

  @spec search_user(String.t()) :: [UserSearchResult.t()]
  def search_user(name) do
    downcase_name = String.downcase(name)

    UserRecord
    |> where([user], fragment("position(? in lower(?)) > 0", ^downcase_name, user.username))
    |> order_by([user],
      asc: fragment("lower(?)", user.username),
      asc: user.username,
      asc: user.id
    )
    |> limit(20)
    |> select([user], {user.username, user.id})
    |> Repo.all()
    |> Enum.map(fn {username, id} ->
      %UserSearchResult{username: username, id: id}
    end)
  end

  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(UserRecord, :count, :id)

  @spec admin?(pos_integer()) :: boolean()
  def admin?(user_id),
    do: Repo.exists?(from(admin in AdminUser, where: admin.user_id == ^user_id))

  defp to_user_domain(%UserRecord{} = record) do
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
