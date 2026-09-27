defmodule ChatchatWeb.Admin.SessionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias ChatchatBroker.Accounts
  alias ChatchatWeb.Admin.SessionHTML

  def new(conn, _params), do: render_login(conn, nil, :ok)

  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_admin(username, password) do
      {:ok, admin} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:admin_user_id, admin.id)
        |> redirect(to: "/admin")

      {:error, :invalid_credentials} ->
        render_login(conn, "Invalid username or password", :unauthorized)
    end
  end

  def create(conn, _params),
    do: render_login(conn, "Username and password are required", :bad_request)

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: "/admin/login")
  end

  defp render_login(conn, error, status) do
    conn
    |> put_status(status)
    |> put_view(html: SessionHTML)
    |> render(:new, error: error)
  end
end
