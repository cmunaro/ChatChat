defmodule ChatchatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chatchat_web

  @session_options [
    store: :cookie,
    key: "_chatchat_web_key",
    signing_salt: "chatchat-live"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ["phoenix.min.js"]
  )

  plug(Plug.Static,
    at: "/assets/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ["phoenix_live_view.min.js"]
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(PromEx.Plug, prom_ex_module: ChatchatWeb.PromEx)

  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(ChatchatWeb.JSONParser,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.Session, @session_options)

  plug(ChatchatWeb.Router)
end
