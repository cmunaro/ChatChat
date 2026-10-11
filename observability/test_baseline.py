import unittest
import json
from pathlib import Path
import tempfile
from datetime import timedelta
from datetime import datetime, timezone

import run_baseline as baseline


def sample(sockets=10000, age=0, failed=0):
    now = datetime.now(timezone.utc)
    def vector(value, instance):
        return {"metric": {"instance": instance, "source": "connections"}, "value": [0, str(value)]}
    return {"timestamp": now.isoformat(), "probes": {
        "prometheus:connections": {"status": "ok", "data": [vector(sockets / 2, n) for n in ["a", "b"]]},
        "prometheus:collection_health": {"status": "ok", "data": [vector(1, n) for n in ["a", "b"]]},
        "prometheus:collection_last_success": {"status": "ok", "data": [vector(now.timestamp() - age, n) for n in ["a", "b"]]},
        **{f"client:{n}": {"status": "ok", "data": {"phase": "ready", "queued_messages": 0, "unique_confirmed_messages": 0, "connection_diagnostics": {"reconnects": {"failed": failed}}}} for n in ["a", "b"]}}}


class BaselineTest(unittest.TestCase):
    def test_requires_fresh_authenticated_sockets_not_ready_wrappers(self):
        self.assertEqual(baseline.authenticated(sample()), 10000)
        self.assertIsNone(baseline.authenticated(sample(age=20)))
        missing = sample()
        missing["probes"]["prometheus:connections"] = {"status": "no_data"}
        self.assertIsNone(baseline.authenticated(missing))
        self.assertFalse(baseline.stable([sample(sockets=9000)] * 12, 10000))

    def test_missing_generator_data_and_backlog_stop_the_ramp(self):
        self.assertFalse(baseline.traffic_stop(sample(), 10000))
        missing = sample()
        del missing["probes"]["client:a"]
        self.assertTrue(baseline.traffic_stop(missing, 10000))
        backlog = sample()
        backlog["probes"]["client:a"]["data"]["queued_messages"] = 500
        self.assertTrue(baseline.traffic_stop(backlog, 10000))
        self.assertTrue(baseline.traffic_stop(sample(sockets=9000), 10000))

    def test_memory_safety_stop(self):
        row = sample()
        row["probes"]["docker_stats"] = {"status": "ok", "data": json.dumps({"MemPerc": "89.99%"})}
        self.assertFalse(baseline.traffic_stop(row, 10000))
        row["probes"]["docker_stats"]["data"] = json.dumps({"MemPerc": "90.00%"})
        self.assertTrue(baseline.traffic_stop(row, 10000))

    def test_observation_gap_is_not_capacity_evidence(self):
        first = sample()
        last = sample()
        last["timestamp"] = (datetime.fromisoformat(first["timestamp"]) + timedelta(seconds=330)).isoformat()
        self.assertFalse(baseline.stable([first] * 6 + [last], 10000))

    def test_traffic_gate_excludes_warmup_and_rejects_growth_latency(self):
        start = datetime.now(timezone.utc)
        rows = []
        for tick in range(30):
            row = sample(sockets=80000)
            row["timestamp"] = (start + timedelta(seconds=tick * 10)).isoformat()
            for value in row["probes"]["prometheus:collection_last_success"]["data"]:
                value["value"][1] = str(start.timestamp() + tick * 10)
            for state in baseline.clients(row):
                state.update(queued_messages=tick * 4000 + 10, unique_confirmed_messages=tick * 4000,
                             confirmation_latency_ms={"buckets": {str(n): tick * 4000 for n in (10, 50, 100, 500, 1000, 10000)}})
            rows.append(row)
        result = baseline.traffic_result(rows, 80000, 300)
        self.assertTrue(result["accepted"])
        self.assertEqual(result["confirmation_rate"], 800)
        original_time = rows[-1]["timestamp"]
        rows[-1]["timestamp"] = (start + timedelta(seconds=330)).isoformat()
        for value in rows[-1]["probes"]["prometheus:collection_last_success"]["data"]:
            value["value"][1] = str(start.timestamp() + 330)
        self.assertTrue(baseline.traffic_result(rows, 80000, 300)["observation_gap"])
        self.assertFalse(baseline.traffic_result(rows, 80000, 300)["accepted"])
        rows[-1]["timestamp"] = original_time
        for value in rows[-1]["probes"]["prometheus:collection_last_success"]["data"]:
            value["value"][1] = str(start.timestamp() + 290)
        rows[-1]["probes"]["docker_stats"] = {"status": "ok", "data": json.dumps({"MemPerc": "90%"})}
        self.assertFalse(baseline.traffic_result(rows, 80000, 300)["accepted"])
        del rows[-1]["probes"]["docker_stats"]
        self.assertFalse(baseline.traffic_result(rows[:10], 80000, 300)["accepted"])
        baseline.clients(rows[-1])[0]["queued_messages"] += 300
        self.assertFalse(baseline.traffic_result(rows, 80000, 300)["accepted"])
        baseline.clients(rows[-1])[0]["queued_messages"] -= 300
        for row in rows:
            for state in baseline.clients(row):
                state["confirmation_latency_ms"]["buckets"].update({str(n): 0 for n in (10, 50, 100)})
        self.assertFalse(baseline.traffic_result(rows, 80000, 300)["accepted"])

    def test_reconciliation_requires_complete_receiver_scans_and_zero_pending(self):
        row = sample()
        for state in baseline.clients(row):
            state.update(queued_messages=10, unique_confirmed_messages=10)
        scan = {"unavailable": 0, "unscanned": 0, "outbox": 0, "inflight": 0, "inbox": 10, "observed": 5000}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def write(scans, pending):
                (directory / "outboxes.json").write_text(json.dumps({"shards": scans}))
                (directory / "postgres-pending.json").write_text(json.dumps(pending))
            write({"a": scan, "b": scan}, {"rows": 0})
            self.assertTrue(baseline.reconciliation(directory, [row], 10000)["complete"])
            for bad in ({**scan, "unavailable": 1}, {**scan, "unscanned": 1},
                        {**scan, "inbox": 9}, {**scan, "observed": 4999}, {"available": False}):
                write({"a": scan, "b": bad}, {"rows": 0})
                self.assertFalse(baseline.reconciliation(directory, [row], 10000)["complete"])
            write({"a": scan, "b": scan}, {"available": False})
            self.assertFalse(baseline.reconciliation(directory, [row], 10000)["complete"])

    def test_requires_repeated_samples_and_no_reconnect_failure(self):
        self.assertTrue(baseline.stable([sample()] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 3, 10000))
        self.assertFalse(baseline.stable([sample(failed=1)] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 11 + [sample(age=20)], 10000))


if __name__ == "__main__":
    unittest.main()
