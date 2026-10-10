"""Authorized isolated load run; fixed CPU sets require a dedicated 12-CPU Docker host."""
import argparse
from datetime import datetime, timezone
import json
import hashlib
import os
from pathlib import Path
import secrets
import subprocess
import time
from types import SimpleNamespace

import capture_diagnostics as capture

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "chatchat-task3"
COMPOSE = ["docker", "compose", "-p", PROJECT, "--profile", "loadtest", "-f", str(ROOT / "docker-compose.yml"),
           "-f", str(ROOT / "docker-compose.baseline.yml")]
RPC_PREFIX = "s = :sys.get_state(ChatchatClient.LoadGenerator); "


def command(argv, timeout=120, env=None):
    result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {argv[:3]}: {result.stderr[-2000:]}")
    return result.stdout.strip()


def rpc(container, code, release="chatchat_client", timeout=60):
    return command(["docker", "exec", container, f"/app/bin/{release}", "rpc", code], timeout)


def containers(env, service):
    ids = command(COMPOSE + ["ps", "-q", service], env=env).splitlines()
    return [command(["docker", "inspect", "--format", "{{.Name}}", item]).lstrip("/") for item in ids]


def snapshot_metadata(env, args, output):
    targets = args.tcp_container + args.loadgen_container + args.haproxy_container + args.resource_container + args.redis_container + args.postgres_container
    rows = json.loads(command(["docker", "inspect", *targets]))
    # Never save container environments or cluster cookies.
    fields = ["NanoCpus", "CpuQuota", "CpuPeriod", "CpusetCpus", "Memory", "Ulimits"]
    metadata = [{"name": row["Name"], "image_id": row["Image"], "image_tag": row["Config"]["Image"],
                 "resources": {key: row["HostConfig"][key] for key in fields}} for row in rows]
    beams = {}
    code = 'IO.puts(Jason.encode!(%{schedulers: :erlang.system_info(:schedulers_online), peer_count: length(Node.list()), dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers_online), dirty_io: :erlang.system_info(:dirty_io_schedulers), run_queues: :erlang.statistics(:run_queue_lengths), otp: List.to_string(:erlang.system_info(:otp_release)), elixir: System.version()}))'
    for service, release in [("tcp", "chatchat_tcp"), ("web", "chatchat_web"), ("loadgen", "chatchat_client")]:
        for container in containers(env, service):
            beams[container] = json.loads(rpc(container, code, release))
    (output / "metadata.json").write_text(json.dumps({"containers": metadata, "beams": beams,
        "haproxy_version": command(["docker", "exec", args.haproxy_container[0], "haproxy", "-vv"]),
        "host": command(["docker", "info", "--format", "{{.NCPU}} {{.MemTotal}} {{.ServerVersion}}"]),
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [ROOT / "docker-compose.baseline.yml", ROOT / "observability/run_baseline.py", ROOT / "observability/capture_diagnostics.py", ROOT / "mise.toml", ROOT / "mix.lock"]},
        "commit": command(["git", "rev-parse", "HEAD"]),
        "diff": command(["git", "diff", "--stat"]),
        "bounds": {"setup_seconds": 240, "shards": 2, "capture_interval_seconds": 10}}, indent=2) + "\n")


def clients(sample):
    probes = sample["probes"]
    return [value["data"] for key, value in probes.items()
            if key.startswith("client:") and value["status"] == "ok" and "phase" in value["data"]]


def authenticated(sample):
    probes = sample["probes"]
    connections = probes.get("prometheus:connections", {})
    health = probes.get("prometheus:collection_health", {})
    freshness = probes.get("prometheus:collection_last_success", {})
    now = datetime.fromisoformat(sample["timestamp"]).timestamp()
    if any(probe.get("status") != "ok" for probe in (connections, health, freshness)):
        return None
    good = {row["metric"]["instance"] for row in health["data"]
            if row["metric"].get("source") == "connections" and float(row["value"][1]) == 1}
    fresh = {row["metric"]["instance"] for row in freshness["data"]
             if row["metric"].get("source") == "connections" and 0 <= now - float(row["value"][1]) <= 15}
    values = connections["data"]
    if len(values) != 2 or any(row["metric"]["instance"] not in good & fresh for row in values):
        return None
    return sum(float(row["value"][1]) for row in values)


def outbox_snapshot(args):
    code = RPC_PREFIX + r'''deadline = System.monotonic_time(:millisecond) + 5000; sim = :sys.get_state(s.simulation);
      stream = Stream.resource(fn -> :ets.select(sim.clients, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}], 256) end,
        fn
          :"$end_of_table" -> {:halt, nil}
          {pids, next} -> {pids, if(next == :"$end_of_table", do: next, else: :ets.select(next))}
        end, fn _ -> :ok end);
      totals = stream |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end) |> Task.async_stream(fn pid ->
        try do
          state = :sys.get_state(pid, 25);
          %{observed: 1, unavailable: 0, connected: if(state.socket, do: 1, else: 0),
            outbox: :gb_trees.size(state.store.outbox), inbox: :gb_trees.size(state.store.inbox),
            inflight: map_size(state.inflight)}
        catch _, _ -> %{observed: 0, unavailable: 1, connected: 0, outbox: 0, inbox: 0, inflight: 0} end
      end, max_concurrency: 8, ordered: false, timeout: 1000, on_timeout: :kill_task)
      |> Enum.reduce(%{observed: 0, unavailable: 0, connected: 0, outbox: 0, inbox: 0, inflight: 0}, fn
        {:ok, values}, total -> Map.merge(total, values, fn _, a, b -> a+b end)
        _, total -> Map.update!(total, :unavailable, &(&1+1))
      end);
      totals = Map.put(totals, :unscanned, max(:ets.info(sim.clients, :size) - totals.observed - totals.unavailable, 0));
      IO.puts(Jason.encode!(totals))'''
    results = {}
    for container in args.loadgen_container:
        try:
            results[container] = json.loads(rpc(container, code, timeout=12))
        except (RuntimeError, subprocess.TimeoutExpired, ValueError):
            results[container] = {"available": False}
    return results


def traffic_stop(sample, requested):
    states = clients(sample)
    sockets = authenticated(sample)
    if len(states) != 2 or sockets is None or sockets < requested * .999:
        return True
    outstanding = sum(s["queued_messages"] - s["unique_confirmed_messages"] for s in states)
    return outstanding > max(100, requested * .01)


def phase(args, output, label, duration, requested, setup=False, traffic=False, population=True):
    directory = output / label
    directory.mkdir()
    (directory / "capture.json").write_text(json.dumps({"duration_seconds": duration,
        "requested_sockets": requested, "interval_seconds": 10,
        "socket_probe_image": args.socket_probe_image, "queries": capture.QUERIES,
        "targets": vars(args)}, indent=2) + "\n")
    samples = []
    start = time.time()
    last_resources = -30
    ready = False
    with (directory / "samples.jsonl").open("w") as stream:
        while time.time() - start < duration:
            tick = time.monotonic()
            resources = tick - last_resources >= 30
            sample = capture.capture_sample(args, resources)
            if resources:
                last_resources = tick
            stream.write(json.dumps(sample) + "\n")
            stream.flush()
            samples.append(sample)
            states = clients(sample)
            sockets = authenticated(sample)
            if len(samples) % 3 == 1:
                print(f"{label}: {int(time.time()-start)}s authenticated={sockets} wrappers={sum(s['ready_clients'] for s in states)} queued={sum(s['queued_messages'] for s in states)} confirmed={sum(s['unique_confirmed_messages'] for s in states)}", flush=True)
            if setup and time.time() - start <= duration and len(states) == 2 and all(s["phase"] == "ready" for s in states) and sockets == requested:
                ready = True
                break
            if traffic and time.time() - start >= 30:
                if traffic_stop(sample, requested):
                    print(f"{label}: safety stop", flush=True)
                    break
            time.sleep(max(0, 10 - (time.monotonic() - tick)))
    (directory / "summary.md").write_text(capture.summary(samples))
    if not setup and population:
        started = datetime.now(timezone.utc).isoformat()
        observed = outbox_snapshot(args)
        try:
            rows = int(command(["docker", "exec", args.postgres_container[0], "psql", "-U", "chatchat",
                "-d", "chatchat_baseline", "-Atc", "SELECT count(*) FROM messages;"], timeout=5))
            (directory / "postgres-pending.json").write_text(json.dumps({"rows": rows,
                "timestamp": datetime.now(timezone.utc).isoformat()}) + "\n")
        except (RuntimeError, subprocess.TimeoutExpired, ValueError):
            (directory / "postgres-pending.json").write_text('{"available": false}\n')
        (directory / "outboxes.json").write_text(json.dumps({"started_at": started,
            "finished_at": datetime.now(timezone.utc).isoformat(), "shards": observed}, indent=2) + "\n")
    return samples, ready


def stable(samples, requested):
    if len(samples) < 6:
        return False
    timestamps = [datetime.fromisoformat(s["timestamp"]).timestamp() for s in samples]
    if any(b - a > 30 for a, b in zip(timestamps, timestamps[1:])):
        return False
    values = [authenticated(s) for s in samples]
    states = clients(samples[-1])
    # Require observed fresh sockets through repeated 30s leases; no failed client reconnects.
    return all(v is not None and v >= requested * .999 for v in values) and len(states) == 2 and all(
        s["connection_diagnostics"]["reconnects"]["failed"] == 0 for s in states)


def set_traffic(args, probability, start=False):
    for container in args.loadgen_container:
        rpc(container, RPC_PREFIX + f''' :ok = ChatchatClient.set_simulation_send_probability(s.simulation, {probability});
          ''' + ('IO.inspect(ChatchatClient.start_simulation_activity(s.simulation))' if start else 'IO.puts("updated")'), timeout=12)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--steps", type=int, nargs="+", default=[10000, 20000, 40000, 80000])
    parser.add_argument("--hold", type=int, default=120)
    parser.add_argument("--traffic", type=float, nargs="+", default=[.01, .05, .10, .20])
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--socket-probe-image", default="chatchat-socket-probe")
    opts = parser.parse_args()
    if opts.hold < 90 or any(n <= 0 or n > 80000 or n % 2 for n in opts.steps) or opts.steps != sorted(set(opts.steps)) or any(p <= 0 or p > 1 for p in opts.traffic) or opts.traffic != sorted(set(opts.traffic)):
        parser.error("hold >=90s; ascending even steps <=80000; traffic probabilities (0,1]")
    # Refuse overlapping workloads, including other Compose projects.
    if command(["docker", "ps", "-q"]):
        raise RuntimeError("baseline requires no running containers; stop unrelated workloads explicitly")
    if int(command(["docker", "info", "--format", "{{.NCPU}} "])) < 12:
        raise RuntimeError("baseline CPU sets require at least 12 Docker CPUs")
    if command(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={PROJECT}"]):
        raise RuntimeError("existing baseline containers; use a fresh deployment")
    if command(["docker", "volume", "ls", "-q", "--filter", f"label=com.docker.compose.project={PROJECT}"]):
        raise RuntimeError("existing baseline volumes; do not reuse data")
    opts.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TCP_CLUSTER_COOKIE=secrets.token_hex(32))
    results = []
    try:
        if opts.build:
            command(COMPOSE + ["build", "tcp", "web", "loadgen"], timeout=600, env=env)
            command(["docker", "build", "-t", opts.socket_probe_image, "-f", "observability/socket-probe.Dockerfile", "."], timeout=120)
        command(COMPOSE + ["up", "-d", "--scale", "tcp=2", "postgres", "redis", "tcp", "haproxy", "prometheus", "web"], env=env)
        (opts.output / "provision.txt").write_text(command(COMPOSE + ["run", "--rm", "--no-deps", "provision"], env=env) + "\n")
        args = SimpleNamespace(prometheus="http://localhost:29090", socket_probe_image=opts.socket_probe_image,
            tcp_container=containers(env, "tcp"), haproxy_container=containers(env, "haproxy"),
            loadgen_container=[], resource_container=containers(env, "web") + containers(env, "prometheus"),
            redis_container=containers(env, "redis"), postgres_container=containers(env, "postgres"))
        largest = None
        for count in opts.steps:
            if largest is not None:
                command(COMPOSE + ["stop", "loadgen"], env=env)
                args.loadgen_container = []
                phase(args, opts.output, f"cooldown-{count}", 90, 0, population=False)
            env.update(BASELINE_CLIENTS_PER_SHARD=str(count // 2), BASELINE_RUN_ID=f"task3-{count}")
            command(COMPOSE + ["up", "-d", "--no-deps", "--force-recreate", "--scale", "loadgen=2", "loadgen"], env=env)
            args.loadgen_container = containers(env, "loadgen")
            directory = opts.output / str(count)
            directory.mkdir()
            snapshot_metadata(env, args, directory)
            setup_samples, ready = phase(args, directory, "setup", 240, count, setup=True)
            held, _ = phase(args, directory, "connections", opts.hold, count) if ready else ([], False)
            accepted = ready and stable(held, count)
            results.append({"requested": count, "ready": ready, "stable": accepted})
            print(f"connection step {count}: stable={accepted}", flush=True)
            if not accepted:
                break
            largest = count
        if largest is not None:
            if results[-1]["requested"] != largest:
                command(COMPOSE + ["stop", "loadgen"], env=env)
                args.loadgen_container = []
                phase(args, opts.output, "cooldown-traffic", 90, 0, population=False)
                env.update(BASELINE_CLIENTS_PER_SHARD=str(largest // 2), BASELINE_RUN_ID=f"task3-traffic-{largest}")
                command(COMPOSE + ["up", "-d", "--no-deps", "--force-recreate", "--scale", "loadgen=2", "loadgen"], env=env)
                args.loadgen_container = containers(env, "loadgen")
                retry, ready = phase(args, opts.output, "traffic-setup", 240, largest, setup=True)
                held, _ = phase(args, opts.output, "traffic-connections", opts.hold, largest) if ready else ([], False)
                if not ready or not stable(held, largest):
                    raise RuntimeError("largest stable connection step could not be reproduced")
            for index, probability in enumerate(opts.traffic):
                set_traffic(args, probability, start=index == 0)
                samples, _ = phase(args, opts.output, f"traffic-{probability}", opts.hold, largest, traffic=True, population=False)
                states = clients(samples[-1])
                outstanding = sum(s["queued_messages"] - s["unique_confirmed_messages"] for s in states) if len(states) == 2 else None
                results.append({"probability": probability, "outstanding": outstanding, "fresh_sockets": authenticated(samples[-1])})
                if traffic_stop(samples[-1], largest):
                    break
            set_traffic(args, 0.0)
            phase(args, opts.output, "drain", 120, largest)
    finally:
        (opts.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        # Save counters above before writers stop. Only this fresh project's volumes are removed.
        command(COMPOSE + ["stop", "loadgen", "tcp", "web"], env=env)
        pg = containers(env, "postgres")
        if pg:
            counts = command(["docker", "exec", pg[0], "psql", "-U", "chatchat", "-d", "chatchat_baseline", "-Atc",
                "TRUNCATE messages, users, admin_users RESTART IDENTITY; SELECT (SELECT count(*) FROM messages), (SELECT count(*) FROM users), (SELECT count(*) FROM admin_users);"])
            (opts.output / "cleanup.txt").write_text(counts + "\n")
        command(COMPOSE + ["down", "-v", "--remove-orphans"], env=env)


if __name__ == "__main__":
    main()
