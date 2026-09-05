import Config

secret_key_base = "1234567890123456789012345678901234567890123456789012345678901234"

config :chatchat_auth, secret_key_base: secret_key_base

config :chatchat_tcp,
  server: [transport_options: [ip: {127, 0, 0, 1}], port: 0, read_timeout: 1_000],
  handler: [authentication_timeout: 100, max_frame_size: 1_024]

config :argon2_elixir, t_cost: 1, m_cost: 8

config :chatchat_broker, ChatchatBroker.Repo,
  url: System.get_env("TEST_DATABASE_URL", "ecto://chatchat:chatchat@localhost/chatchat_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :chatchat_web, ChatchatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false

config :logger, level: :warning
