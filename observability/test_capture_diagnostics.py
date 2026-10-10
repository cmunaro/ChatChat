"""Run with: python3 -m unittest discover -s observability -p 'test_capture*.py'."""

import argparse
from io import BytesIO
import json
import subprocess
import unittest
from unittest.mock import patch

import capture_diagnostics as capture


class CaptureTests(unittest.TestCase):
    def test_command_timeout_and_missing_container_do_not_leak_error_text(self):
        with patch.object(capture.subprocess, "run", side_effect=subprocess.TimeoutExpired("docker", 3)):
            self.assertEqual(capture.command_probe(["docker"]), {"status": "timeout"})
        result = subprocess.CompletedProcess([], 1, "", "private diagnostic detail")
        with patch.object(capture.subprocess, "run", return_value=result):
            self.assertEqual(capture.client_probe("missing"), {"status": "unavailable", "exit_code": 1})

    def test_oversized_command_and_http_outputs_are_bounded(self):
        result = subprocess.CompletedProcess([], 0, "x" * (capture.MAX_BYTES + 1), "")
        with patch.object(capture.subprocess, "run", return_value=result):
            self.assertEqual(capture.command_probe(["docker"]), {"status": "truncated"})
        with patch.object(capture.urllib.request, "urlopen", return_value=BytesIO(b"x" * (capture.MAX_BYTES + 1))):
            self.assertEqual(capture.prometheus_probe("http://localhost", "up", 1), {"status": "truncated"})

    def test_absent_instrumentation_and_invalid_client_response_are_explicit(self):
        response = {"status": "success", "data": {"resultType": "vector", "result": []}}
        with patch.object(capture.urllib.request, "urlopen", return_value=BytesIO(json.dumps(response).encode())):
            self.assertEqual(capture.prometheus_probe("http://localhost", "up", 1)["status"], "no_data")
        with patch.object(capture, "command_probe", return_value={"status": "ok", "data": '{"phase":"running"}'}):
            self.assertEqual(capture.client_probe("old-generator")["status"], "diagnostics_unavailable")
        with patch.object(capture, "command_probe", return_value={"status": "ok", "data": '[]'}):
            self.assertEqual(capture.client_probe("invalid")["status"], "unavailable")

    def test_unavailable_http_probe_and_missing_generators_do_not_abort_sample(self):
        args = argparse.Namespace(prometheus="http://localhost", tcp_container=[], haproxy_container=[], loadgen_container=["missing"], resource_container=[])
        with patch.object(capture, "prometheus_probe", return_value={"status": "unavailable"}), patch.object(capture, "command_probe", return_value={"status": "timeout"}):
            sample = capture.capture_sample(args)
        self.assertEqual(sample["probes"]["client:missing"]["status"], "timeout")
        self.assertEqual(sample["probes"]["proc:missing"]["status"], "timeout")
        report = capture.summary(iter([sample]))
        self.assertIn("Samples: 1", report)
        self.assertIn("stage means: Unavailable", report)
        self.assertIn("bottleneck attribution remains pending", report)
        self.assertIn("client:missing: timeout", report)

    def test_report_correlates_measured_stage_with_concurrent_pressure_without_claiming_causation(self):
        def metric(labels, value):
            return {"status": "ok", "data": [{"metric": labels, "value": [1, str(value)]}]}

        sample = {"timestamp": "2026-10-10T00:00:00+00:00", "probes": {
            "prometheus:stage_mean_ms": metric({"instance": "node", "stage": "queue", "phase": "fallback"}, 500),
            "prometheus:disconnects": metric({"reason": "idle_timeout"}, 2),
            "docker_stats": {"status": "ok", "data": '{"Name":"tcp","CPUPerc":"100%","MemUsage":"1GiB"}'},
        }}
        report = capture.summary(iter([sample]))
        self.assertIn("queue/fallback: 500.0 ms", report)
        self.assertIn("disconnects peak-series=2.00", report)
        self.assertIn("100% CPU", report)
        self.assertIn("not proof of causation", report)
        self.assertEqual(capture.finite_samples(metric({}, "NaN")), [])

    def test_container_targets_cannot_be_options_or_shell_text(self):
        for name in ("--privileged", "a;env", "a\nsecret"):
            with self.assertRaises(argparse.ArgumentTypeError):
                capture.container_name(name)
        self.assertEqual(capture.container_name("chatchat-tcp-1"), "chatchat-tcp-1")


if __name__ == "__main__":
    unittest.main()
