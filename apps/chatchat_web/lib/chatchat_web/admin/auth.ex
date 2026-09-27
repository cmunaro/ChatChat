defmodule ChatchatWeb.Admin.Auth do
  @moduledoc false

  import Plug.Conn

  alias ChatchatBroker.Accounts

  @session_key :admin_user_id

  def init(options), do: options

  def call(conn, _options) do
    case get_session(conn, @session_key) do
      user_id when is_integer(user_id) -> authorize(conn, user_id)
      _missing -> reject(conn)
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    user_id = session[Atom.to_string(@session_key)] || session[@session_key]

    if Accounts.admin?(user_id) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
    end
  end

  defp authorize(conn, user_id) do
    if Accounts.admin?(user_id), do: conn, else: reject(conn)
  end

  defp reject(conn) do
    conn
    |> clear_session()
    |> Phoenix.Controller.redirect(to: "/admin/login")
    |> halt()
  end
end
