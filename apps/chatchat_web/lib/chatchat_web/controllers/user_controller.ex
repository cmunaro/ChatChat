defmodule ChatchatWeb.UserController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias ChatchatBroker.Accounts
  alias ChatchatWeb.Schemas.{ErrorResponse, UserSearchResults}

  tags(["Users"])
  security([%{"bearerAuth" => []}])

  operation(:search,
    summary: "Search a user",
    description: "Search a user by username.",
    operation_id: "searchUser",
    parameters: [
      name: [in: :query, type: :string, required: true, description: "Username to search"]
    ],
    responses: [
      ok: {"Matching users", "application/json", UserSearchResults},
      unauthorized:
        {"Missing, invalid, or expired access token", "application/json", ErrorResponse}
    ]
  )

  def search(conn, %{"name" => name}) do
    case Accounts.search_user(name) do
      {:ok, users} ->
        results =
          Enum.map(users, fn user ->
            %{id: user.id, username: user.username}
          end)

        conn
        |> put_status(:ok)
        |> json(results)

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: error})
    end
  end

  def search(conn, _) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing name"})
  end
end
