import Config

if config_env() == :prod do
  release_name = System.fetch_env!("RELEASE_NAME")

  if release_name in ["chatchat_web", "chatchat_broker"] do
    database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is required"

    config :chatchat_broker, ChatchatBroker.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  end

  if release_name in ["chatchat_web", "chatchat_tcp"] do
    secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is required"
    config :chatchat_auth, secret_key_base: secret_key_base

    if release_name == "chatchat_web" do
      config :chatchat_web, ChatchatWeb.Endpoint,
        http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
        secret_key_base: secret_key_base
    end
  end

  if release_name == "chatchat_tcp" do
    config :chatchat_tcp,
      server: [
        transport_options: [ip: {0, 0, 0, 0}],
        port: String.to_integer(System.get_env("TCP_PORT", "4040")),
        read_timeout: String.to_integer(System.get_env("TCP_READ_TIMEOUT", "60000"))
      ]
  end
end
