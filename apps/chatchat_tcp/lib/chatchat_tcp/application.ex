defmodule ChatchatTcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    tcp_options = Application.fetch_env!(:chatchat_tcp, :server)

    children =
      [
        {Registry, keys: :duplicate, name: ChatchatTcp.Presence.Registry},
        {Redix, redis_options()},
        ChatchatTcp.MessageAdmission,
        {Task.Supervisor, name: ChatchatTcp.Delivery.TaskSupervisor},
        ChatchatTcp.Delivery,
        ChatchatTcp.Persistence,
        {ThousandIsland,
         Keyword.merge(tcp_options,
           handler_module: ChatchatTcp.Handler,
           handler_options: Application.fetch_env!(:chatchat_tcp, :handler),
           supervisor_options: [name: ChatchatTcp.Server]
         )}
      ] ++ metrics_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: ChatchatTcp.Supervisor)
  end

  defp metrics_children do
    if Application.get_env(:chatchat_tcp, ChatchatTcp.PromEx, [])[:disabled] do
      []
    else
      metrics_server = Application.fetch_env!(:chatchat_tcp, :metrics_server)

      [
        ChatchatTcp.PromEx,
        {Bandit,
         plug: {PromEx.Plug, prom_ex_module: ChatchatTcp.PromEx},
         ip: Keyword.fetch!(metrics_server, :ip),
         port: Keyword.fetch!(metrics_server, :port),
         startup_log: false}
      ]
    end
  end

  defp redis_options do
    {
      Application.fetch_env!(:chatchat_tcp, :redis_url),
      name: ChatchatTcp.Redis
    }
  end
end
