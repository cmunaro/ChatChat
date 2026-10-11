"""Authorized isolated load run; fixed CPU sets require a dedicated 12-CPU Docker host."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import hashlib
import os
import re
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
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [ROOT / "docker-compose.baseline.yml", ROOT / "observability/run_baseline.py", ROOT / "observability/capture_diagnostics.py", ROOT / "mise.toml", ROOT / "mix.lock", ROOT / "apps/chatchat_tcp/lib/chatchat_tcp/presence.ex", ROOT / "apps/chatchat_tcp/lib/chatchat_tcp/presence_routing.ex", ROOT / "apps/chatchat_tcp/lib/chatchat_tcp/handler.ex", ROOT / "apps/chatchat_tcp/lib/chatchat_tcp/presence_redis.ex", ROOT / "apps/chatchat_client/lib/chatchat_client.ex", ROOT / "apps/chatchat_client/lib/chatchat_client/simulated_client.ex", ROOT / "apps/chatchat_client/lib/chatchat_client/reconnect_backoff.ex"]},
        "commit": command(["git", "rev-parse", "HEAD"]),
        "diff": command(["git", "diff", "--stat"]),
        "bounds": {"setup_seconds": 240, "shards": 2, "capture_interval_seconds": 10}}, indent=2) + "\n")


def proxy_config(threads):
    source = (ROOT / "observability/haproxy.cfg").read_text()
    configured, count = re.subn(r"^  nbthread \d+$", f"  nbthread {threads}", source, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError("baseline requires one explicit HAProxy nbthread setting")
    return configured


def failure_snapshot(args, directory):
    """Save bounded process-failure headers, never request contents or environments."""
    rows = {}
    for container in args.tcp_container + args.loadgen_container:
        state = json.loads(command(["docker", "inspect", "--format",
            '{{json .State}}', container]))
        logs = subprocess.run(["docker", "logs", "--tail", "1000", container],
            capture_output=True, text=True, timeout=5)
        headers = re.findall(r"GenServer (Elixir\.[\w.]+|Chatchat[\w.]+|#PID<[^>]+>) terminating", logs.stdout + logs.stderr)
        rows[container] = {"oom_killed": state["OOMKilled"],
            "running": state["Running"], "failure_headers": headers[-32:]}
    (directory / "failure-events.json").write_text(json.dumps(rows, indent=2) + "\n")


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
          state = try do :sys.get_state(pid, 25) catch :exit, _ -> :sys.get_state(pid, 25) end;
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


def traffic_stop(sample, requested, allow_unavailable=False):
    states = clients(sample)
    sockets = authenticated(sample)
    if sample.get("generator_counter_reset"):
        return True
    if len(states) != 2 or (not allow_unavailable and (sockets is None or sockets < requested * .999)):
        return True
    stats = sample["probes"].get("docker_stats", {})
    if stats.get("status") == "ok":
        for line in stats["data"].splitlines():
            row = json.loads(line)
            if float(row.get("MemPerc", "0%").rstrip("%")) >= 90:
                return True
    if any(s["queued_messages"] < s["unique_confirmed_messages"] or s["unique_confirmed_messages"] < 0 for s in states):
        return True
    outstanding = sum(s["queued_messages"] - s["unique_confirmed_messages"] for s in states)
    return outstanding > max(100, requested * .01)


def phase(args, output, label, duration, requested, setup=False, traffic=False, population=True, allow_unavailable=False):
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
    previous_counts = {}
    with (directory / "samples.jsonl").open("w") as stream:
        while time.time() - start < duration:
            tick = time.monotonic()
            resources = tick - last_resources >= 30
            sample = capture.capture_sample(args, resources)
            if resources:
                last_resources = tick
            samples.append(sample)
            states = clients(sample)
            sockets = authenticated(sample)
            if len(samples) % 3 == 1:
                counts = {key: sum(state[key] for state in states) if len(states) == 2 else None
                          for key in ("ready_clients", "queued_messages", "unique_confirmed_messages")}
                print(f"{label}: {int(time.time()-start)}s authenticated={sockets} wrappers={counts['ready_clients']} queued={counts['queued_messages']} confirmed={counts['unique_confirmed_messages']}", flush=True)
            if setup and time.time() - start <= duration and len(states) == 2 and all(s["phase"] == "ready" for s in states) and sockets == requested:
                ready = True
                break
            counter_reset = False
            for key, probe in sample["probes"].items():
                if key.startswith("client:") and probe.get("status") == "ok" and "phase" in probe.get("data", {}):
                    counts = tuple(probe["data"][name] for name in ("queued_messages", "unique_confirmed_messages"))
                    counter_reset |= key in previous_counts and any(a < b for a, b in zip(counts, previous_counts[key]))
                    previous_counts[key] = counts
            if counter_reset:
                sample["generator_counter_reset"] = True
            stream.write(json.dumps(sample) + "\n")
            stream.flush()
            if traffic and (allow_unavailable or time.time() - start >= 30):
                if traffic_stop(sample, requested, allow_unavailable):
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


def traffic_result(samples, requested, duration):
    """Evaluate the post-warmup interval; cumulative earlier traffic is excluded."""
    times = [datetime.fromisoformat(s["timestamp"]).timestamp() for s in samples]
    window = [s for s, t in zip(samples, times) if t - times[0] >= 30] if times else []
    result = {"accepted": False}
    if len(window) < 6 or any(len(clients(s)) != 2 or any("confirmation_latency_ms" not in state for state in clients(s)) for s in window):
        return result
    first, last = clients(window[0]), clients(window[-1])
    elapsed = datetime.fromisoformat(window[-1]["timestamp"]).timestamp() - datetime.fromisoformat(window[0]["timestamp"]).timestamp()
    confirmed = sum(s["unique_confirmed_messages"] for s in last) - sum(s["unique_confirmed_messages"] for s in first)
    outstanding = [sum(s["queued_messages"] - s["unique_confirmed_messages"] for s in clients(row)) for row in window]
    buckets = {limit: sum(s["confirmation_latency_ms"]["buckets"][str(limit)] for s in last) -
               sum(s["confirmation_latency_ms"]["buckets"][str(limit)] for s in first)
               for limit in (10, 50, 100, 500, 1000, 10000)}
    p95 = next((limit for limit, count in buckets.items() if confirmed > 0 and count >= confirmed * .95), None)
    slope = (outstanding[-1] - outstanding[0]) / elapsed if elapsed > 0 else None
    complete = times[-1] - times[0] >= duration - 20
    fresh = all(authenticated(s) is not None and authenticated(s) >= requested * .999 for s in window)
    gaps = any(b - a > 30 for a, b in zip(times, times[1:]))
    result.update(confirmation_rate=confirmed / elapsed if elapsed > 0 else None,
                  p95_upper_ms=p95, backlog_slope_per_second=slope,
                  outstanding=outstanding[-1], peak_outstanding=max(outstanding),
                  full_duration=complete, fresh_sockets=fresh, observation_gap=gaps)
    result["accepted"] = (complete and fresh and not gaps and not any(traffic_stop(s, requested) for s in window)
                          and p95 is not None and p95 <= 100
                          and slope is not None and slope <= 1 and outstanding[-1] <= 100)
    return result


def reconciliation(directory, samples, requested):
    scans = json.loads((directory / "outboxes.json").read_text())["shards"]
    pending = json.loads((directory / "postgres-pending.json").read_text())
    states = clients(samples[-1]) if samples else []
    valid = len(states) == 2 and len(scans) == 2 and all(
        row.get("available", True) and row.get("unavailable") == 0 and row.get("unscanned") == 0
        and row.get("outbox") == 0 and row.get("inflight") == 0 for row in scans.values())
    valid = valid and sum(row.get("observed", 0) for row in scans.values()) == requested
    queued = sum(s["queued_messages"] for s in states)
    confirmed = sum(s["unique_confirmed_messages"] for s in states)
    inbox = sum(row.get("inbox", 0) for row in scans.values())
    return {"complete": valid and pending.get("rows") == 0 and queued == confirmed == inbox,
            "admitted": queued, "confirmed": confirmed, "inbox": inbox,
            "postgres_pending": pending, "scans": scans}


def set_traffic(args, probability, start=False):
    for container in args.loadgen_container:
        rpc(container, RPC_PREFIX + f''' :ok = ChatchatClient.set_simulation_send_probability(s.simulation, {probability});
          ''' + ('IO.inspect(ChatchatClient.start_simulation_activity(s.simulation))' if start else 'IO.puts("updated")'), timeout=12)


def recovery_stable(samples, requested):
    if not samples:
        return False
    times = [datetime.fromisoformat(s["timestamp"]).timestamp() for s in samples]
    window = [s for s, t in zip(samples, times) if t >= times[-1] - 90]
    return (times[-1] - times[0] >= 160 and len(window) >= 10
            and datetime.fromisoformat(window[-1]["timestamp"]).timestamp()
            - datetime.fromisoformat(window[0]["timestamp"]).timestamp() >= 90
            and not any(b - a > 30 for a, b in zip(times, times[1:]))
            and all(authenticated(s) is not None and authenticated(s) >= requested * .999
                    and not traffic_stop(s, requested, True) for s in window))


def failure_targets(args, scenario):
    targets = getattr(args, {"redis": "redis_container", "postgres": "postgres_container",
                            "tcp-all": "tcp_container"}[scenario])
    if len(targets) != (2 if scenario == "tcp-all" else 1):
        raise RuntimeError("failure scenario requires the complete dedicated target set")
    return targets


def run_failure(args, output, scenario, requested, probability, result):
    targets = failure_targets(args, scenario)
    action = "kill" if scenario == "tcp-all" else "pause"
    restore = "start" if scenario == "tcp-all" else "unpause"
    result.update(scenario=scenario, targets=targets, accepted=False, actions=[],
                  expected_unavailable_probes=targets, outage_seconds=30,
                  recovery_seconds=180, drain_seconds=120, stability_seconds=90)
    path = output / "failure-scenario.json"

    def save():
        path.write_text(json.dumps(result, indent=2) + "\n")

    def act(verb, target):
        record = {"action": verb, "container": target,
                  "started_at": datetime.now(timezone.utc).isoformat()}
        result["actions"].append(record)
        save()
        try:
            command(["docker", verb, target], timeout=30)
            record["ok"] = True
        except Exception as error:
            record.update(ok=False, error=str(error))
            raise
        finally:
            record["finished_at"] = datetime.now(timezone.utc).isoformat()
            save()

    planned = datetime.now(timezone.utc)
    result.update(planned_at=planned.isoformat(),
                  outage_deadline=(planned + timedelta(seconds=30)).isoformat(),
                  recovery_deadline=(planned + timedelta(seconds=210)).isoformat(),
                  drain_deadline=(planned + timedelta(seconds=330)).isoformat(),
                  expected_unavailable_probes={
                      "redis": ["Redis presence acquisition/renewal", "authenticated sockets"],
                      "postgres": ["PostgreSQL pending rows", "fallback persistence"],
                      "tcp-all": ["TCP RPC/metrics", "authenticated sockets"]}[scenario])
    save()
    try:
        set_traffic(args, probability)
        try:
            # Kill every TCP node before starting any; dependencies and generators stay alive.
            for target in targets:
                act(action, target)
            outage, _ = phase(args, output, "failure-outage", 30, requested,
                              traffic=True, population=False, allow_unavailable=True)
            result["safety_stop"] = any(traffic_stop(s, requested, True) for s in outage)
        finally:
            try:
                if result.get("safety_stop"):
                    set_traffic(args, 0.0)
            finally:
                errors = []
                for target in targets:
                    try:
                        act(restore, target)
                    except Exception as error:
                        errors.append(str(error))
                result["restoration_errors"] = errors
                save()
        if not result["restoration_errors"]:
            recovery, _ = phase(args, output, "failure-recovery", 180, requested,
                                traffic=True, population=False, allow_unavailable=True)
            result["recovery_stable"] = recovery_stable(recovery, requested)
            times = [datetime.fromisoformat(s["timestamp"]).timestamp() for s in outage + recovery]
            result["observation_gap"] = any(b - a > 30 for a, b in zip(times, times[1:]))
            result["safety_stop"] = result.get("safety_stop", False) or any(
                traffic_stop(s, requested, True) for s in recovery)
            # Histograms here include outage latency; no healthy p95 gate applies.
            result["outage_latency_counters"] = [s.get("confirmation_latency_ms") for s in clients(recovery[-1])] if recovery else []
    except Exception as error:
        result["error"] = str(error)
    finally:
        try:
            set_traffic(args, 0.0)
            drained, _ = phase(args, output, "failure-drain", 120, requested)
            result["reconciliation"] = reconciliation(output / "failure-drain", drained, requested)
            result["accepted"] = (result.get("recovery_stable", False)
                                  and not result.get("safety_stop", False)
                                  and not result.get("observation_gap", True)
                                  and not result.get("error") and not result.get("restoration_errors")
                                  and result["reconciliation"]["complete"])
        finally:
            save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--steps", type=int, nargs="+", default=[10000, 20000, 40000, 80000])
    parser.add_argument("--hold", type=int, default=120)
    parser.add_argument("--traffic", type=float, nargs="+", default=[.01, .05, .10, .20])
    parser.add_argument("--traffic-hold", type=int, default=None, help="traffic-step duration; defaults to --hold")
    parser.add_argument("--soak", type=int, default=0, help="soak highest accepted rate after ramp (seconds)")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--proxy-threads", type=int, choices=[1, 2], default=2)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--failure-scenario", choices=["redis", "postgres", "tcp-all"])
    group.add_argument("--backend-outage", action="store_true",
                        help="interrupt one dedicated TCP node for 30s, then observe 180s recovery at .01 traffic")
    parser.add_argument("--outage-mode", choices=["stop", "pause"], default="stop",
                        help="pause keeps DNS intact to exercise health timeout and lease expiry")
    parser.add_argument("--socket-probe-image", default="chatchat-socket-probe")
    opts = parser.parse_args()
    if opts.hold < 90 or any(n <= 0 or n > 80000 or n % 2 for n in opts.steps) or opts.steps != sorted(set(opts.steps)) or any(p <= 0 or p > 1 for p in opts.traffic) or opts.traffic != sorted(set(opts.traffic)):
        parser.error("hold >=90s; ascending even steps <=80000; traffic probabilities (0,1]")
    if (opts.traffic_hold is not None and opts.traffic_hold < 90) or (opts.soak != 0 and opts.soak < 90):
        parser.error("traffic-hold and nonzero soak must be >=90s")
    traffic_duration = opts.traffic_hold or opts.hold
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
    configuration = opts.output.resolve() / "haproxy.cfg"
    configuration.write_text(proxy_config(opts.proxy_threads))
    env = dict(os.environ, TCP_CLUSTER_COOKIE=secrets.token_hex(32),
               BASELINE_HAPROXY_CONFIG=str(configuration))
    (opts.output / "plan.json").write_text(json.dumps({
        "steps": opts.steps, "probabilities": opts.traffic, "connection_hold_seconds": opts.hold,
        "traffic_hold_seconds": traffic_duration, "soak_seconds": opts.soak,
        "drain_seconds": 120, "p95_upper_ms": 100, "max_final_outstanding": 100,
        "max_backlog_slope_per_second": 1, "safety_outstanding": "max(100, population * .01)",
        "max_observation_gap_seconds": 30, "min_offered_rate_fraction": .95,
        "safety_memory_percent": 90}, indent=2) + "\n")
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
                failure_snapshot(args, directory)
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
            chosen = None
            for index, probability in enumerate(opts.traffic):
                set_traffic(args, probability, start=index == 0)
                samples, _ = phase(args, opts.output, f"traffic-{probability}", traffic_duration, largest, traffic=True, population=False)
                assessment = traffic_result(samples, largest, traffic_duration)
                assessment["offered_rate"] = largest * probability
                assessment["accepted"] = assessment["accepted"] and assessment.get("confirmation_rate", 0) >= largest * probability * .95
                results.append({"probability": probability, **assessment})
                set_traffic(args, 0.0)
                drain_label = f"drain-{probability}"
                drained, _ = phase(args, opts.output, drain_label, 120, largest)
                assessment["reconciliation"] = reconciliation(opts.output / drain_label, drained, largest)
                results[-1].update(assessment)
                if not assessment["reconciliation"]["complete"]:
                    raise RuntimeError("traffic step did not fully reconcile within drain deadline")
                if not assessment["accepted"]:
                    break
                chosen = probability
            if opts.soak and chosen is not None:
                set_traffic(args, chosen)
                samples, _ = phase(args, opts.output, "soak", opts.soak, largest, traffic=True, population=False)
                assessment = traffic_result(samples, largest, opts.soak)
                assessment["offered_rate"] = largest * chosen
                assessment["accepted"] = assessment["accepted"] and assessment.get("confirmation_rate", 0) >= largest * chosen * .95
                results.append({"soak_probability": chosen, **assessment})
                set_traffic(args, 0.0)
                drained, _ = phase(args, opts.output, "soak-drain", 120, largest)
                results[-1]["reconciliation"] = reconciliation(opts.output / "soak-drain", drained, largest)
                if not results[-1]["reconciliation"]["complete"]:
                    raise RuntimeError("soak did not fully reconcile within drain deadline")
            if opts.failure_scenario:
                if chosen is None or not results[-1].get("accepted") or not results[-1].get("reconciliation", {}).get("complete"):
                    raise RuntimeError("failure injection requires passing reconciled traffic")
                results.append({"failure_scenario": opts.failure_scenario})
                run_failure(args, opts.output, opts.failure_scenario, largest, chosen, results[-1])
            if opts.backend_outage:
                set_traffic(args, .01)
                node = args.tcp_container[0]
                actions = []
                pause = opts.outage_mode == "pause"
                try:
                    command(["docker", "pause", node] if pause else
                            ["docker", "stop", "--time", "10", node], timeout=30)
                    actions.append({"action": "paused" if pause else "stopped", "container": node,
                                    "timestamp": datetime.now(timezone.utc).isoformat()})
                    phase(args, opts.output, "backend-outage", 30, largest, population=False)
                finally:
                    command(["docker", "unpause" if pause else "start", node], timeout=30)
                    actions.append({"action": "resumed" if pause else "started", "container": node,
                                    "timestamp": datetime.now(timezone.utc).isoformat()})
                    (opts.output / "outage-actions.json").write_text(json.dumps(actions, indent=2) + "\n")
                phase(args, opts.output, "backend-recovery", 180, largest, population=False)
                set_traffic(args, 0.0)
                phase(args, opts.output, "recovery-drain", 120, largest)
    finally:
        (opts.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        # Save counters above before writers stop. Only this fresh project's volumes are removed.
        try:
            command(COMPOSE + ["stop", "loadgen", "tcp", "web"], env=env)
            pg = containers(env, "postgres")
            if pg:
                counts = command(["docker", "exec", pg[0], "psql", "-U", "chatchat", "-d", "chatchat_baseline", "-Atc",
                    "TRUNCATE messages, users, admin_users RESTART IDENTITY; SELECT (SELECT count(*) FROM messages), (SELECT count(*) FROM users), (SELECT count(*) FROM admin_users);"], timeout=10)
                (opts.output / "cleanup.txt").write_text(counts + "\n")
        finally:
            command(COMPOSE + ["down", "-v", "--remove-orphans"], env=env)



if __name__ == "__main__":
    main()
