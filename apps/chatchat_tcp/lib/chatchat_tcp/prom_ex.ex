defmodule ChatchatTcp.PromEx do
  use PromEx, otp_app: :chatchat_tcp

  @impl true
  def plugins do
    [
      {PromEx.Plugins.Application, otp_app: :chatchat_tcp},
      PromEx.Plugins.Beam,
      ChatchatTcp.PromEx.MessagePlugin
    ]
  end
end
