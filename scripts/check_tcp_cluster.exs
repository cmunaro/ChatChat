# Small, isolated discovery/BEAM-message check; starts no ChatChat applications.
# Run: MIX_ENV=test elixir --name chatchat_check@127.0.0.1 -S mix run --no-start scripts/check_tcp_cluster.exs
{:ok, _} = Application.ensure_all_started(:libcluster)

{:ok, peer, remote} =
  :peer.start_link(%{
    name: :chatchat_tcp,
    host: ~c"127.0.0.1",
    longnames: true,
    connection: :standard_io,
    args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
  })

try do
  {:ok, supervisor} =
    Cluster.Supervisor.start_link([
      [
        check: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            query: "localhost",
            node_basename: "chatchat_tcp",
            polling_interval: 100,
            resolver: fn "localhost" -> [{127, 0, 0, 1}] end
          ]
        ]
      ],
      []
    ])

  try do
    deadline = System.monotonic_time(:millisecond) + 5_000

    wait = fn wait ->
      cond do
        remote in Node.list() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          raise "cluster discovery timed out"

        true ->
          Process.sleep(50)
          wait.(wait)
      end
    end

    :ok = wait.(wait)
    parent = self()
    reference = make_ref()

    remote_pid =
      Node.spawn(remote, :erlang, :send, [parent, {:cluster_receipt, reference, remote}])

    true = node(remote_pid) == remote

    receive do
      {:cluster_receipt, ^reference, ^remote} ->
        IO.puts("DNS discovery and direct two-node messaging passed")
    after
      2_000 -> raise "direct BEAM message timed out"
    end
  after
    Supervisor.stop(supervisor)
  end
after
  :peer.stop(peer)
end
