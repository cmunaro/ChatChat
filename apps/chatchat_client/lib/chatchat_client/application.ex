defmodule ChatchatClient.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {DynamicSupervisor, strategy: :one_for_one, name: ChatchatClient.SimulationSupervisor}
      ] ++ load_generator_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp load_generator_children do
    case Application.get_env(:chatchat_client, :load_generator) do
      nil -> []
      options -> [{ChatchatClient.LoadGenerator, options}]
    end
  end
end
