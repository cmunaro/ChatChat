defmodule ChatchatWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(OpenApiSpex.Plug.PutApiSpec, module: ChatchatWeb.ApiSpec)
  end

  scope "/api", ChatchatWeb do
    pipe_through(:api)

    post("/register", AuthController, :register)
    post("/login", AuthController, :login)
  end

  scope "/" do
    pipe_through(:api)

    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"
  end
end
