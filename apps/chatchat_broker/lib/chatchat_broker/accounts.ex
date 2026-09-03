defmodule ChatchatBroker.Accounts do
  alias ChatchatBroker.Domain.UserSearchResult
  alias ChatchatBroker.Domain.{Password, User, Username}
  alias ChatchatBroker.Storage.AccountsStore

  @spec register_user(term(), term()) :: {:ok, User.t()} | {:error, [String.t()]}
  def register_user(username, password) do
    with {:ok, username} <- Username.validate(username),
         :ok <- Password.validate(password) do
      AccountsStore.insert_user(username, Password.hash(password))
    else
      {:error, message} -> {:error, [message]}
    end
  end

  @spec authenticate_user(term(), term()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(username, password) when is_binary(password) do
    with {:ok, username} <- Username.normalize(username),
         {:ok, user, password_hash} <- AccountsStore.fetch_credentials(username),
         true <- Password.valid?(password, password_hash) do
      {:ok, user}
    else
      :error -> invalid_credentials()
      false -> {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_username, _password), do: invalid_credentials()

  @spec search_user(term()) :: {:ok, [UserSearchResult.t()]} | {:error, String.t()}
  def search_user(name) when is_binary(name) do
    {:ok, normalized_name} = Username.normalize(name)

    if String.length(normalized_name) < 3 do
      {:error, "name too short"}
    else
      case Username.validate(name) do
        {:ok, username} -> {:ok, AccountsStore.search_user(username)}
        {:error, _} -> {:error, "invalid name"}
      end
    end
  end

  def search_user(_), do: {:error, "invalid name"}

  defp invalid_credentials do
    Password.simulate_verify()
    {:error, :invalid_credentials}
  end
end
