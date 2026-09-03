import Config

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is required"

  config :chatchat_broker, ChatchatBroker.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  if System.get_env("RELEASE_NAME") == "chatchat_web" do
    secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is required"

    config :chatchat_web, ChatchatWeb.Endpoint,
      http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
      secret_key_base: secret_key_base
  end
end
