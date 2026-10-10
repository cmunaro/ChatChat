defmodule ChatchatTcp.PromEx do
  use PromEx, otp_app: :chatchat_tcp

  @impl true
  def plugins do
    [
      {PromEx.Plugins.Application, otp_app: :chatchat_tcp},
      PromEx.Plugins.Beam,
      {PromEx.Plugins.Ecto, otp_app: :chatchat_broker, repos: [ChatchatBroker.Repo]},
      ChatchatTcp.PromEx.MessagePlugin
    ]
  end
end
