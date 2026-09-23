import Config

if config_env() == :prod do
  config :argon2_elixir,
    parallelism: 12

  release_name = System.fetch_env!("RELEASE_NAME")

  if release_name in ["chatchat_web", "chatchat_broker", "chatchat_tcp"] do
    database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is required"

    config :chatchat_broker, ChatchatBroker.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  end

  if release_name in ["chatchat_web", "chatchat_tcp", "chatchat_client"] do
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
      redis_url: System.get_env("REDIS_URL", "redis://localhost:6379"),
      metrics_server: [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("METRICS_PORT", "9568"))
      ],
      admission: [
        pending_ttl: String.to_integer(System.get_env("ADMISSION_TTL", "60000")),
        delivery_window: String.to_integer(System.get_env("DELIVERY_WINDOW", "20000")),
        persistence_batch_size:
          String.to_integer(System.get_env("PERSISTENCE_BATCH_SIZE", "500")),
        persistence_retry_interval:
          String.to_integer(System.get_env("PERSISTENCE_RETRY_INTERVAL", "1000"))
      ],
      server: [
        transport_options: [ip: {0, 0, 0, 0}],
        port: String.to_integer(System.get_env("TCP_PORT", "4040")),
        read_timeout: String.to_integer(System.get_env("TCP_READ_TIMEOUT", "60000"))
      ]
  end

  if release_name == "chatchat_client" do
    load_generator_id = System.fetch_env!("HOSTNAME")
    run_id = System.get_env("LOAD_TEST_RUN_ID", "default")

    config :chatchat_client,
      http_url: System.get_env("HTTP_URL", "http://web:4000"),
      tcp_host: System.get_env("TCP_HOST", "tcp"),
      tcp_port: String.to_integer(System.get_env("TCP_PORT", "4040")),
      request_timeout: String.to_integer(System.get_env("CLIENT_REQUEST_TIMEOUT", "60000")),
      load_generator: [
        id: load_generator_id,
        clients: String.to_integer(System.get_env("CLIENTS_PER_LOADGEN", "50000")),
        participants: String.to_integer(System.get_env("LOADGEN_PARTICIPANTS", "10")),
        first_user_id: String.to_integer(System.get_env("LOAD_TEST_FIRST_USER_ID", "1500000001")),
        barrier_directory: "/barrier/#{run_id}",
        connect_timeout_seconds:
          String.to_integer(System.get_env("LOAD_TEST_CONNECT_TIMEOUT_SECONDS", "21600")),
        creation_concurrency:
          String.to_integer(System.get_env("CLIENT_CREATION_CONCURRENCY", "40")),
        ramp_interval_ms: String.to_integer(System.get_env("CLIENT_RAMP_INTERVAL_MS", "5")),
        duration_seconds: String.to_integer(System.get_env("LOAD_TEST_DURATION_SECONDS", "300")),
        send_probability: String.to_float(System.get_env("SEND_PROBABILITY", "1.0")),
        disconnection_probability:
          String.to_float(System.get_env("DISCONNECTION_PROBABILITY", "0.15")),
        message_payload_size: String.to_integer(System.get_env("MESSAGE_PAYLOAD_SIZE", "128"))
      ]
  end
end
