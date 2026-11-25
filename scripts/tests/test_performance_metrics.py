"""合成数据验证性能证据，不读取真实App、注册快捷键或控制其他进程。"""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import sys
import tempfile
import subprocess
import time
import unittest
import uuid
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock_performance as sampler
import keydock
from keydock_common import PipelineError, sha256
from performance_metrics import MetricsError, distribution, resource_delta, validate_query, validate_sample, validate_self_check

IMAGE = "11111111-2222-4333-8444-555555555555"


def sample(tick=24_000_000, user=12_000_000, system=0):
    return {"schemaVersion": 1, "kind": "keydock-process-resources", "identity": {
        "pid": 100, "uid": 502, "realUID": 502, "startUnixSeconds": 1, "startUnixMicroseconds": 5,
        "executablePath": "/synthetic/KeyDock.app/Contents/MacOS/KeyDock"}, "executableUUID": IMAGE,
        "processStartAbsoluteTicks": 1, "userTimeMachTicks": user, "systemTimeMachTicks": system,
        "residentBytes": 10_000, "physicalFootprintBytes": 6_000, "absoluteTimeTicks": tick,
        "continuousTimeTicks": tick, "timebaseNumerator": 125, "timebaseDenominator": 3,
        "lowPowerMode": False, "thermalState": "nominal"}


def query_report():
    result = {"schemaVersion": 3, "fixture": "keydock-synthetic-catalog-v1", "itemCount": 2000, "warmups": 10,
              "configuration": "Release", "matchesExpectedResults": True, "system": "Synthetic system",
              "lowPowerMode": False, "thermalState": 0, "panelFirstFrameQualification": "NOT_QUALIFIED",
              "catalogPreparation": {"scope": "synthetic fixture construction and Unicode search preparation; excludes indexing and UI", "milliseconds": 30.0, "normalizedUTF8Bytes": 100_000}}
    for kind in ["ranking", "queryPipeline"]:
        points = []
        for index in range(100):
            value = {"ordinal": index, "variant": "application-prefix" if index % 2 == 0 else "localized-keywords",
                     "milliseconds": index + 1, "resultCount": 10}
            if kind == "queryPipeline": value.update(queryID=str(uuid.uuid4()), generation=index + 11)
            points.append(value)
        result[kind] = {"scope": "synthetic", "samples": points, "p50Milliseconds": 50, "p95Milliseconds": 95,
                        "maxMilliseconds": 100, "targetMilliseconds": 50, "pass": False}
    return result


class PerformanceMetricsTests(unittest.TestCase):
    def test_nearest_rank_uses_all_samples_and_rejects_non_finite_values(self):
        result = distribution(list(range(101, 0, -1)))
        self.assertEqual(result, {"count": 101, "minimum": 1, "p50": 51, "p95": 96, "maximum": 101})
        for values in [[], [math.nan], [math.inf], [-1], [True], ["1"]]:
            with self.subTest(values=values), self.assertRaises(MetricsError): distribution(values)

    def test_non_one_to_one_timebase_and_multicore_cpu_are_not_nanoseconds(self):
        before, after = sample(), sample(tick=48_000_000, user=60_000_000, system=12_000_000)
        measured = resource_delta(before, after)
        self.assertAlmostEqual(measured["elapsedSeconds"], 1)
        self.assertAlmostEqual(measured["cpuSeconds"], 2.5)
        self.assertAlmostEqual(measured["cpuPercentOneCore"], 250)
        self.assertFalse(measured["sleepOrClockGap"])
        wrong = (after["userTimeMachTicks"] - before["userTimeMachTicks"]) / 1e9
        self.assertLess(wrong, .1)

    def test_sleep_gap_is_retained_and_counter_regression_is_never_zero(self):
        before, after = sample(), sample(tick=48_000_000)
        after["continuousTimeTicks"] += 48_000_000
        measured = resource_delta(before, after)
        self.assertTrue(measured["sleepOrClockGap"])
        self.assertAlmostEqual(measured["clockGapSeconds"], 2)
        for field in ["absoluteTimeTicks", "continuousTimeTicks", "userTimeMachTicks", "systemTimeMachTicks"]:
            first, second = sample(system=4), sample(tick=48_000_000, system=4)
            second[field] = first[field] - 1
            with self.subTest(field=field), self.assertRaises(MetricsError): resource_delta(first, second)

    def test_generation_uuid_path_and_owner_changes_are_rejected(self):
        anchor = sample()
        changes = [("identity", "pid", 101), ("identity", "uid", 503), ("identity", "startUnixMicroseconds", 6),
                   ("identity", "executablePath", "/synthetic/other"), (None, "executableUUID", str(uuid.uuid4()).upper()),
                   (None, "processStartAbsoluteTicks", 2), (None, "timebaseNumerator", 1)]
        for group, field, value in changes:
            current = copy.deepcopy(anchor)
            (current[group] if group else current)[field] = value
            with self.subTest(field=field), self.assertRaises(MetricsError): validate_sample(current, expected=anchor)
        for kwargs in [{"owner_uid": 503}, {"path": "/wrong"}, {"image_uuid": str(uuid.uuid4()).upper()}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(MetricsError): validate_sample(anchor, **kwargs)

    def test_native_schema_rejects_content_extra_fields_and_non_integer_counters(self):
        for field, value in [("userTimeMachTicks", True), ("residentBytes", -1), ("physicalFootprintBytes", 1.2),
                             ("timebaseNumerator", 0), ("thermalState", []), ("executableUUID", "bad")]:
            current = sample(); current[field] = value
            with self.subTest(field=field), self.assertRaises(MetricsError): validate_sample(current)
        current = sample(); current["privateContent"] = "Synthetic secret"
        with self.assertRaises(MetricsError): validate_sample(current)
        with self.assertRaises(MetricsError): validate_sample({"state": "unavailable", "reason": "notRunning"})

    def test_cpu_self_check_catches_raw_ticks_mislabeled_as_seconds(self):
        before, after = sample(), sample(tick=48_000_000, user=24_000_000)
        payload = {"kind": "keydock-owned-cpu-self-check", "before": before, "after": after, "posixCPUSeconds": .5, "checksum": 1}
        self.assertEqual(validate_self_check(payload)["status"], "PASS")
        payload["posixCPUSeconds"] = .012
        with self.assertRaises(MetricsError): validate_self_check(payload)

    def test_query_budget_failure_is_preserved_and_statistics_cannot_be_forged(self):
        report = query_report()
        self.assertEqual(validate_query(report)["status"], "FAIL")
        self.assertEqual(validate_query(report)["panelFirstFrameQualification"], "NOT_QUALIFIED")
        report["queryPipeline"]["p95Milliseconds"] = 1
        with self.assertRaises(MetricsError): validate_query(report)

    def test_query_identity_sample_order_and_scope_cannot_drift(self):
        for change in ["short", "stale", "duplicate", "results", "private", "debug", "order"]:
            report = query_report(); points = report["queryPipeline"]["samples"]
            if change == "short": points.pop()
            elif change == "stale": points[5]["generation"] = 1
            elif change == "duplicate": points[5]["queryID"] = points[4]["queryID"]
            elif change == "results": points[5]["resultCount"] = 1
            elif change == "private": points[5]["queryText"] = "Synthetic private input"
            elif change == "debug": report["configuration"] = "Debug"
            elif change == "order": points[5]["ordinal"] = True
            with self.subTest(change=change), self.assertRaises(MetricsError): validate_query(report)


class ResourceEvidenceTests(unittest.TestCase):
    def write_log(self, path, state="completed"):
        records = [{"event": "header", "phase": "declared-idle-hidden"},
                   {"event": "sample", "ordinal": 0, "phase": "declared-idle-hidden", "resources": sample()},
                   {"event": "phase", "phase": "synthetic-interaction"},
                   {"event": "sample", "ordinal": 1, "phase": "synthetic-interaction", "resources": sample(tick=48_000_000, user=24_000_000)},
                   {"event": "terminal", "status": state, "sampleCount": 2}]
        with path.open("xb") as stream:
            for record in records: sampler.write_record(stream, record)
        return records

    def test_raw_hash_and_incomplete_last_line_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "raw.ndjson"; self.write_log(path)
            original = path.read_bytes(); digest = sha256(path)
            samples, intervals, terminal = sampler.verify_log(path, digest)
            self.assertEqual(len(samples), 2); self.assertTrue(intervals[0]["phaseTransition"])
            self.assertEqual(terminal["status"], "completed")
            path.write_bytes(original[:-1])
            with self.assertRaises(MetricsError): sampler.verify_log(path, digest)
            with self.assertRaises(MetricsError): sampler.verify_log(path, sha256(path))

    def test_failed_and_interrupted_logs_are_retained_as_terminal_facts(self):
        with tempfile.TemporaryDirectory() as temporary:
            for state in ["failed", "interrupted"]:
                path = Path(temporary) / (state + ".ndjson"); self.write_log(path, state)
                self.assertEqual(sampler.verify_log(path, sha256(path))[2]["status"], state)

    def test_phase_round_trip_between_samples_is_excluded_from_stable_idle(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "raw.ndjson"
            records = self.write_log(path)
            records.insert(3, {"event": "phase", "phase": "declared-idle-hidden"})
            records[4]["phase"] = "declared-idle-hidden"
            path.unlink()
            with path.open("xb") as stream:
                for record in records: sampler.write_record(stream, record)
            _, intervals, terminal = sampler.verify_log(path, sha256(path))
            self.assertTrue(intervals[0]["phaseTransition"])
            self.assertEqual(terminal["observedPhases"], ["declared-idle-hidden", "synthetic-interaction"])

    def test_query_timeout_keeps_exact_partial_output_and_no_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            raw_stdout, raw_stderr = b"partial owned JSON", b"owned error bytes"
            error = subprocess.TimeoutExpired(["/synthetic/probe"], 60)
            owned = Mock(); owned.wait.side_effect = [error, 0]; owned.poll.return_value = None
            def start(command, stdout, stderr):
                stdout.write(raw_stdout); stdout.flush(); stderr.write(raw_stderr); stderr.flush()
                return owned
            with patch.object(sampler, "observer_identity", return_value={"source": "synthetic"}), patch.object(sampler.subprocess, "Popen", side_effect=start), patch("builtins.print"):
                self.assertEqual(sampler.query(Path("/synthetic/probe"), output), 1)
            owned.terminate.assert_called_once(); owned.kill.assert_not_called()
            self.assertEqual((output / "query.stdout").read_bytes(), raw_stdout)
            self.assertEqual((output / "query.stderr").read_bytes(), raw_stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertTrue(summary["timedOut"])
            self.assertEqual(summary["reason"], "query-tool-timeout")
            self.assertEqual(summary["exitCode"], 124)

    @unittest.skipUnless(os.name == "posix", "SIGINT验收需要POSIX自有进程")
    def test_owned_query_interrupt_keeps_written_bytes_and_reaps_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); output = directory / "output"; output.mkdir()
            probe = directory / "owned-probe"
            probe.write_text("#!" + sys.executable + "\nimport os, sys, time\nfrom pathlib import Path\nPath(" + repr(str(directory / "owned-pid")) + ").write_text(str(os.getpid()))\nsys.stdout.write('owned partial bytes'); sys.stdout.flush()\nsys.stderr.write('owned diagnostic'); sys.stderr.flush()\ntime.sleep(60)\n")
            probe.chmod(0o700)
            driver = directory / "driver.py"
            driver.write_text("import sys\nfrom pathlib import Path\nsys.path.insert(0, " + repr(str(Path(sampler.__file__).parent)) + ")\nimport keydock_performance as sampler\nsampler.observer_identity = lambda probe: {'source': 'owned-test'}\nsys.exit(sampler.query(Path(sys.argv[1]), Path(sys.argv[2])))\n")
            process = subprocess.Popen([sys.executable, str(driver), str(probe), str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not (output / "query.stderr").exists() or (output / "query.stderr").read_bytes() != b"owned diagnostic":
                    if time.monotonic() >= deadline or process.poll() is not None: self.fail("owned query fixture did not become ready")
                    time.sleep(.01)
                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 1, (stdout, stderr))
                self.assertEqual((output / "query.stdout").read_bytes(), b"owned partial bytes")
                self.assertEqual((output / "query.stderr").read_bytes(), b"owned diagnostic")
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "interrupted")
                self.assertEqual(summary["reason"], "operator-interrupted")
                self.assertEqual(summary["qualification"], "NOT_QUALIFIED")
                self.assertTrue(summary["interrupted"])
                with self.assertRaises(ProcessLookupError): os.kill(int((directory / "owned-pid").read_text()), 0)
            finally:
                sampler.stop_owned_child(process)
                for stream in (process.stdout, process.stderr): stream.close()

    def test_preflight_interrupt_also_has_terminal_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            argv = ["sampler", "--mode", "resident", "--probe", "/synthetic/probe", "--output", str(output), "--app", "/synthetic/app", "--pid", "100"]
            with patch.object(sys, "argv", argv), patch.object(sampler, "resident", side_effect=KeyboardInterrupt):
                self.assertEqual(sampler.main(), 130)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual((summary["status"], summary["qualification"]), ("interrupted", "NOT_QUALIFIED"))

    def test_image_swap_and_exit_never_select_another_pid(self):
        target = sampler.Target.__new__(sampler.Target)
        target.executable = Path(sample()["identity"]["executablePath"]); target.disk_identity = (1, 2, 3, 4)
        target.pid = 100; target.probe = Path("/synthetic/probe"); target.image_uuid = IMAGE
        target.anchor = sample(); target.previous = sample()
        with patch.object(sampler, "file_identity", return_value=(1, 2, 3, 5)), patch.object(sampler, "run_json") as collect:
            with self.assertRaisesRegex(MetricsError, "app-executable-changed"): target.poll()
            collect.assert_not_called()
        with patch.object(sampler, "file_identity", return_value=target.disk_identity), patch.object(sampler.os, "getuid", return_value=502), patch.object(sampler, "run_json", side_effect=MetricsError("native-notRunning")) as collect:
            with self.assertRaisesRegex(MetricsError, "native-notRunning"): target.poll()
            self.assertEqual(collect.call_count, 1)
            self.assertEqual(collect.call_args.args[0], [target.probe, "--pid", 100, "--executable", target.executable])

    def test_invalid_pipeline_arguments_do_not_compile_or_control_app(self):
        with patch.object(keydock, "stage") as stage:
            for kwargs in [{"mode": "resident"}, {"mode": "resident", "app": Path("/synthetic"), "pid": 1},
                           {"mode": "resident", "app": Path("/synthetic"), "pid": 100, "duration": math.nan},
                           {"mode": "query", "app": Path("/synthetic")}, {"mode": "probe-check", "pid": 100}]:
                with self.subTest(kwargs=kwargs), self.assertRaises(PipelineError): keydock.performance(**kwargs)
            stage.assert_not_called()


if __name__ == "__main__": unittest.main()
