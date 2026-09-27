defmodule ChatchatWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(OpenApiSpex.Plug.PutApiSpec, module: ChatchatWeb.ApiSpec)
  end

  pipeline :authenticated do
    plug(ChatchatWeb.Plugs.Authenticate)
  end

  pipeline :admin_authenticated do
    plug(ChatchatWeb.Admin.Auth)
  end

  scope "/api", ChatchatWeb do
    pipe_through(:api)

    post("/register", AuthController, :register)
    post("/login", AuthController, :login)
  end

  scope "/api", ChatchatWeb do
    pipe_through([:api, :authenticated])

    get("/user/search", UserController, :search)
  end

  scope "/" do
    pipe_through(:api)

    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/openapi")
  end

  scope "/admin", ChatchatWeb.Admin do
    pipe_through(:browser)

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
  end

  scope "/admin", ChatchatWeb.Admin do
    pipe_through([:browser, :admin_authenticated])

    post("/logout", SessionController, :delete)

    live_session :admin, on_mount: [{ChatchatWeb.Admin.Auth, :ensure_authenticated}] do
      live("/", OverviewLive, :index)
    end
  end
end
