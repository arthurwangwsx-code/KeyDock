import copy
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock
import release_quality as quality
from keydock_common import CONFIG, PipelineError, atomic_json, sha256
from quality_fixture import SOURCE, TIMING, fixture_ci, fixture_logs, fixture_summary


class ReleaseQualityTests(unittest.TestCase):
    def test_core_only_summary_cannot_authorize_a_release(self):
        logs = fixture_logs(); del logs[quality.OCR_STAGE]
        summary = fixture_summary(logs)
        self.assertEqual(summary["ocr"]["status"], "NOT_QUALIFIED")
        with self.assertRaises(PipelineError): quality.validate_public(summary, SOURCE, CONFIG["version"], CONFIG["buildNumber"])

    def test_fake_pass_missing_ocr_inventory_and_empty_partitions_fail(self):
        for mutation in ("missing-record", "missing-case", "failed-test", "empty-python"):
            with self.subTest(mutation=mutation):
                logs = fixture_logs()
                if mutation == "missing-record": logs[quality.OCR_STAGE] = logs["swift-tests"]
                elif mutation == "missing-case": logs["swift-inventory"] = logs["swift-inventory"].replace(quality.OCR_ID, "")
                elif mutation == "failed-test": logs[quality.OCR_STAGE] += "✘ actual failure\n"
                else: logs["pipeline-tests"] = "Ran 0 tests\nOK\n"
                with self.assertRaises(PipelineError): fixture_summary(logs)

    def test_wrong_recognition_mode_or_unrecognized_repeat_cannot_qualify(self):
        for field in ("mode", "repeat", "fixture"):
            logs = fixture_logs(); lines = logs[quality.OCR_STAGE].splitlines()
            record = json.loads(lines[0].split(quality.OCR_MARKER, 1)[1])
            if field == "mode": record["configuration"]["level"] = "fast"
            elif field == "repeat": record["rounds"][1]["hasSynthetic"] = False
            else: record["fixtureSHA256"] = "unknown"
            logs[quality.OCR_STAGE] = quality.OCR_MARKER + json.dumps(record) + "\n" + "\n".join(lines[1:])
            with self.subTest(field=field), self.assertRaises(PipelineError): fixture_summary(logs)

    def test_foreign_source_build_or_non_native_host_is_rejected(self):
        original = fixture_summary()
        quality.validate_public(original, SOURCE, CONFIG["version"], CONFIG["buildNumber"])
        for change in ("source", "build", "host"):
            summary = copy.deepcopy(original)
            if change == "source": summary["source"]["commit"] = "d" * 40
            elif change == "build": summary["buildNumber"] = "stale"
            else: summary["host"]["architecture"] = "x86_64"
            with self.subTest(change=change), self.assertRaises(PipelineError): quality.validate_public(summary, SOURCE, CONFIG["version"], CONFIG["buildNumber"])

    def test_local_receipt_rechecks_logs_source_and_derived_results(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(quality, "ROOT", Path(temporary)):
            directory = Path(temporary) / ".local/pipeline/20261124T000000000000Z"; directory.mkdir(parents=True)
            hashes = {}
            for relative in quality.SOURCE_FILES:
                file = Path(temporary) / relative; file.parent.mkdir(parents=True, exist_ok=True); file.write_text("synthetic source")
                hashes[relative] = sha256(file)
            logs = fixture_logs()
            paths = {}
            for name, content in logs.items():
                file = directory / (name + ".log"); file.write_text(content)
                paths[name] = str(file.relative_to(Path(temporary)))
            summary = fixture_summary(logs, hashes)
            receipt = {"summary": summary, "timingFilter": TIMING, "logs": paths}
            with self.assertRaises(PipelineError): quality.require_local(SOURCE)
            atomic_json(quality.receipt_path(SOURCE["commit"]), receipt)
            atomic_json(quality.latest_path(SOURCE["commit"]), {"source":SOURCE,"status":"passed"})
            self.assertEqual(quality.require_local(SOURCE), summary)
            atomic_json(quality.latest_path(SOURCE["commit"]), {"source":SOURCE,"status":"failed"})
            with self.assertRaises(PipelineError): quality.require_local(SOURCE)
            atomic_json(quality.latest_path(SOURCE["commit"]), {"source":SOURCE,"status":"passed"})
            with patch.object(quality, "host_facts", return_value={**summary["host"], "sdkBuild":"changed"}):
                with self.assertRaises(PipelineError): quality.require_local(SOURCE,current_host=True)
            (directory / "swift-tests.log").write_text(logs["swift-tests"] + "changed bytes\n")
            with self.assertRaises(PipelineError): quality.require_local(SOURCE)
            (directory / "swift-tests.log").write_text(logs["swift-tests"])
            receipt["summary"]["tests"]["executedCount"] = 999
            atomic_json(quality.receipt_path(SOURCE["commit"]), receipt)
            with self.assertRaises(PipelineError): quality.require_local(SOURCE)

    def test_full_check_attempts_keep_running_or_failed_state_until_a_new_pass(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(quality,"ROOT",Path(temporary)):
            attempt = quality.begin_check(Path("first-run"),SOURCE,False)
            self.assertEqual(json.loads(quality.latest_path(SOURCE["commit"]).read_text())["status"],"running")
            quality.finish_check(attempt,False)
            self.assertEqual(json.loads(quality.latest_path(SOURCE["commit"]).read_text())["status"],"failed")
            newer = quality.begin_check(Path("second-run"),SOURCE,False)
            with self.assertRaises(PipelineError): quality.finish_check(attempt,True)
            quality.finish_check(newer,True)
            self.assertEqual(json.loads(quality.latest_path(SOURCE["commit"]).read_text())["status"],"passed")

    def test_same_team_old_dmg_app_cannot_replace_the_qualified_zip_payload(self):
        fields = ("bundle_id","profile","safe_smoke","source_dirty","commit","release_version","build_number","architecture","qualification_sha256","bundle_sha256","binary_sha256","code_signature","notarized")
        expected = {name:"synthetic" for name in fields}
        expected["data_compatibility"] = keydock.current_data_compatibility()
        keydock.compare_app_payloads(copy.deepcopy(expected),expected)
        for field in ("commit","release_version","build_number","qualification_sha256","bundle_sha256","data_compatibility"):
            actual = copy.deepcopy(expected); actual[field] = "old payload"
            with self.subTest(field=field), self.assertRaises(PipelineError): keydock.compare_app_payloads(actual,expected)

    def test_only_successful_same_source_push_ci_can_authorize_packaging(self):
        quality.validate_ci(fixture_ci(), SOURCE)
        for field, value in (("head_sha", "e" * 40), ("event", "workflow_dispatch"), ("conclusion", "failure"), ("path", ".github/workflows/other.yml")):
            facts = fixture_ci(); facts[field] = value
            with self.subTest(field=field), self.assertRaises(PipelineError): quality.validate_ci(facts, SOURCE)

    def test_qualification_timeout_is_failure_even_after_the_owned_group_exits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = Mock(pid=12345); process.wait.side_effect = [subprocess.TimeoutExpired("synthetic", 1), 0]
            with patch.object(keydock, "ROOT", root), patch.object(keydock, "RUN_DIR", root / "logs"), patch.object(keydock.subprocess, "Popen", return_value=process), patch.object(keydock.os, "killpg") as kill:
                with self.assertRaises(PipelineError): keydock.stage("synthetic-ocr", ["synthetic"], timeout=1)
                kill.assert_called_once_with(12345, signal.SIGTERM)
                self.assertEqual(json.loads((root / "logs/synthetic-ocr.json").read_text())["exitCode"], 124)


if __name__ == "__main__": unittest.main()
