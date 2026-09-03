defmodule ChatchatWeb.UserController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

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
      ok: {"Matching users", "application/json", %OpenApiSpex.Schema{type: :array}},
      unauthorized:
        {"Missing, invalid, or expired access token", "application/json",
         ChatchatWeb.Schemas.ErrorResponse}
    ]
  )

  def search(conn, %{"name" => _name}) do
    json(conn, [])
  end
end
