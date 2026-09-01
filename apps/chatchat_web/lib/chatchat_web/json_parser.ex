defmodule ChatchatWeb.JSONParser do
  import Plug.Conn

  def init(options), do: Plug.Parsers.init(options)

  def call(conn, options) do
    Plug.Parsers.call(conn, options)
  rescue
    Plug.Parsers.ParseError ->
      body = Jason.encode!(%{error: "malformed JSON request body"})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:bad_request, body)
      |> halt()
  end
end
