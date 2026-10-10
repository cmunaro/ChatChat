"""Check the dashboard's actual runtime queries with promtool (no live data).

Run: python3 observability/test_dashboard.py /path/to/promtool
Or: python3 observability/test_dashboard.py docker exec -i CONTAINER /bin/promtool
"""

import json
from pathlib import Path
import subprocess
import sys


dashboard = json.loads((Path(__file__).parent / "grafana/dashboards/chatchat.json").read_text())
panels = {panel["title"]: panel for panel in dashboard["panels"]}
queries = {
    "connections": panels["Connected TCP clients"]["targets"][0]["expr"],
    "postgres": panels["Pending ownership"]["targets"][0]["expr"],
    "sender": panels["Pending ownership"]["targets"][1]["expr"],
    "health": panels["Runtime collection health"]["targets"][0]["expr"],
}


def scenario(name, *, failed=False, stale=False, missing=False, down=False, zero=False, all_unavailable=False):
    series = []

    def add(metric, node, value, source=None):
        labels = f'job="chatchat_tcp",instance="{node}"'
        if source:
            labels += f',source="{source}"'
        series.append({"series": f"{metric}{{{labels}}}", "values": f"{value}+0x20"})

    for node in ("a", "b"):
        add("up", node, 0 if down and node == "b" else 1)
        for source in ("connections", "inbox", "sender", "postgres"):
            if missing and node == "b":
                continue
            add("chatchat_runtime_collection_success", node, 0 if all_unavailable or (failed and node == "b") else 1, source)
            add("chatchat_runtime_collection_last_success_timestamp_seconds", node, 1 if stale and node == "b" else 10, source)
        for metric, value in (
            ("chatchat_tcp_connected_clients", 2),
            ("chatchat_delivery_attempts", 4),
            ("chatchat_postgres_undelivered_messages", 3),
        ):
            add(metric, node, 0 if zero else value)

    incomplete = failed or stale or missing or down or all_unavailable
    tests = []
    for key, value in (("connections", 4), ("sender", 8), ("postgres", 3)):
        expected = [] if all_unavailable or (incomplete and key != "postgres") else [{"labels": "{}", "value": 0 if zero else value}]
        tests.append({"expr": queries[key], "eval_time": "20s", "exp_samples": expected})

    expected_health = []
    for node in ("a", "b"):
        for source in ("connections", "inbox", "sender", "postgres"):
            expected_health.append({
                "labels": f'{{job="chatchat_tcp",instance="{node}",source="{source}"}}',
                "value": -1 if missing and node == "b" else (0 if all_unavailable or (incomplete and node == "b") else 1),
            })
    tests.append({"expr": queries["health"], "eval_time": "20s", "exp_samples": expected_health})
    return {"name": name, "interval": "1s", "input_series": series, "promql_expr_test": tests}


tests = [
    scenario("fresh complete totals and shared database"),
    scenario("genuine zero", zero=True),
    scenario("failed collection", failed=True),
    scenario("expired collection", stale=True),
    scenario("missing collection", missing=True),
    scenario("down exporter", down=True),
    scenario("all sources unavailable", all_unavailable=True),
]
# Legacy exporters must be visibly unsupported, never passed as fresh totals.
legacy_series = [
    {"series": 'up{job="chatchat_tcp",instance="old"}', "values": "1+0x20"},
    {"series": 'chatchat_tcp_connected_clients{job="chatchat_tcp",instance="old"}', "values": "7+0x20"},
]
tests.append({"name": "legacy deployment", "input_series": legacy_series, "promql_expr_test": [
    {"expr": queries["connections"], "eval_time": "20s", "exp_samples": []},
    {"expr": queries["health"], "eval_time": "20s", "exp_samples": [
        {"labels": '{job="chatchat_tcp",instance="old",source="' + source + '"}', "value": -1}
        for source in ("connections", "inbox", "sender", "postgres")
    ]},
    {"expr": panels["Legacy runtime readings — freshness unverified"]["targets"][0]["expr"],
     "eval_time": "20s", "exp_samples": [
         {"labels": '{__name__="chatchat_tcp_connected_clients",job="chatchat_tcp",instance="old"}', "value": 7}
     ]},
]})
tests.append({"name": "modern exporters excluded from legacy view", "input_series": legacy_series + [
    {"series": 'chatchat_runtime_collection_success{job="chatchat_tcp",instance="old",source="connections"}', "values": "0+0x20"}
], "promql_expr_test": [{
    "expr": panels["Legacy runtime readings — freshness unverified"]["targets"][0]["expr"],
    "eval_time": "20s", "exp_samples": []
}]})
tests.append({"name": "HAProxy live sockets and active backends", "input_series": [
    {"series": 'up{job="haproxy",instance="lb"}', "values": "1+0x20"},
    {"series": 'haproxy_server_current_sessions{job="haproxy",instance="lb",proxy="chatchat_tcp_nodes",server="tcp1"}', "values": "9+0x20"},
    {"series": 'haproxy_server_status{job="haproxy",instance="lb",proxy="chatchat_tcp_nodes",server="tcp1",state="UP"}', "values": "1+0x20"},
    {"series": 'haproxy_server_current_sessions{job="haproxy",instance="lb",proxy="chatchat_tcp_nodes",server="unused"}', "values": "0+0x20"},
    {"series": 'haproxy_server_status{job="haproxy",instance="lb",proxy="chatchat_tcp_nodes",server="unused",state="UP"}', "values": "0+0x20"},
], "promql_expr_test": [
    {"expr": panels["TCP sessions (HAProxy)"]["targets"][0]["expr"], "eval_time": "20s", "exp_samples": [{"labels": "{}", "value": 9}]},
    {"expr": panels["TCP connections per node"]["targets"][0]["expr"], "eval_time": "20s", "exp_samples": [
        {"labels": '{__name__="haproxy_server_current_sessions",job="haproxy",instance="lb",proxy="chatchat_tcp_nodes",server="tcp1"}', "value": 9}
    ]}
]})
# Parse every modified runtime query, even panels not covered by numeric cases.
for panel in dashboard["panels"]:
    for target in panel.get("targets", []):
        if target.get("expr") and ("chatchat_runtime_collection" in target["expr"] or panel["title"] in (
            "Delivery stage p95", "Delivery stage mean", "Delivery stage outcomes",
            "TCP disconnect reasons", "TCP Redis latency", "TCP Redis failures", "TCP database timing",
            "TCP sessions (HAProxy)", "TCP connections per node", "TCP connection rate"
        )):
            expression = target["expr"].replace("$__rate_interval", "1m")
            tests.append({"name": "empty " + panel["title"], "promql_expr_test": [
                {"expr": expression, "eval_time": "20s", "exp_samples": []}
            ]})

command = sys.argv[1:] or ["promtool"]
result = subprocess.run(
    command + ["test", "rules", "/dev/stdin"],
    input=json.dumps({"evaluation_interval": "1s", "tests": tests}),
    text=True,
    check=False,
)
sys.exit(result.returncode)
