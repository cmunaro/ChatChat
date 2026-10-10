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
    "capacity": "{__name__=~\"chatchat_delivery_attempts|chatchat_delivery_waiting|chatchat_delivery_fallback_workers\",job=\"chatchat_tcp\"}",
    "scheduler_queue": "chatchat_tcp_prom_ex_beam_stats_run_queue_count{job=\"chatchat_tcp\"}",
    "sender_results": "sum by (instance, status, reason) (rate(chatchat_messages_results_total{job=\"chatchat_tcp\"}[1m]))",
    "proxy_health": "haproxy_server_status{proxy=\"chatchat_tcp_nodes\",state=~\"UP|DOWN\"}",
    "proxy_checks": "rate(haproxy_backend_check_up_down_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "proxy_errors": "rate(haproxy_backend_connection_errors_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "proxy_aborts": "rate(haproxy_backend_server_aborts_total{proxy=\"chatchat_tcp_nodes\"}[1m])",
    "exporter_up": "up{job=~\"chatchat_tcp|haproxy\"}",
}

# Fixed commands only: never inspect environment, read logs, or scan Redis keys.
PROC_PROBE = r"""
for file in /proc/net/sockstat /proc/net/sockstat6 /proc/net/netstat /proc/net/snmp /proc/sys/net/ipv4/ip_local_port_range /proc/sys/net/core/somaxconn /proc/sys/net/ipv4/tcp_max_syn_backlog; do
  if [ -r "$file" ]; then printf '\nFILE %s\n' "$file"; cat "$file"; fi
done
if command -v awk >/dev/null 2>&1; then
  for file in /proc/net/tcp /proc/net/tcp6; do
    if [ -r "$file" ]; then
      printf '\nLISTEN_QUEUE_SAMPLES %s (local_address tx:rx_hex)\n' "$file"
      awk 'NR > 4097 { print "TRUNCATED_AFTER_4096_ROWS"; exit } NR > 1 && $4 == "0A" { print $2, $5 }' "$file"
    fi
  done
else
  printf '\nLISTEN_QUEUE_PROBE_UNAVAILABLE\n'
fi
count=0
for file in /proc/[0-9]*/comm; do
  [ -r "$file" ] || continue
  read -r comm < "$file"
  case "$comm" in beam.smp|haproxy)
    directory=${file%/comm}
    printf '\nPROCESS %s %s\n' "$directory" "$comm"
    if [ -r "$directory/limits" ]; then cat "$directory/limits"; fi
    if [ -r "$directory/fd" ]; then
      printf 'OPEN_FDS '; ls "$directory/fd" 2>/dev/null | wc -l
    else
      printf 'OPEN_FDS_UNAVAILABLE\n'
    fi
    count=$((count + 1)); [ "$count" -lt 32 ] || break
  esac
done
"""

CLIENT_RPC = """
case Process.whereis(ChatchatClient.LoadGenerator) do
  nil -> IO.puts(Jason.encode!(%{available: false}))
  pid ->
    state = :sys.get_state(pid, 1_000)
    status = GenServer.call(state.simulation, :status, 1_000)
    IO.puts(Jason.encode!(Map.take(status, [:phase, :ready_clients, :running_wrappers,
      :queued_messages, :confirmed_attempts, :failed_attempts, :submission_failures,
      :connection_diagnostics])))
end
"""


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


def capture_sample(args, include_resources=True):
    timestamp = time.time()
    probes = {"prometheus:" + name: (prometheus_probe, (args.prometheus, query, timestamp)) for name, query in QUERIES.items()}
    for container in args.loadgen_container:
        probes["client:" + container] = (client_probe, (container,))
    containers = list(dict.fromkeys(args.tcp_container + args.haproxy_container + args.loadgen_container + args.resource_container))
    if containers:
        probes["docker_stats"] = (command_probe, (["docker", "stats", "--no-stream", "--format", "{{json .}}", *containers],))
    if include_resources:
        for container in containers:
            probes["proc:" + container] = (command_probe, (["docker", "exec", container, "sh", "-c", PROC_PROBE],))
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {name: pool.submit(function, *arguments) for name, (function, arguments) in probes.items()}
        results = {name: future.result() for name, future in futures.items()}
    return {"timestamp": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(), "probes": results}


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", default="http://localhost:9090")
    for role in ("tcp", "haproxy", "loadgen", "resource"):
        parser.add_argument("--" + role + "-container", action="append", default=[], type=container_name)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--duration", type=float, default=300)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.interval <= 60 and args.interval <= args.duration <= 3600):
        parser.error("interval must be 1–60 seconds; duration must be interval–3600 seconds")
    url = urllib.parse.urlsplit(args.prometheus)
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
        parser.error("Prometheus must be an HTTP(S) URL without credentials")
    if sum(len(getattr(args, role + "_container")) for role in ("tcp", "haproxy", "loadgen", "resource")) > 32:
        parser.error("at most 32 explicit container targets are supported")
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "capture.json").write_text(json.dumps({
        "interval": args.interval, "duration": args.duration,
        "targets": {role: getattr(args, role + "_container") for role in ("tcp", "haproxy", "loadgen", "resource")},
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
