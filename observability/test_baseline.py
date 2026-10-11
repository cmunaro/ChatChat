import unittest
from unittest.mock import patch
from types import SimpleNamespace
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

    def test_failure_selection_rejects_combination_before_docker(self):
        with patch("sys.argv", ["runner", "--output", "/tmp/unused", "--backend-outage",
                                "--failure-scenario", "redis"]), patch.object(baseline, "command") as command:
            with self.assertRaises(SystemExit):
                baseline.main()
            command.assert_not_called()

    def test_failure_targets_and_safety_preserve_generator_gates(self):
        args = SimpleNamespace(tcp_container=["tcp1", "tcp2"], redis_container=["redis"],
                               postgres_container=["postgres"])
        for scenario, targets in [("redis", ["redis"]), ("postgres", ["postgres"]),
                                  ("tcp-all", ["tcp1", "tcp2"])]:
            self.assertEqual(baseline.failure_targets(args, scenario), targets)
        row = sample(sockets=0)
        self.assertTrue(baseline.traffic_stop({**row, "generator_counter_reset": True}, 10000, True))
        self.assertFalse(baseline.traffic_stop(row, 10000, True))
        del row["probes"]["client:a"]
        self.assertTrue(baseline.traffic_stop(row, 10000, True))
        args.tcp_container = ["tcp1"]
        with self.assertRaises(RuntimeError):
            baseline.failure_targets(args, "tcp-all")

    def test_failure_actions_restore_every_target_and_drain_after_partial_failure(self):
        args = SimpleNamespace(tcp_container=["tcp1", "tcp2"])
        for failed_action in (None, ("kill", "tcp2"), ("start", "tcp1")):
            calls = []
            def command(argv, **kwargs):
                calls.append(tuple(argv[1:]))
                if tuple(argv[1:]) == failed_action:
                    raise RuntimeError("injected failure")
            with tempfile.TemporaryDirectory() as temporary, patch.object(baseline, "command", command), \
                    patch.object(baseline, "set_traffic") as traffic, \
                    patch.object(baseline, "phase", return_value=([sample(sockets=0)], False)) as phase, \
                    patch.object(baseline, "reconciliation", return_value={"complete": False}):
                result = {}
                baseline.run_failure(args, Path(temporary), "tcp-all", 10000, .015, result)
                self.assertEqual(calls, [("kill", "tcp1"), ("kill", "tcp2"),
                                         ("start", "tcp1"), ("start", "tcp2")])
                self.assertFalse(result["accepted"])
                self.assertEqual(phase.call_args.args[2], "failure-drain")
                self.assertEqual(traffic.call_args.args[1], 0.0)
                self.assertEqual(len(json.loads((Path(temporary) / "failure-scenario.json").read_text())["actions"]), 4)

    def test_safety_stop_halts_submissions_before_restoration(self):
        events = []
        row = sample(sockets=0)
        row["probes"]["docker_stats"] = {"status": "ok", "data": json.dumps({"MemPerc": "90%"})}
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(baseline, "command", side_effect=lambda argv, **kw: events.append(argv[1])), \
                patch.object(baseline, "set_traffic", side_effect=lambda args, p: events.append(p)), \
                patch.object(baseline, "phase", return_value=([row], False)), \
                patch.object(baseline, "reconciliation", return_value={"complete": True}):
            result = {}
            baseline.run_failure(SimpleNamespace(redis_container=["redis"]), Path(temporary),
                                 "redis", 10000, .015, result)
            self.assertLess(events.index(0.0), events.index("unpause"))
            self.assertTrue(result["safety_stop"])
            self.assertFalse(result["accepted"])

    def test_failure_acceptance_requires_reconciliation(self):
        start = datetime.now(timezone.utc)
        rows = []
        for tick in range(21):
            row = sample()
            now = start + timedelta(seconds=tick * 10)
            row["timestamp"] = now.isoformat()
            for value in row["probes"]["prometheus:collection_last_success"]["data"]:
                value["value"][1] = str(now.timestamp())
            rows.append(row)
        for complete in (True, False):
            with tempfile.TemporaryDirectory() as temporary, \
                    patch.object(baseline, "command"), patch.object(baseline, "set_traffic"), \
                    patch.object(baseline, "phase", side_effect=[(rows[:3], False), (rows[3:], False), (rows[-1:], False)]), \
                    patch.object(baseline, "reconciliation", return_value={"complete": complete}):
                result = {}
                baseline.run_failure(SimpleNamespace(postgres_container=["pg"]), Path(temporary),
                                     "postgres", 10000, .015, result)
                self.assertEqual(result["accepted"], complete)

    def test_recovery_needs_final_ninety_seconds_and_no_gap(self):
        rows = []
        start = datetime.now(timezone.utc)
        for tick in range(18):
            row = sample(sockets=10000 if tick >= 8 else 0, failed=3)
            now = start + timedelta(seconds=tick * 10)
            row["timestamp"] = now.isoformat()
            for value in row["probes"]["prometheus:collection_last_success"]["data"]:
                value["value"][1] = str(now.timestamp())
            rows.append(row)
        self.assertTrue(baseline.recovery_stable(rows, 10000))
        self.assertFalse(baseline.recovery_stable(rows[:17], 10000))
        self.assertFalse(baseline.recovery_stable(rows[:2] + rows[6:], 10000))

    def test_requires_repeated_samples_and_no_reconnect_failure(self):
        self.assertTrue(baseline.stable([sample()] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 3, 10000))
        self.assertFalse(baseline.stable([sample(failed=1)] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 11 + [sample(age=20)], 10000))


if __name__ == "__main__":
    unittest.main()
