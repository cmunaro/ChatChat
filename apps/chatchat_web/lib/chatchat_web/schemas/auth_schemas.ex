defmodule ChatchatWeb.Schemas.CredentialsRequest do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CredentialsRequest",
    description: "Credentials supplied for registration or login.",
    type: :object,
    additionalProperties: false,
    properties: %{
      username: %Schema{
        type: :string,
        minLength: 3,
        maxLength: 32,
        pattern: "^[a-zA-Z0-9_]+$",
        example: "alice"
      },
      password: %Schema{
        type: :string,
        minLength: 8,
        maxLength: 128,
        format: :password,
        writeOnly: true,
        example: "password123"
      }
    },
    required: [:username, :password]
  })
end

defmodule ChatchatWeb.Schemas.AccessTokenResponse do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AccessTokenResponse",
    description: "A signed access token and its absolute expiration time.",
    type: :object,
    additionalProperties: false,
    properties: %{
      access_token: %Schema{type: :string, description: "Signed Phoenix access token"},
      expires_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "UTC expiration timestamp"
      }
    },
    required: [:access_token, :expires_at]
  })
end

defmodule ChatchatWeb.Schemas.ErrorResponse do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ErrorResponse",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "invalid credentials"}
    },
    required: [:error]
  })
end

defmodule ChatchatWeb.Schemas.RegistrationErrorsResponse do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RegistrationErrorsResponse",
    description: "Registration validation errors.",
    type: :object,
    properties: %{
      errors: %Schema{
        oneOf: [
          %Schema{type: :array, items: %Schema{type: :string}},
          %Schema{type: :object, additionalProperties: true}
        ]
      }
    },
    required: [:errors]
  })
end
