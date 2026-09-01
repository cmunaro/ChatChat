defmodule ChatchatBroker.Repo do
  use Ecto.Repo,
    otp_app: :chatchat_broker,
    adapter: Ecto.Adapters.Postgres
end
