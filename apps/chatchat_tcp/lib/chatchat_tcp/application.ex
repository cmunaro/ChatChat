defmodule ChatchatTcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    tcp_options = Application.fetch_env!(:chatchat_tcp, :server)

    children = [
      {Registry, keys: :duplicate, name: ChatchatTcp.Presence.Registry},
      {Redix, redis_options()},
      ChatchatTcp.MessageAdmission,
      {Task.Supervisor, name: ChatchatTcp.Delivery.TaskSupervisor},
      ChatchatTcp.Delivery,
      {ThousandIsland,
       Keyword.merge(tcp_options,
         handler_module: ChatchatTcp.Handler,
         handler_options: Application.fetch_env!(:chatchat_tcp, :handler),
         supervisor_options: [name: ChatchatTcp.Server]
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ChatchatTcp.Supervisor)
  end

  defp redis_options do
    {
      Application.fetch_env!(:chatchat_tcp, :redis_url),
      name: ChatchatTcp.Redis
    }
  end
end
