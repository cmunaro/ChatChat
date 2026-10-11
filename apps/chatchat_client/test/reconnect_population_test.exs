defmodule ChatchatClient.ReconnectPopulationTest do
  use ExUnit.Case, async: false

  @population 200
  @tag timeout: 60_000
  test "an entire bounded population spreads outage retries and retains every pending identity" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        backlog: 256,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    previous = Application.get_env(:chatchat_client, :tcp_port)
    Application.put_env(:chatchat_client, :tcp_port, port)
    table = :ets.new(:outage_backend, [:set, :public])
    :ets.insert(table, {:available, true})
    supervisor = start_supervised!({Task.Supervisor, max_children: @population + 1})

    {:ok, _} =
      Task.Supervisor.start_child(supervisor, fn -> accept(listener, supervisor, table) end)

    owner = self()
    telemetry = make_ref()

    :telemetry.attach(
      telemetry,
      [:chatchat, :client, :retry_interval],
      &__MODULE__.interval/4,
      owner
    )

    on_exit(fn ->
      :telemetry.detach(telemetry)
      :gen_tcp.close(listener)

      if previous,
        do: Application.put_env(:chatchat_client, :tcp_port, previous),
        else: Application.delete_env(:chatchat_client, :tcp_port)
    end)

    clients =
      for user <- 1..@population do
        pid = ChatchatClient.run_preprovisioned("outage_#{user}", user, result_observer: self())
        # Also clean up a partially constructed population if startup fails.
        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        {user, pid}
      end

    try do
      :ets.insert(table, {:available, false})
      for {{:socket, _pid}, socket} <- :ets.tab2list(table), do: :gen_tcp.close(socket)
      wait_for(fn -> Enum.all?(clients, fn {_, pid} -> :sys.get_state(pid).socket == nil end) end)

      pending =
        for {user, pid} <- clients do
          {:ok, id} = ChatchatClient.send_message(pid, 999, "retained")
          {user, pid, id}
        end

      Process.sleep(5_000)
      failed = Enum.filter(:ets.tab2list(table), &match?({{:attempt, _, _}, _}, &1))
      assert length(failed) >= @population
      assert length(failed) <= @population * 3

      for {_, pid, id} <- pending do
        state = :sys.get_state(pid)
        assert state.socket == nil
        assert is_reference(state.reconnect_timer)
        assert [[^id, 999, "retained", nil]] = ChatchatClient.outbox(pid)
      end

      intervals = collect_intervals(%{})
      assert map_size(intervals) == @population
      assert Enum.all?(intervals, fn {_pid, values} -> Enum.all?(values, &(&1 >= 1_590)) end)
      timestamps = Enum.map(failed, &elem(&1, 1))
      assert Enum.max(timestamps) - Enum.min(timestamps) >= 1_500

      :ets.insert(table, {:available, true})

      wait_for(
        fn ->
          Enum.all?(pending, fn {_, pid, _} ->
            state = :sys.get_state(pid)

            state.socket != nil and state.reconnect_failures == 0 and
              ChatchatClient.outbox(pid) == []
          end)
        end,
        200
      )

      for {user, _, id} <- pending, do: assert(:ets.member(table, {:received, user, id}))
    after
      for {_, pid} <- clients, Process.alive?(pid), do: GenServer.stop(pid)
      :gen_tcp.close(listener)
      wait_for(fn -> Task.Supervisor.children(supervisor) == [] end, 50)
    end
  end

  def interval(_event, %{interval: interval}, %{role: :reconnect}, owner),
    do: send(owner, {:population_interval, self(), interval})

  def interval(_, _, _, _), do: :ok

  defp collect_intervals(values) do
    receive do
      {:population_interval, pid, interval} ->
        collect_intervals(Map.update(values, pid, [interval], &[interval | &1]))
    after
      0 -> values
    end
  end

  defp accept(listener, supervisor, table) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case Task.Supervisor.start_child(supervisor, fn ->
               receive do
                 {:socket, socket} -> serve(socket, table)
               end
             end) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(socket, pid)
            send(pid, {:socket, socket})

          {:error, _} ->
            :gen_tcp.close(socket)
        end

        accept(listener, supervisor, table)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, table) do
    try do
      with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
           %{"type" => "authenticate", "token" => token} <- Jason.decode!(line),
           {:ok, user} <- ChatchatAuth.verify(token) do
        if :ets.lookup_element(table, :available, 2) do
          :ets.insert(table, {{:socket, self()}, socket})
          json(socket, %{type: "authenticated", user_id: user})
          messages(socket, user, table)
        else
          :ets.insert(table, {{:attempt, user, make_ref()}, System.monotonic_time(:millisecond)})
          json(socket, %{type: "error", error: "unauthorized"})
        end
      end
    after
      :ets.delete(table, {:socket, self()})
      :gen_tcp.close(socket)
    end
  end

  defp messages(socket, user, table) do
    case :gen_tcp.recv(socket, 0, 20_000) do
      {:ok, line} ->
        case Jason.decode!(line) do
          %{"type" => "ping"} ->
            json(socket, %{type: "pong"})

          %{"type" => "send_message", "message_id" => id, "request_id" => request} ->
            :ets.insert(table, {{:received, user, id}, true})

            json(socket, %{
              type: "message_result",
              message_id: id,
              request_id: request,
              status: "ok"
            })
        end

        messages(socket, user, table)

      {:error, _} ->
        :ok
    end
  end

  defp json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")
  defp wait_for(predicate, attempts \\ 100)

  defp wait_for(predicate, attempts) when attempts > 0 do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(100)
          wait_for(predicate, attempts - 1)
        )
  end

  defp wait_for(_, 0), do: flunk("population did not recover before the bounded deadline")
end
