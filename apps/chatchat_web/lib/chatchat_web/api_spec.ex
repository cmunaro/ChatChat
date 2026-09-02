defmodule ChatchatWeb.ApiSpec do
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "ChatChat API",
        description: "HTTP API layer",
        version: "0.1.0"
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(ChatchatWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
