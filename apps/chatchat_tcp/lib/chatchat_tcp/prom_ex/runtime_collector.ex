defmodule ChatchatTcp.PromEx.RuntimeCollector do
  @moduledoc false
  use GenServer

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Delivery, MessageDelivery}

  @timeout 2_000
  @task_supervisor ChatchatTcp.PromEx.TaskSupervisor

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  def poll(server \\ __MODULE__), do: GenServer.cast(server, :poll)

  def emit_health(source, success, last_success) do
    :telemetry.execute(
      [:chatchat, :runtime, :collection],
      %{success: success, last_success: last_success},
      %{source: source}
    )
  end

  @impl true
  def init(options) do
    sources =
      Keyword.get(options, :sources, %{
        inbox: &Delivery.metric_snapshot/0,
        sender: &MessageDelivery.metric_snapshot/0,
        postgres: fn ->
          %{postgres_undelivered_messages: MessagesStore.count_undelivered(@timeout)}
        end
      })

    health = Map.new(sources, fn {source, _} -> {source, %{success: 0, last_success: 0}} end)

    {:ok,
     %{
       sources: sources,
       health: health,
       jobs: %{},
       timeout: Keyword.get(options, :timeout, @timeout),
       supervisor: Keyword.get(options, :task_supervisor, @task_supervisor)
     }}
  end

  @impl true
  def handle_cast(:poll, state) do
    Enum.each(state.health, fn {source, health} ->
      emit_health(source, health.success, health.last_success)
    end)

    jobs =
      Enum.reduce(state.sources, state.jobs, fn {source, collect}, jobs ->
        if Enum.any?(jobs, fn {_, job} -> job.source == source end) do
          jobs
        else
          task = Task.Supervisor.async_nolink(state.supervisor, collect)
          timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)

          Map.put(jobs, task.ref, %{
            source: source,
            task: task,
            timer: timer,
            deadline: System.monotonic_time(:millisecond) + state.timeout
          })
        end
      end)

    {:noreply, %{state | jobs: jobs}}
  end

  @impl true
  def handle_info({reference, snapshot}, state) when is_reference(reference) do
    now = System.monotonic_time(:millisecond)

    case Map.pop(state.jobs, reference) do
      {nil, _} ->
        {:noreply, state}

      {job, _jobs} when job.deadline <= now ->
        Task.shutdown(job.task, :brutal_kill)
        {:noreply, fail(state, reference)}

      {job, jobs} ->
        Process.cancel_timer(job.timer)
        Process.demonitor(reference, [:flush])
        :telemetry.execute([:chatchat, :runtime, :snapshot], snapshot, %{})
        health = %{success: 1, last_success: System.system_time(:second)}
        emit_health(job.source, health.success, health.last_success)
        {:noreply, %{state | jobs: jobs, health: Map.put(state.health, job.source, health)}}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    {:noreply, fail(state, reference)}
  end

  def handle_info({:timeout, reference}, state) do
    case state.jobs[reference] do
      nil -> :ok
      job -> Task.shutdown(job.task, :brutal_kill)
    end

    {:noreply, fail(state, reference)}
  end

  defp fail(state, reference) do
    case Map.pop(state.jobs, reference) do
      {nil, _} ->
        state

      {job, jobs} ->
        Process.cancel_timer(job.timer)
        health = %{state.health[job.source] | success: 0}
        emit_health(job.source, health.success, health.last_success)

        :telemetry.execute([:chatchat, :runtime, :collection, :failed], %{count: 1}, %{
          source: job.source
        })

        %{state | jobs: jobs, health: Map.put(state.health, job.source, health)}
    end
  end
end
