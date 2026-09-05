defmodule ChatchatWeb.Plugs.Authenticate do
  import Plug.Conn

  def init(options), do: options

  def call(conn, _options) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case ChatchatAuth.verify(token) do
          {:ok, user_id} -> assign(conn, :current_user_id, user_id)
          {:error, _reason} -> unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{error: "unauthorized"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, body)
    |> halt()
  end
end
