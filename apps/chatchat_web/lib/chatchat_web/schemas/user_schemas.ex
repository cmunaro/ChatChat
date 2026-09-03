defmodule ChatchatWeb.Schemas.UserSearchResult do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserSearchResult",
    description: "Public user information returned by username search.",
    type: :object,
    additionalProperties: false,
    properties: %{
      id: %Schema{type: :integer, minimum: 1},
      username: %Schema{type: :string, minLength: 3, maxLength: 32}
    },
    required: [:id, :username]
  })
end

defmodule ChatchatWeb.Schemas.UserSearchResults do
  alias ChatchatWeb.Schemas.UserSearchResult
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserSearchResults",
    description: "Up to 20 users whose usernames contain the search term.",
    type: :array,
    maxItems: 20,
    items: UserSearchResult
  })
end
