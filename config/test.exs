import Config

config :argon2_elixir, t_cost: 1, m_cost: 8

config :chatchat_broker, ChatchatBroker.Repo,
  url: System.get_env("TEST_DATABASE_URL", "ecto://chatchat:chatchat@localhost/chatchat_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :chatchat_web, ChatchatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1234567890123456789012345678901234567890123456789012345678901234",
  server: false

config :logger, level: :warning
