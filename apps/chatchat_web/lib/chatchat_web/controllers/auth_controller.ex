defmodule ChatchatWeb.AuthController do
  use Phoenix.Controller, formats: [:json]
  alias ChatchatBroker.Accounts

  @token_salt "user authentication"
  @token_max_age 15 * 60

  def register(conn, %{"username" => username, "password" => password}) do
    case Accounts.register_user(username, password) do
      {:ok, _user} ->
        conn
        |> put_status(:created)
        |> send_resp(:no_content, "")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: get_errors(changeset)})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{credentials: ["username and password are required"]}})
  end

  def login(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        token = Phoenix.Token.sign(ChatchatWeb.Endpoint, @token_salt, user.id)

        json(conn, %{
          access_token: token,
          expires_at: access_token_expires_at()
        })

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid credentials"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "invalid credentials"})
  end

  def verify_access_token(token) do
    Phoenix.Token.verify(ChatchatWeb.Endpoint, @token_salt, token, max_age: @token_max_age)
  end

  defp get_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {_field, {message, _opts}} ->
      message
    end)
  end

  defp access_token_expires_at do
    DateTime.utc_now()
    |> DateTime.add(@token_max_age, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
