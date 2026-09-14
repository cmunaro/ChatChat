defmodule ChatchatWeb.PromEx do
  use PromEx, otp_app: :chatchat_web

  @impl true
  def plugins do
    [
      {PromEx.Plugins.Application, otp_app: :chatchat_web},
      PromEx.Plugins.Beam,
      {PromEx.Plugins.Phoenix, endpoint: ChatchatWeb.Endpoint, router: ChatchatWeb.Router},
      {PromEx.Plugins.Ecto, otp_app: :chatchat_broker, repos: [ChatchatBroker.Repo]}
    ]
  end
end
