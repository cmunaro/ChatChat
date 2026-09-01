defmodule ChatchatWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", ChatchatWeb do
    pipe_through(:api)

    post("/register", AuthController, :register)
    post("/login", AuthController, :login)
  end
end
