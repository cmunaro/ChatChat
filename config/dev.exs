import Config

config :chatchat_broker, ChatchatBroker.Repo,
  url: System.get_env("DATABASE_URL", "ecto://chatchat:chatchat@localhost/chatchat_dev"),
  pool_size: 10,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :chatchat_web, ChatchatWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: System.get_env(
    "SECRET_KEY_BASE",
    "1234567890123456789012345678901234567890123456789012345678901234"
  ),
  server: true,
  check_origin: false,
  code_reloader: false,
  debug_errors: true

config :logger, :default_formatter, format: "[$level] $message\n"
