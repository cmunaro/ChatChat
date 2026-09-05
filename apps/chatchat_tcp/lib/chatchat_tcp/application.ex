defmodule ChatchatTcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    tcp_options = Application.fetch_env!(:chatchat_tcp, :server)

    children = [
      {Registry, keys: :duplicate, name: ChatchatTcp.Presence.Registry},
      {ThousandIsland,
       Keyword.merge(tcp_options,
         handler_module: ChatchatTcp.Handler,
         handler_options: Application.fetch_env!(:chatchat_tcp, :handler),
         supervisor_options: [name: ChatchatTcp.Server]
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ChatchatTcp.Supervisor)
  end
end
