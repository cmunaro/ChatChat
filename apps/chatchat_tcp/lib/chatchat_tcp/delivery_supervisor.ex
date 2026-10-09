defmodule ChatchatTcp.DeliverySupervisor do
  @moduledoc "Restart delivery budgets, their workers, and socket producers as one unit."
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(tcp_options) do
    children = [
      ChatchatTcp.MessageDelivery,
      {Task.Supervisor, name: ChatchatTcp.Delivery.TaskSupervisor},
      ChatchatTcp.Delivery,
      {ThousandIsland,
       Keyword.merge(tcp_options,
         handler_module: ChatchatTcp.Handler,
         handler_options: Application.fetch_env!(:chatchat_tcp, :handler),
         supervisor_options: [name: ChatchatTcp.Server]
       )}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
