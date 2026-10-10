import unittest
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

    def test_observation_gap_is_not_capacity_evidence(self):
        first = sample()
        last = sample()
        last["timestamp"] = (datetime.fromisoformat(first["timestamp"]) + timedelta(seconds=330)).isoformat()
        self.assertFalse(baseline.stable([first] * 6 + [last], 10000))

    def test_requires_repeated_samples_and_no_reconnect_failure(self):
        self.assertTrue(baseline.stable([sample()] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 3, 10000))
        self.assertFalse(baseline.stable([sample(failed=1)] * 12, 10000))
        self.assertFalse(baseline.stable([sample()] * 11 + [sample(age=20)], 10000))


if __name__ == "__main__":
    unittest.main()
