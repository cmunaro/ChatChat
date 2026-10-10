import Config

secret_key_base =
  System.get_env(
    "SECRET_KEY_BASE",
    "1234567890123456789012345678901234567890123456789012345678901234"
  )

config :chatchat_auth, secret_key_base: secret_key_base

config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache

# Local Docker services use the standard PostgreSQL and Redis ports.
# Keep development state separate from the test database and Redis DB 15.
redis_url = System.get_env("REDIS_URL", "redis://localhost:6379/0")
config :chatchat_tcp, redis_url: redis_url
config :chatchat_web, redis_url: redis_url

config :chatchat_broker, ChatchatBroker.Repo,
  url: System.get_env("DATABASE_URL", "ecto://chatchat:chatchat@localhost:5432/chatchat_dev"),
  pool_size: 10,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :chatchat_web, ChatchatWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: secret_key_base,
  server: true,
  check_origin: false,
  debug_errors: true,
  code_reloader: true

config :logger, :default_formatter, format: "[$level] $message\n"
