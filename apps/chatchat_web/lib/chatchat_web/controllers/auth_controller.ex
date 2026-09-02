defmodule ChatchatWeb.AuthController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias ChatchatBroker.Accounts

  alias ChatchatWeb.Schemas.{
    AccessTokenResponse,
    CredentialsRequest,
    ErrorResponse,
    RegistrationErrorsResponse
  }

  @token_salt "user authentication"
  @token_max_age 15 * 60

  tags(["Authentication"])

  operation(:register,
    summary: "Register an account",
    description: "Creates an account when the username is not already registered.",
    operation_id: "registerAccount",
    request_body: {"Registration credentials", "application/json", CredentialsRequest},
    responses: [
      no_content: "Account created",
      bad_request: {"Malformed JSON request body", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid credentials or username already registered", "application/json",
         RegistrationErrorsResponse}
    ]
  )

  def register(conn, %{"username" => username, "password" => password}) do
    case Accounts.register_user(username, password) do
      {:ok, _user} ->
        conn
        |> put_status(:created)
        |> send_resp(:no_content, "")

      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{credentials: ["username and password are required"]}})
  end

  operation(:login,
    summary: "Log in",
    description: "Authenticates an account and returns a signed access token.",
    operation_id: "login",
    request_body: {"Account credentials", "application/json", CredentialsRequest},
    responses: [
      ok: {"Authenticated", "application/json", AccessTokenResponse},
      bad_request: {"Malformed JSON request body", "application/json", ErrorResponse},
      unauthorized: {"Invalid credentials", "application/json", ErrorResponse}
    ]
  )

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

  defp access_token_expires_at do
    DateTime.utc_now()
    |> DateTime.add(@token_max_age, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
