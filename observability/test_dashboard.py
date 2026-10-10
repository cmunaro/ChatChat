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
                "value": 0 if all_unavailable or (incomplete and node == "b") else 1,
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
# Parse every modified runtime query, even panels not covered by numeric cases.
for panel in dashboard["panels"]:
    for target in panel.get("targets", []):
        if "chatchat_runtime_collection" in target.get("expr", ""):
            tests.append({"name": "empty " + panel["title"], "promql_expr_test": [
                {"expr": target["expr"], "eval_time": "20s", "exp_samples": []}
            ]})

command = sys.argv[1:] or ["promtool"]
result = subprocess.run(
    command + ["test", "rules", "/dev/stdin"],
    input=json.dumps({"evaluation_interval": "1s", "tests": tests}),
    text=True,
    check=False,
)
sys.exit(result.returncode)
