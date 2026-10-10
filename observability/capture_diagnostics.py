"""Read-only, bounded capture of ChatChat diagnostics. See README.md for usage."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import subprocess
import time
import urllib.parse
import urllib.request


MAX_BYTES = 256 * 1024
MAX_SERIES = 200
QUERIES = {
    "stage_p95_ms": "histogram_quantile(0.95, sum by (le, instance, stage, phase) (rate(chatchat_delivery_stage_duration_milliseconds_bucket{job=\"chatchat_tcp\"}[1m])))",
    "stage_mean_ms": "sum by (instance, stage, phase) (rate(chatchat_delivery_stage_duration_milliseconds_sum{job=\"chatchat_tcp\"}[1m])) / sum by (instance, stage, phase) (rate(chatchat_delivery_stage_duration_milliseconds_count{job=\"chatchat_tcp\"}[1m]))",
    "stage_outcomes": "sum by (instance, stage, phase, outcome) (rate(chatchat_delivery_stage_total{job=\"chatchat_tcp\"}[1m]))",
    "disconnects": "sum by (instance, reason) (rate(chatchat_tcp_disconnections_total{job=\"chatchat_tcp\"}[1m]))",
    "redis_p95_ms": "histogram_quantile(0.95, sum by (le, instance, operation) (rate(chatchat_redis_pipeline_duration_milliseconds_bucket{job=\"chatchat_tcp\"}[1m])))",
    "redis_failures": "sum by (instance, operation) (rate(chatchat_redis_pipeline_failures_total{job=\"chatchat_tcp\"}[1m]))",
    "database_queue_p95_ms": "histogram_quantile(0.95, sum by (le, instance) (rate(chatchat_broker_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket{job=\"chatchat_tcp\"}[1m])))",
    "database_execution_p95_ms": "histogram_quantile(0.95, sum by (le, instance) (rate(chatchat_broker_prom_ex_ecto_repo_query_execution_time_milliseconds_bucket{job=\"chatchat_tcp\"}[1m])))",
    "connections": "chatchat_tcp_connected_clients{job=\"chatchat_tcp\"}",
    "collection_health": "chatchat_runtime_collection_success{job=\"chatchat_tcp\"}",
    "collection_last_success": "chatchat_runtime_collection_last_success_timestamp_seconds{job=\"chatchat_tcp\"}",
    "postgres_pending": "chatchat_postgres_undelivered_messages{job=\"chatchat_tcp\"}",
    "capacity": "{__name__=~\"chatchat_delivery_attempts|chatchat_delivery_waiting|chatchat_delivery_fallback_workers\",job=\"chatchat_tcp\"}",
    "scheduler_queue": "chatchat_tcp_prom_ex_beam_stats_run_queue_count{job=\"chatchat_tcp\"}",
    "sender_results": "sum by (instance, status, reason) (rate(chatchat_messages_results_total{job=\"chatchat_tcp\"}[1m]))",
    "proxy_health": "haproxy_server_status{proxy=\"chatchat_tcp_nodes\",state=~\"UP|DOWN\"} == 1",
    "proxy_checks": "rate(haproxy_backend_check_up_down_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "proxy_errors": "rate(haproxy_backend_connection_errors_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "proxy_aborts": "rate(haproxy_backend_server_aborts_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "exporter_up": "up{job=~\"chatchat_tcp|haproxy\"}",
}

# Fixed commands only: never inspect environment, read logs, or scan Redis keys.
PROC_PROBE = r"""
for file in /proc/net/sockstat /proc/net/sockstat6 /proc/net/netstat /proc/net/snmp /proc/sys/net/ipv4/ip_local_port_range /proc/sys/net/core/somaxconn /proc/sys/net/ipv4/tcp_max_syn_backlog /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.events; do
  if [ -r "$file" ]; then printf '\nFILE %s\n' "$file"; cat "$file"; fi
done

count=0
for file in /proc/[0-9]*/comm; do
  [ -r "$file" ] || continue
  read -r comm < "$file"
  case "$comm" in beam.smp|haproxy)
    directory=${file%/comm}
    printf '\nPROCESS %s %s\n' "$directory" "$comm"
    if [ -r "$directory/limits" ]; then cat "$directory/limits"; fi
    if [ -r "$directory/status" ]; then awk '/^Threads:|^Cpus_allowed_list:/ {print}' "$directory/status"; fi
    if [ -r "$directory/fd" ]; then
      printf 'OPEN_FDS '; ls "$directory/fd" 2>/dev/null | wc -l
    else
      printf 'OPEN_FDS_UNAVAILABLE\n'
    fi
    count=$((count + 1)); [ "$count" -lt 32 ] || break
  esac
done
"""

SOCKET_PROBE = r"""
if command -v ss >/dev/null 2>&1; then
  (ss -H -lnt; printf 'SS_STATUS %s\n' "$?") | awk '
    $1 == "SS_STATUS" {if ($2 != 0) exit 1; next}
    NR <= 256 {print "LISTENER_NATIVE", $4, $2, $3}
    NR == 257 {print "LISTENER_TRUNCATED"; exit}' || exit 1
  (ss -H -nt state all '( dport = :4040 or dport = :5432 or dport = :6379 )'; printf 'SS_STATUS %s\n' "$?") | awk '
    $1 == "SS_STATUS" {if ($2 != 0) {failed=1; exit 1}; next}
    NR > 262144 {truncated=1; exit}
    {rows++; key=$4 " " $5 " " $1
     source=$4; sub(/:[^:]*$/, "", source)
     key=source " " $5 " " $1
     if (!(key in counts) && groups >= 256) {omitted++; next}
     if (!(key in counts)) groups++
     counts[key]++
     port=key " " $4
     if (!(port in ports)) {ports[port]=1; unique[key]++}
    }
    END {if (failed) exit 1; for (key in counts) print "DESTINATION_NATIVE", key, counts[key], unique[key]
         print "SOCKET_ROWS", rows+0, "TRUNCATED", truncated+0, "OMITTED_DESTINATION_ROWS", omitted+0}' || exit 1
  exit
fi
if command -v awk >/dev/null 2>&1; then
  files=0
  for file in /proc/net/tcp /proc/net/tcp6; do
    if [ -r "$file" ]; then
      files=$((files + 1))
      printf '\nLISTEN_QUEUE_SAMPLES %s (local_address tx:rx_hex)\n' "$file"
      awk '
        NR > 262145 { truncated=1; exit }
        NR > 1 {
          rows++
          if ($4 == "0A") print "LISTENER", $2, $5
          if (($4 == "01" || $4 == "02" || $4 == "06") && $3 ~ /:(0FC8|1538|18EB)$/) {
            split($2, local, ":")
            key=local[1] " " $3 " " $4
            if (!(key in counts) && destinations >= 256) { omitted++; next }
            if (!(key in counts)) destinations++
            counts[key]++
            source=key " " local[2]
            if (!(source in ports)) { ports[source]=1; unique_ports[key]++ }
          }
        }
        END {
          for (key in counts) print "DESTINATION_STATE", key, counts[key], unique_ports[key]
          print "SOCKET_ROWS", rows+0, "TRUNCATED", truncated+0, "OMITTED_DESTINATION_ROWS", omitted+0
        }' "$file" || exit 1
    fi
  done
  [ "$files" -gt 0 ] || { printf 'SOCKET_FILES_UNAVAILABLE\n'; exit 1; }
else
  printf '\nLISTEN_QUEUE_PROBE_UNAVAILABLE\n'
  exit 1
fi
"""

CLIENT_RPC = """
case Process.whereis(ChatchatClient.LoadGenerator) do
  nil -> IO.puts(Jason.encode!(%{available: false}))
  pid ->
    state = :sys.get_state(pid, 1_000)
    status = GenServer.call(state.simulation, :status, 1_000)
    simulation_state = :sys.get_state(state.simulation, 1_000)
    status = Map.put(status, :effective_options, Map.take(simulation_state.options,
      [:number_of_clients, :creation_concurrency, :ramp_interval_ms, :duration_seconds,
       :send_message_probability_per_second, :disconnection_probability_per_second,
       :message_payload_size]))
    status = Map.put(status, :runtime, %{schedulers: :erlang.system_info(:schedulers_online),
      run_queues: :erlang.statistics(:run_queue_lengths)})
    retry_sample = :ets.select(simulation_state.clients, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}], 16)
    {clients, truncated} = case retry_sample do
      :"$end_of_table" -> {[], false}
      {clients, continuation} -> {clients, continuation != :"$end_of_table"}
    end
    observations = Enum.map(clients, fn client ->
      try do
        client_state = :sys.get_state(client, 25)
        %{available: true, connected: client_state.socket != nil,
          reconnect_timer: client_state.reconnect_timer != nil,
          outbox_size: :gb_trees.size(client_state.store.outbox)}
      catch
        _, _ -> %{available: false}
      end
    end)
    status = Map.put(status, :retry_sample, %{limit: 16, truncated: truncated, observations: observations})
    IO.puts(Jason.encode!(Map.take(status, [:phase, :ready_clients, :running_wrappers,
      :queued_messages, :confirmed_attempts, :message_attempts, :retry_attempts, :unique_confirmed_messages, :confirmation_latency_ms,
      :failed_attempts, :rejected_messages, :submission_failures,
      :connection_diagnostics, :runtime, :retry_sample, :effective_options, :requested_clients, :startup_failures])))
end
"""


TCP_RPC = """
redis = Process.registered()
  |> Enum.filter(&(String.starts_with?(Atom.to_string(&1), "Elixir.ChatchatTcp.Redis")))
  |> Enum.take(32)
  |> Enum.map(fn name ->
    info = case Process.whereis(name) do
      nil -> nil
      pid -> Process.info(pid, [:message_queue_len, :reductions, :memory])
    end
    %{role: Atom.to_string(name), available: info != nil,
      process: if(info, do: Map.new(info), else: %{})}
  end)
IO.puts(Jason.encode!(%{redis: redis, schedulers: :erlang.system_info(:schedulers_online),
  run_queues: :erlang.statistics(:run_queue_lengths)}))
"""


def json_command_probe(command):
    result = command_probe(command)
    if result["status"] == "ok":
        try:
            result["data"] = json.loads(result["data"])
            if not isinstance(result["data"], dict):
                return {"status": "unavailable"}
        except ValueError:
            return {"status": "unavailable"}
    return result


def command_probe(command, timeout=3):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        if result.returncode:
            return {"status": "unavailable", "exit_code": result.returncode}
        if len(result.stdout.encode()) > MAX_BYTES:
            return {"status": "truncated"}
        return {"status": "ok", "data": result.stdout.strip()}
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    except OSError:
        return {"status": "unavailable"}


def prometheus_probe(base_url, query, timestamp):
    url = base_url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": query, "time": timestamp})
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            raw = response.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return {"status": "truncated"}
        payload = json.loads(raw)
        if payload.get("status") != "success" or payload.get("data", {}).get("resultType") != "vector":
            return {"status": "unavailable"}
        series = payload["data"]["result"]
        if len(series) > MAX_SERIES:
            return {"status": "truncated", "series_count": len(series)}
        return {"status": "ok" if series else "no_data", "data": series}
    except (OSError, ValueError):
        return {"status": "unavailable"}


def client_probe(container):
    result = command_probe(["docker", "exec", container, "/app/bin/chatchat_client", "rpc", CLIENT_RPC])
    if result["status"] == "ok":
        try:
            result["data"] = json.loads(result["data"])
            if not isinstance(result["data"], dict):
                return {"status": "unavailable"}
            if not result["data"].get("connection_diagnostics"):
                result["status"] = "diagnostics_unavailable"
        except ValueError:
            result = {"status": "unavailable"}
    return result


def timed_probe(function, arguments):
    started = datetime.now(timezone.utc).isoformat()
    result = function(*arguments)
    return {**result, "started_at": started, "finished_at": datetime.now(timezone.utc).isoformat()}


def capture_sample(args, include_resources=True):
    timestamp = time.time()
    probes = {"prometheus:" + name: (prometheus_probe, (args.prometheus, query, timestamp)) for name, query in QUERIES.items()}
    for container in args.tcp_container:
        probes["runtime:" + container] = (json_command_probe, (["docker", "exec", container, "/app/bin/chatchat_tcp", "rpc", TCP_RPC],))
    for container in args.loadgen_container:
        probes["client:" + container] = (client_probe, (container,))
    containers = list(dict.fromkeys(args.tcp_container + args.haproxy_container + args.loadgen_container + args.resource_container + getattr(args, "redis_container", []) + getattr(args, "postgres_container", [])))
    if containers:
        probes["docker_stats"] = (command_probe, (["docker", "stats", "--no-stream", "--format", "{{json .}}", *containers],))
    for container in getattr(args, "redis_container", []):
        probes["redis:" + container] = (command_probe, (["docker", "exec", container, "redis-cli", "INFO", "ALL"],))
    for container in getattr(args, "postgres_container", []):
        probes["postgres:" + container] = (command_probe, (["docker", "exec", container, "sh", "-c",
            'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT state, wait_event_type, wait_event, count(*) FROM pg_stat_activity GROUP BY 1,2,3;"'],))
    if include_resources:
        for container in containers:
            probes["proc:" + container] = (command_probe, (["docker", "exec", container, "sh", "-c", PROC_PROBE],))
        for container in list(dict.fromkeys(args.tcp_container + args.haproxy_container + args.loadgen_container)):
            image = getattr(args, "socket_probe_image", None)
            command = (["docker", "run", "--rm", "--read-only", "--pull", "never",
                        "--network", "container:" + container, "--cap-drop", "ALL",
                        "--entrypoint", "sh", image, "-c", SOCKET_PROBE] if image else
                       ["docker", "exec", container, "sh", "-c", SOCKET_PROBE])
            probes["sockets:" + container] = (command_probe, (command, 8))
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {name: pool.submit(timed_probe, function, arguments) for name, (function, arguments) in probes.items()}
        results = {name: future.result() for name, future in futures.items()}
    return {"timestamp": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(), "probes": results}


def socket_observation(raw):
    listeners, destinations, scans, counters = [], [], [], {}
    header = None
    for line in raw.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "LISTENER_NATIVE" and len(fields) == 4:
            listeners.append({"address": fields[1], "queued": int(fields[2]), "backlog": int(fields[3])})
        elif fields[0] == "DESTINATION_NATIVE" and len(fields) == 6:
            destinations.append({"source_address": fields[1], "destination": fields[2], "state": fields[3], "count": int(fields[4]), "unique_source_ports": int(fields[5])})
        elif fields[0] == "LISTENER_TRUNCATED":
            scans.append(line)
        elif fields[0] == "LISTENER" and len(fields) == 3:
            listeners.append({"address_hex": fields[1], "queue_hex": fields[2]})
        elif fields[0] == "DESTINATION_STATE" and len(fields) == 6:
            destinations.append({"source_address_hex": fields[1], "destination_hex": fields[2], "state_hex": fields[3], "count": int(fields[4]), "unique_source_ports": int(fields[5])})
        elif fields[0] == "SOCKET_ROWS":
            scans.append(line)
        elif fields[0] == "TcpExt:":
            if header is None:
                header = fields[1:]
            else:
                values = dict(zip(header, fields[1:]))
                counters = {key: int(values[key]) for key in ("ListenDrops", "ListenOverflows") if key in values}
                header = None
    return {"listeners": listeners, "destinations": destinations, "scan_bounds": scans, "counters": counters}


def finite_samples(probe):
    if probe.get("status") != "ok":
        return []
    values = []
    for series in probe.get("data", []):
        value = float(series["value"][1])
        if math.isfinite(value):
            values.append((series["metric"], value))
    return values


def summary(samples):
    count = 0
    unavailable = {}
    previous_kernel = {}
    lines = ["# Diagnostic capture", "", "", "",
             "This capture is observational. Stage distributions overlap: persist includes database",
             "checkout and commit; Redis calls also contribute to route/wake time. Do not add p95s.", "",
             "## Stage latency and concurrent pressure", ""]
    for sample in samples:
        count += 1
        probes = sample["probes"]
        for name, probe in probes.items():
            if probe["status"] != "ok":
                key = name + ": " + probe["status"]
                unavailable[key] = unavailable.get(key, 0) + 1
        for name, probe in probes.items():
            if name.startswith("client:") and probe["status"] in ("ok", "diagnostics_unavailable"):
                data = probe["data"]
                counters = {key: data.get(key) for key in ("phase", "ready_clients", "queued_messages", "confirmed_attempts", "failed_attempts", "connection_diagnostics")}
                retry = data.get("retry_sample", {})
                observations = retry.get("observations", [])
                counters["retry_sample"] = {"sampled": len(observations), "truncated": retry.get("truncated"),
                    "unavailable": sum(not row.get("available") for row in observations),
                    "connected": sum(row.get("connected", False) for row in observations),
                    "pending_reconnect": sum(row.get("reconnect_timer", False) for row in observations),
                    "outbox_entries": sum(row.get("outbox_size", 0) for row in observations)}
                lines.append(f"- {sample['timestamp']} {name}: " + json.dumps(counters, sort_keys=True))
            if name.startswith("runtime:") and probe["status"] == "ok":
                lines.append(f"- {sample['timestamp']} {name}: " + json.dumps(probe["data"], sort_keys=True))
            if name.startswith("proc:") and probe["status"] == "ok":
                socket_data = probes.get("sockets:" + name.removeprefix("proc:"), {})
                observation = socket_observation(probe["data"] + "\n" + (socket_data.get("data", "") if socket_data.get("status") == "ok" else ""))
                counters = observation["counters"]
                previous = previous_kernel.get(name)
                delta = {key: value - previous[key] for key, value in counters.items()
                         if previous and key in previous and value >= previous[key]}
                previous_kernel[name] = counters
                top = sorted(observation["destinations"], key=lambda row: row["count"], reverse=True)[:8]
                lines.append(f"- {sample['timestamp']} {name}: namespace counter deltas {delta or 'unavailable (first sample/reset)'}; "
                             f"listeners {observation['listeners']}; top destination/state counts {top}; bounds {observation['scan_bounds']}")
        stages = finite_samples(probes.get("prometheus:stage_mean_ms", {}))
        stages.sort(key=lambda item: item[1], reverse=True)
        top = ", ".join(f"{labels.get('instance')} {labels.get('stage')}/{labels.get('phase')}: {value:.1f} ms" for labels, value in stages[:3]) or "Unavailable"
        pressure = []
        for name in ("disconnects", "proxy_checks", "proxy_errors", "proxy_aborts", "scheduler_queue", "capacity"):
            entries = finite_samples(probes.get("prometheus:" + name, {}))
            if entries:
                peak = max(value for _, value in entries)
                pressure.append(f"{name} peak-series={peak:.2f}")
        cpu = []
        stats = probes.get("docker_stats", {})
        if stats.get("status") == "ok":
            for row in stats["data"].splitlines():
                try:
                    data = json.loads(row)
                    cpu.append(f"{data.get('Name')}: {data.get('CPUPerc')} CPU, {data.get('MemUsage')} memory")
                except ValueError:
                    pass
        lines.append(f"- {sample['timestamp']}: stage means: {top}; " + ("; ".join(pressure + cpu) or "pressure unavailable"))
    lines[2] = f"Samples: {count}"
    lines += ["", "## Missing evidence", ""]
    lines += [f"- {name}: {count} samples" for name, count in sorted(unavailable.items())] or ["None of the requested probes failed."]
    lines += ["", "## Attribution limits", "",
              "The slowest observed stage is evidence of elapsed time, not proof of causation.",
              "Compare per-node series and counter deltas in samples.jsonl with CPU, collection",
              "freshness, descriptor usage, port ranges, TIME_WAIT and listen-overflow counters.",
              "Socket totals cannot prove per-destination source-port exhaustion. Descriptor counts",
              "and kernel files are node snapshots; missing files are not evidence of zero pressure.",
              "Client retries require at least two status samples for deltas. No captured workload or",
              "missing stage/client diagnostics means bottleneck attribution remains pending.",
              "Shared CPU causation requires the separately isolated baseline in task 3.", ""]
    return "\n".join(lines)


def container_name(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value):
        raise argparse.ArgumentTypeError("invalid container name")
    return value


def probe_image(value):
    if len(value) > 255 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./:@-]*", value):
        raise argparse.ArgumentTypeError("invalid local probe image")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", default="http://localhost:9090")
    for role in ("tcp", "haproxy", "loadgen", "resource", "redis", "postgres"):
        parser.add_argument("--" + role + "-container", action="append", default=[], type=container_name)
    parser.add_argument("--socket-probe-image", type=probe_image, help="local image with sh, awk and iproute2 ss; shares only the target network namespace")
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--duration", type=float, default=300)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.interval <= 60 and args.interval <= args.duration <= 3600):
        parser.error("interval must be 1–60 seconds; duration must be interval–3600 seconds")
    url = urllib.parse.urlsplit(args.prometheus)
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
        parser.error("Prometheus must be an HTTP(S) URL without credentials")
    if sum(len(getattr(args, role + "_container")) for role in ("tcp", "haproxy", "loadgen", "resource", "redis", "postgres")) > 32:
        parser.error("at most 32 explicit container targets are supported")
    args.output.mkdir(parents=True, exist_ok=False)
    targets = list(dict.fromkeys(container
        for role in ("tcp", "haproxy", "loadgen", "resource", "redis", "postgres")
        for container in getattr(args, role + "_container")))
    resource_format = ('{"name":{{json .Name}},"image":{{json .Image}},'
        '"nano_cpus":{{json .HostConfig.NanoCpus}},"cpu_quota":{{json .HostConfig.CpuQuota}},'
        '"cpu_period":{{json .HostConfig.CpuPeriod}},"cpuset":{{json .HostConfig.CpusetCpus}},'
        '"memory_limit":{{json .HostConfig.Memory}},"ulimits":{{json .HostConfig.Ulimits}},'
        '"networks":{{json .NetworkSettings.Networks}}}')
    resources = command_probe(["docker", "inspect", "--format", resource_format, *targets]) if targets else {"status": "no_data"}
    (args.output / "capture.json").write_text(json.dumps({
        "interval": args.interval, "duration": args.duration,
        "effective_resources": resources,
        "socket_probe_image": args.socket_probe_image,
        "bounds": {"socket_rows_per_family": 262144, "destination_groups_per_family": 256,
                   "retry_sample": 16, "retry_timeout_ms": 25},
        "targets": {role: getattr(args, role + "_container") for role in ("tcp", "haproxy", "loadgen", "resource", "redis", "postgres")},
        "queries": QUERIES,
    }, indent=2) + "\n")
    started = time.monotonic()
    next_resource = started
    with (args.output / "samples.jsonl").open("w") as output:
        for index in range(math.ceil(args.duration / args.interval)):
            due = started + index * args.interval
            delay = due - time.monotonic()
            if delay < -args.interval:
                continue
            if delay > 0:
                time.sleep(delay)
            if time.monotonic() >= started + args.duration:
                break
            include_resources = time.monotonic() >= next_resource
            sample = capture_sample(args, include_resources)
            if include_resources:
                next_resource = time.monotonic() + 30
            output.write(json.dumps(sample) + "\n")
            output.flush()
    with (args.output / "samples.jsonl").open() as captured:
        report = summary(json.loads(line) for line in captured)
    (args.output / "summary.md").write_text(report)


if __name__ == "__main__":
    main()
