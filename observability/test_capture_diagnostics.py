"""Run with: python3 -m unittest discover -s observability -p 'test_capture*.py'."""

import argparse
from io import BytesIO
import json
import subprocess
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import capture_diagnostics as capture


class CaptureTests(unittest.TestCase):
    def test_target_scrape_failures_are_classified_without_raw_errors(self):
        targets = [{"labels": {"job": "haproxy"}, "health": "down",
                    "lastScrape": "2026-10-11T11:57:26Z", "lastScrapeDuration": 5,
                    "lastError": "Get http://private-host/metrics: context deadline exceeded"},
                   {"labels": {"job": "unrelated"}, "lastError": "private detail"}]
        response = {"status": "success", "data": {"activeTargets": targets}}
        with patch.object(capture.urllib.request, "urlopen", return_value=BytesIO(json.dumps(response).encode())):
            result = capture.prometheus_targets_probe("http://localhost")
        self.assertEqual(result["data"], [{"job": "haproxy", "health": "down",
                         "last_scrape": "2026-10-11T11:57:26Z", "scrape_seconds": 5,
                         "failure_reason": "timeout"}])
        self.assertNotIn("private", json.dumps(result))
        report = capture.summary([{"timestamp": "2026-10-11T11:57:26Z",
                                   "probes": {"prometheus:targets": result}}])
        self.assertIn('"failure_reason": "timeout"', report)
        self.assertIn("exporter scrapes", report)

    def test_target_capture_bounds_and_unavailable_responses(self):
        for raw, status in [(b"x" * (capture.MAX_BYTES + 1), "truncated"),
                            (b'{}', "unavailable"),
                            (b'{"status":"success","data":{"activeTargets":[]}}', "no_data")]:
            with patch.object(capture.urllib.request, "urlopen", return_value=BytesIO(raw)):
                self.assertEqual(capture.prometheus_targets_probe("http://localhost")["status"], status)

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

    def test_socket_scan_finds_listener_after_old_limit_and_counts_unique_ports(self):
        program = capture.SOCKET_PROBE.split("if command -v awk", 1)[1].split("awk '", 1)[1].split("' \"$file\"", 1)[0]
        rows = ["header"] + ["0: 0100007F:1234 0200007F:0FC8 01 00000000:00000000"] * 5000
        rows += ["0: 00000000:0FC8 00000000:0000 0A 00000000:00000008"]
        result = subprocess.run(["awk", program], input="\n".join(rows), text=True, capture_output=True, check=True)
        observation = capture.socket_observation(result.stdout)
        self.assertEqual(observation["listeners"][0]["address_hex"], "00000000:0FC8")
        self.assertEqual(observation["destinations"][0]["count"], 5000)
        self.assertEqual(observation["destinations"][0]["unique_source_ports"], 1)
        self.assertIn("TRUNCATED 0", observation["scan_bounds"][0])

    def test_socket_destination_limit_reports_omissions_without_losing_listeners(self):
        program = capture.SOCKET_PROBE.split("if command -v awk", 1)[1].split("awk '", 1)[1].split("' \"$file\"", 1)[0]
        rows = ["header"] + [f"0: {index:08X}:1234 0200007F:0FC8 01 00000000:00000000" for index in range(300)]
        rows += ["0: 00000000:0FC8 00000000:0000 0A 00000000:00000001"]
        result = subprocess.run(["awk", program], input="\n".join(rows), text=True, capture_output=True, check=True)
        observation = capture.socket_observation(result.stdout)
        self.assertEqual(len(observation["destinations"]), 256)
        self.assertEqual(len(observation["listeners"]), 1)
        self.assertIn("OMITTED_DESTINATION_ROWS 44", observation["scan_bounds"][0])

    def test_socket_row_limit_marks_incomplete_scan(self):
        program = capture.SOCKET_PROBE.split("if command -v awk", 1)[1].split("awk '", 1)[1].split("' \"$file\"", 1)[0]
        row = "0: 0100007F:1234 0200007F:0FC8 01 00000000:00000000\n"
        result = subprocess.run(["awk", program], input="header\n" + row * 262145,
                                text=True, capture_output=True, check=True)
        self.assertIn("SOCKET_ROWS 262144 TRUNCATED 1", result.stdout)

    def test_kernel_deltas_are_namespace_scoped_and_reset_is_unavailable(self):
        def sample(value):
            return {"timestamp": "now", "probes": {"proc:proxy": {"status": "ok", "data":
                "TcpExt: ListenDrops ListenOverflows\nTcpExt: %s %s" % (value, value)}}}
        report = capture.summary([sample(10), sample(15), sample(1)])
        self.assertIn("'ListenDrops': 5", report)
        self.assertEqual(report.count("unavailable (first sample/reset)"), 2)

    def test_repeated_runtime_probe_is_not_gated_by_slow_resource_interval(self):
        args = argparse.Namespace(prometheus="http://localhost", tcp_container=["tcp"], haproxy_container=[], loadgen_container=[], resource_container=[])
        with patch.object(capture, "prometheus_probe", return_value={"status": "no_data"}), patch.object(capture, "json_command_probe", return_value={"status": "ok", "data": {"redis": []}}), patch.object(capture, "command_probe", return_value={"status": "ok", "data": ""}):
            probes = capture.capture_sample(args, include_resources=False)["probes"]
        self.assertIn("runtime:tcp", probes)
        self.assertNotIn("proc:tcp", probes)
        self.assertIn("no_data", capture.summary([{"timestamp": "now", "probes": probes}]))

    def test_failed_ss_query_cannot_be_reported_as_zero_sockets(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "ss"
            executable.write_text("#!/bin/sh\nexit 1\n")
            executable.chmod(0o755)
            result = subprocess.run(["sh", "-c", capture.SOCKET_PROBE],
                env={**os.environ, "PATH": directory + ":" + os.environ["PATH"]},
                text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SOCKET_ROWS 0", result.stdout)

    def test_native_listener_backlog_and_source_port_counts(self):
        observation = capture.socket_observation(
            "LISTENER_NATIVE 0.0.0.0:4040 12 4096\n"
            "DESTINATION_NATIVE 172.31.0.10 172.31.0.6:4040 ESTAB 49417 49417\n"
            "SOCKET_ROWS 49417 TRUNCATED 0 OMITTED_DESTINATION_ROWS 0")
        self.assertEqual(observation["listeners"][0]["queued"], 12)
        self.assertEqual(observation["listeners"][0]["backlog"], 4096)
        self.assertEqual(observation["destinations"][0]["unique_source_ports"], 49417)
        for value in ("--privileged", "image;env", "a\nsecret"):
            with self.assertRaises(argparse.ArgumentTypeError):
                capture.probe_image(value)
        self.assertEqual(capture.probe_image("local/probe:v1"), "local/probe:v1")

    def test_container_targets_cannot_be_options_or_shell_text(self):
        for name in ("--privileged", "a;env", "a\nsecret"):
            with self.assertRaises(argparse.ArgumentTypeError):
                capture.container_name(name)
        self.assertEqual(capture.container_name("chatchat-tcp-1"), "chatchat-tcp-1")


if __name__ == "__main__":
    unittest.main()
