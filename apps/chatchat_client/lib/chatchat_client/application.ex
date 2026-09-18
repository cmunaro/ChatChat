defmodule ChatchatClient.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: ChatchatClient.SimulationSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
