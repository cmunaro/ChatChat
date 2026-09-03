defmodule ChatchatWeb.AuthController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias ChatchatBroker.Accounts
  alias ChatchatWeb.AuthToken

  alias ChatchatWeb.Schemas.{
    AccessTokenResponse,
    CredentialsRequest,
    ErrorResponse,
    RegistrationErrorsResponse
  }

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
        json(conn, AuthToken.issue(user.id))

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
end
