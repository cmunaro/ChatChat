defmodule ChatchatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chatchat_web

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(ChatchatWeb.JSONParser,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()
  )

  plug(ChatchatWeb.Router)
end
