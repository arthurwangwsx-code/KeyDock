"""仅合成文件／协议替身；不提交真实公证、不操作系统镜像或个人App。"""
import copy
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock
import release_delivery as delivery
from keydock_common import CONFIG, PipelineError
from quality_fixture import fixture_ci, fixture_summary

IDENTIFIER = "11111111-2222-3333-4444-555555555555"
OTHER_ID = "11111111-2222-3333-4444-666666666666"
BINDING = {"source": {"commit": "a" * 40, "dirty": False}, "version": CONFIG["version"], "role": "dmg",
           "teamID": CONFIG["teamID"], "qualificationSHA256": "b" * 64, "coreCI": 123}


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.payload = self.root / "synthetic.dmg"
        self.payload.write_bytes(b"synthetic image; never mounted")
        self.receipt = self.root / "request.json"
        self.calls = []

    def response(self, arguments, directory, label, timeout):
        self.calls.append((list(map(str, arguments)), label, timeout))
        if arguments[0] == "submit":
            self.assertEqual(delivery.read_receipt(self.receipt)["state"], "submission-unknown")
            self.assertIn("--no-wait", arguments)
            return {"id": IDENTIFIER}
        if arguments[0] in ("info", "wait"): return {"id": IDENTIFIER, "status": "Accepted"}
        return {"jobId": IDENTIFIER, "status": "Accepted", "sha256": delivery.file_record(self.payload)["sha256"],
                "archiveFilename": self.payload.name}

    def submit(self): return delivery.notarize(self.payload, "synthetic-profile", self.receipt, BINDING)

    def unknown(self, identifier=None):
        delivery.durable_json(self.receipt, {"schemaVersion": 1, "binding": BINDING,
            "payload": delivery.file_record(self.payload), "state": "submitted" if identifier else "submission-unknown", "submissionID": identifier})

    def test_new_inode_copy_keeps_source_and_independent_bytes(self):
        before = delivery.file_record(self.payload)
        result = delivery.copy_payload(self.payload, self.root / "copy.dmg")
        self.assertEqual(result["source"], before)
        self.assertEqual(result["copy"]["sha256"], before["sha256"])
        self.assertNotEqual(result["copy"]["inode"], before["inode"])
        self.payload.write_bytes(b"creator changed later")
        self.assertEqual((self.root / "copy.dmg").read_bytes(), b"synthetic image; never mounted")

    def test_copy_rejects_source_change_and_preserves_both_files(self):
        original = delivery.file_record
        def changing(path):
            if Path(path).name == "copy.dmg": self.payload.write_bytes(b"changed during copy")
            return original(path)
        with patch.object(delivery, "file_record", side_effect=changing):
            with self.assertRaisesRegex(PipelineError, "differs"): delivery.copy_payload(self.payload, self.root / "copy.dmg")
        self.assertTrue((self.root / "copy.dmg").exists())

    def test_links_and_existing_destination_are_never_consumed_or_overwritten(self):
        link = self.root / "symlink.dmg"; link.symlink_to(self.payload)
        with self.assertRaises(PipelineError): delivery.copy_payload(link, self.root / "absent")
        os.link(self.payload, self.root / "hardlink.dmg")
        with self.assertRaises(PipelineError): delivery.copy_payload(self.payload, self.root / "absent")
        (self.root / "hardlink.dmg").unlink()
        with self.assertRaises(FileExistsError): delivery.copy_payload(self.payload, self.payload)

    def test_submit_id_persisted_before_wait_and_accepted_reuse_is_offline(self):
        original = self.response
        def observe(arguments, *args):
            if arguments[0] == "wait": self.assertEqual(delivery.read_receipt(self.receipt)["submissionID"], IDENTIFIER)
            return original(arguments, *args)
        with patch.object(delivery, "invoke_notary", side_effect=observe): self.assertEqual(self.submit(), IDENTIFIER)
        with patch.object(delivery, "invoke_notary") as network:
            self.assertEqual(self.submit(), IDENTIFIER); network.assert_not_called()
        self.assertEqual([c[0][0] for c in self.calls], ["submit", "wait", "log"])

    def test_submit_timeout_or_lost_id_never_automatically_resubmits(self):
        for response in (PipelineError("synthetic timeout"), {}):
            with self.subTest(response=type(response).__name__):
                self.receipt.unlink(missing_ok=True)
                with patch.object(delivery, "invoke_notary", side_effect=response if isinstance(response, Exception) else None,
                                  return_value=response):
                    with self.assertRaises(PipelineError): self.submit()
                with patch.object(delivery, "invoke_notary") as network:
                    with self.assertRaisesRegex(PipelineError, "outcome unknown"): self.submit()
                    network.assert_not_called()

    def test_id_durability_failure_before_or_after_rename_does_not_replay_submit(self):
        for after in (False, True):
            with self.subTest(after=after):
                self.receipt.unlink(missing_ok=True); self.calls.clear()
                original = delivery.durable_json
                def fault(path, value):
                    if value.get("state") == "submitted":
                        if after: original(path, value)
                        raise OSError("synthetic fsync failure")
                    original(path, value)
                with patch.object(delivery, "durable_json", side_effect=fault), patch.object(delivery, "invoke_notary", side_effect=self.response):
                    with self.assertRaises(OSError): self.submit()
                self.calls.clear()
                with patch.object(delivery, "invoke_notary", side_effect=self.response):
                    if after: self.assertEqual(self.submit(), IDENTIFIER)
                    else:
                        with self.assertRaises(PipelineError): self.submit()
                self.assertFalse(any(c[0][0] == "submit" for c in self.calls))

    def test_wait_timeout_reuses_known_id_and_never_submits_again(self):
        self.unknown(IDENTIFIER)
        with patch.object(delivery, "invoke_notary", side_effect=PipelineError("synthetic wait timeout")):
            with self.assertRaises(PipelineError): self.submit()
        with patch.object(delivery, "invoke_notary", side_effect=self.response): self.submit()
        self.assertEqual([c[0][0] for c in self.calls], ["wait", "log"])

    def test_input_drift_and_other_role_refuse_before_any_network(self):
        self.unknown(IDENTIFIER)
        self.payload.write_bytes(b"changed")
        with patch.object(delivery, "invoke_notary") as network:
            with self.assertRaises(PipelineError): delivery.query_request(self.receipt, "synthetic")
            network.assert_not_called()
        self.unknown(IDENTIFIER)
        with patch.object(delivery, "invoke_notary") as network:
            with self.assertRaises(PipelineError): delivery.query_request(self.receipt, "synthetic", expected_binding=dict(BINDING, role="app"))
            network.assert_not_called()

    def test_unknown_explicit_id_binds_only_after_exact_service_proof(self):
        self.unknown()
        original = self.response
        for field, value in (("sha256", "c" * 64), ("jobId", OTHER_ID)):
            def wrong(arguments, *args):
                result = original(arguments, *args)
                if arguments[0] == "log": result[field] = value
                return result
            with self.subTest(field=field), patch.object(delivery, "invoke_notary", side_effect=wrong):
                with self.assertRaises(PipelineError): delivery.query_request(self.receipt, "synthetic", attach_id=IDENTIFIER)
                self.assertIsNone(delivery.read_receipt(self.receipt)["submissionID"])
        with patch.object(delivery, "invoke_notary", side_effect=self.response):
            self.assertEqual(delivery.query_request(self.receipt, "synthetic", attach_id=IDENTIFIER), IDENTIFIER)
        self.assertFalse(any(c[0][0] == "submit" for c in self.calls))

    def test_pending_or_rejected_service_never_marks_accepted(self):
        for status in ("In Progress", "Invalid", "unexpected"):
            with self.subTest(status=status):
                self.unknown(IDENTIFIER)
                with patch.object(delivery, "invoke_notary", return_value={"id": IDENTIFIER, "status": status}) as network:
                    with self.assertRaises(PipelineError): self.submit()
                    self.assertEqual(network.call_count, 1)
                self.assertNotEqual(delivery.read_receipt(self.receipt)["state"], "accepted")

    def test_future_and_noninteger_schema_never_reuse_or_query(self):
        for schema in (2, True, 1.0, "1"):
            with self.subTest(schema=schema):
                self.unknown(IDENTIFIER)
                state = delivery.read_receipt(self.receipt); state["schemaVersion"] = schema
                delivery.durable_json(self.receipt, state)
                with patch.object(delivery, "invoke_notary") as network:
                    with self.assertRaises(PipelineError): self.submit()
                    with self.assertRaises(PipelineError): delivery.query_request(self.receipt, "synthetic")
                    network.assert_not_called()

    def test_outside_payload_receipt_is_refused_before_reading_payload(self):
        self.unknown(IDENTIFIER)
        state = delivery.read_receipt(self.receipt)
        outside = self.root / "outside"; outside.mkdir()
        state["payload"]["path"] = str(outside / "never-read.dmg")
        delivery.durable_json(self.receipt, state)
        with patch.object(delivery, "file_record") as files, patch.object(delivery, "invoke_notary") as network:
            with self.assertRaises(PipelineError): delivery.query_request(self.receipt, "synthetic")
            files.assert_not_called(); network.assert_not_called()

    def test_receipt_fd_rebind_and_actual_read_budget(self):
        self.unknown(IDENTIFIER)
        opened = delivery.os.open
        rebound = [False]
        def rebind(path, flags, *args, **kwargs):
            if Path(path) == self.receipt and not rebound[0]:
                rebound[0] = True
                self.receipt.rename(self.root / "old.json")
                self.receipt.write_text("{}")
            return opened(path, flags, *args, **kwargs)
        with patch.object(delivery.os, "open", side_effect=rebind):
            with self.assertRaises(PipelineError): delivery.read_receipt(self.receipt)
        self.receipt.write_bytes(b" " * (1024 * 1024 + 1))
        with self.assertRaises(PipelineError): delivery.read_receipt(self.receipt)

    def test_concurrent_owner_cannot_query_or_submit(self):
        self.unknown(IDENTIFIER)
        with delivery.exclusive(self.receipt.with_suffix(".lock")), patch.object(delivery, "invoke_notary") as network:
            with self.assertRaisesRegex(PipelineError, "active operator"): self.submit()
            network.assert_not_called()

    def test_uncheckpointed_input_stops_but_final_output_is_retained_and_rebuilt(self):
        files = delivery.FrozenFiles(self.root)
        output = self.root / "output.dmg"; output.write_bytes(b"failed staple")
        with self.assertRaises(PipelineError): files.file("input", output, lambda: None)
        files.file("final", output, lambda: output.write_bytes(b"new final"), rebuild=True)
        retained = list(self.root.glob("incomplete-final-*.dmg"))
        self.assertEqual(len(retained), 1); self.assertEqual(retained[0].read_bytes(), b"failed staple")
        files.file("final", output, lambda: self.fail("must not rebuild completed output"))
        output.chmod(0o600); output.write_bytes(b"changed")
        with self.assertRaises(PipelineError): files.file("final", output, lambda: None, rebuild=True)

    def test_candidate_path_rejects_links_and_shared_permissions(self):
        private = self.root / "run/package"; private.mkdir(parents=True, mode=0o700)
        delivery.require_candidate(private, self.root)
        link = self.root / "link"; link.symlink_to(private.parent)
        with self.assertRaises((PipelineError, OSError)): delivery.require_candidate(link / "package", self.root)
        escaped = self.root / "run/../run/package"
        with self.assertRaises(PipelineError): delivery.require_candidate(escaped, self.root / "run")
        private.chmod(0o755)
        with self.assertRaises(PipelineError): delivery.require_candidate(private, self.root)

    def test_real_owned_process_obeys_wall_clock_and_keeps_unknown_receipt(self):
        popen = subprocess.Popen
        def owned(*args, **kwargs):
            return popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
        with patch.object(delivery.subprocess, "Popen", side_effect=owned):
            with self.assertRaisesRegex(PipelineError, "wall-clock timeout"):
                delivery.invoke_notary(["info", IDENTIFIER], self.root, "owned-timeout", 0.05)
        self.assertEqual(len(list(self.root.glob("owned-timeout-*.stderr.log"))), 1)

    def test_term_and_hup_stop_owned_child_and_restore_signal_handlers(self):
        popen = subprocess.Popen
        for value in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=value):
                old_handler = signal.getsignal(value); children = []; timers = []
                def owned(*args, **kwargs):
                    child = popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
                    children.append(child)
                    timer = threading.Timer(0.05, lambda: os.kill(os.getpid(), value)); timer.start(); timers.append(timer)
                    return child
                with patch.object(delivery.subprocess, "Popen", side_effect=owned):
                    with self.assertRaisesRegex(PipelineError, "interrupted"): delivery.invoke_notary(["info", IDENTIFIER], self.root, "owned-cancel", 10)
                for timer in timers: timer.join()
                self.assertIsNotNone(children[0].poll())
                self.assertEqual(signal.getsignal(value), old_handler)

    def test_failed_submit_with_complete_id_preserves_id_before_reporting_failure(self):
        failure = delivery.NotaryCommandError("synthetic exit failure", {"id": IDENTIFIER})
        with patch.object(delivery, "invoke_notary", side_effect=failure):
            with self.assertRaises(PipelineError): self.submit()
        self.assertEqual(delivery.read_receipt(self.receipt)["submissionID"], IDENTIFIER)
        with patch.object(delivery, "invoke_notary", side_effect=self.response): self.submit()
        self.assertFalse(any(c[0][0] == "submit" for c in self.calls))

    def test_signal_during_popen_assignment_still_reaps_owned_child(self):
        popen = subprocess.Popen
        for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=value):
                children = []; old = signal.getsignal(value)
                def owned(*args, **kwargs):
                    child = popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
                    children.append(child)
                    os.kill(os.getpid(), value)
                    return child
                with patch.object(delivery.subprocess, "Popen", side_effect=owned):
                    with self.assertRaisesRegex(PipelineError, "interrupted"):
                        delivery.invoke_notary(["info", IDENTIFIER], self.root, "owned-create-cancel", 10)
                self.assertIsNotNone(children[0].poll()); self.assertEqual(signal.getsignal(value), old)

    def test_matching_hash_allows_audited_service_filename_difference(self):
        self.unknown(IDENTIFIER)
        original = self.response
        def renamed(arguments, *args):
            value = original(arguments, *args)
            if arguments[0] == "log": value["archiveFilename"] = "original-submission-name.dmg"
            return value
        with patch.object(delivery, "invoke_notary", side_effect=renamed): self.submit()
        self.assertEqual(delivery.read_receipt(self.receipt)["serviceProof"]["archiveFilename"], "original-submission-name.dmg")

    def test_package_resumes_after_staple_failure_without_resubmit_or_creator_rewrite(self):
        self.package_fault_resume("staple-dmg")

    def test_unsubmitted_partial_signature_is_retained_and_rebuilt(self):
        self.package_fault_resume("sign-dmg")

    def test_unsubmitted_partial_creator_is_retained_and_rebuilt(self):
        self.package_fault_resume("dmg")

    def test_partial_image_copy_is_retained_before_explicit_resume(self):
        self.package_fault_resume("copy-image-app")

    def package_fault_resume(self, fault):
        qualification, ci = fixture_summary(), fixture_ci()
        facts = {"profile": "release", "safe_smoke": False, "source_dirty": False, "commit": "a" * 40,
                 "release_version": CONFIG["version"], "build_number": CONFIG["buildNumber"], "version": "0.1.0",
                 "code_signature": {"kind": "developer-id", "team_id": CONFIG["teamID"], "hardened_runtime": True},
                 "bundle_id": CONFIG["bundleIdentifier"], "architecture": "arm64", "binary_sha256": "c" * 64,
                 "qualification_sha256": keydock.quality.digest(qualification), "bundle_sha256": "d" * 64,
                 "notarized": True, "data_compatibility": keydock.current_data_compatibility()}
        source = self.root / "source.app"; source.mkdir(); (source / "resource").write_bytes(b"original")
        run_dir = self.root / "repository/.local/pipeline/run"; run_dir.mkdir(parents=True)
        release = self.root / "release"; stages = []; fail_staple = [True]; submissions = []
        def command(args, **kwargs):
            args = list(map(str, args))
            if "-k" in args: Path(args[-1]).write_bytes(b"synthetic zip")
            elif args[0] == "/usr/bin/ditto": shutil.copytree(args[-2], args[-1])
        def stage(name, args, **kwargs):
            stages.append(name); destination = Path(args[-1])
            if str(args[0]) == "/usr/bin/ditto": command(args)
            if name == "dmg": destination.write_bytes(b"creator")
            if name == "sign-dmg": destination.write_bytes(destination.read_bytes() + b"signed")
            if name == "staple-dmg": destination.write_bytes(destination.read_bytes() + b"ticket")
            if name == fault and fail_staple[0]:
                fail_staple[0] = False; raise PipelineError("synthetic stage failure")
        def notary_response(arguments, directory, label, timeout):
            if arguments[0] == "submit": submissions.append(str(arguments[1])); return {"id": IDENTIFIER}
            if arguments[0] == "wait": return {"id": IDENTIFIER, "status": "Accepted"}
            request = delivery.read_receipt(directory / ("notary-app.json" if "notary-app.zip" in submissions[-1] else "notary-dmg.json"))
            return {"jobId": IDENTIFIER, "status": "Accepted", "sha256": request["payload"]["sha256"],
                    "archiveFilename": Path(request["payload"]["path"]).name}
        with patch.object(keydock, "ROOT", self.root / "repository"), patch.object(keydock, "BUILD", self.root / "build"), \
             patch.object(keydock, "DIST", release), patch.object(keydock, "RUN_DIR", run_dir), \
             patch.object(keydock, "source_identity", return_value=BINDING["source"]), \
             patch.object(keydock.quality, "require_local", return_value=qualification), patch.object(keydock.quality, "core_ci", return_value=ci), \
             patch.object(keydock, "inspect_app", return_value=facts), patch.object(keydock, "run", side_effect=command), \
             patch.object(keydock, "stage", side_effect=stage), patch.object(delivery, "invoke_notary", side_effect=notary_response), \
             patch.object(keydock, "verify_assets", side_effect=lambda p: json.loads((Path(p) / "release-manifest.json").read_text())), \
             patch.object(keydock, "verify_dmg"):
            install_text = keydock.ROOT / "release/INSTALL.txt"; install_text.parent.mkdir(); install_text.write_text("synthetic")
            with self.assertRaisesRegex(PipelineError, "stage failure"): keydock.package(source, "synthetic")
            work = run_dir / "package"
            creator = work / "creator/generated.dmg"
            original = delivery.file_record(creator) if creator.exists() else None
            registry = keydock.ROOT / ".local/release-delivery/candidates" / (CONFIG["version"] + ".json")
            registry.unlink()
            with self.assertRaisesRegex(PipelineError, "unindexed candidate"): keydock.package(profile="synthetic")
            keydock.package(profile="synthetic", resume_work=work)
            if original and fault != "dmg": self.assertEqual(delivery.file_record(creator), original)
        self.assertEqual(stages.count("dmg"), 2 if fault == "dmg" else 1)
        self.assertEqual(stages.count("sign-dmg"), 2 if fault == "sign-dmg" else 1)
        self.assertEqual(len(submissions), 2)  # App与DMG各一次。
        retained = [p for p in (run_dir / "package").glob("incomplete-*") if p.is_dir() or p.suffix == ".dmg"]
        self.assertEqual(len(retained), 1)
        self.assertEqual((source / "resource").read_bytes(), b"original")

    def test_timed_and_untimed_stage_cancellation_reaps_before_return(self):
        popen = subprocess.Popen
        for timeout in (None, 10):
            with self.subTest(timeout=timeout):
                children = []
                def owned(*args, **kwargs):
                    child = popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
                    children.append(child); os.kill(os.getpid(), signal.SIGTERM)
                    return child
                with patch.object(keydock, "RUN_DIR", self.root / str(timeout)), patch.object(keydock, "ROOT", self.root), \
                     patch.object(keydock.subprocess, "Popen", side_effect=owned):
                    with self.assertRaises(PipelineError): keydock.stage("owned-stage", [sys.executable], timeout=timeout)
                self.assertIsNotNone(children[0].poll())
                state = delivery.read_receipt(self.root / str(timeout) / "owned-stage.json")
                self.assertEqual(state["exitCode"], 128 + signal.SIGTERM)

    def test_directory_durability_failure_prevents_submit(self):
        other = self.root / "new/nested/request.json"
        with patch.object(delivery.os, "fsync", side_effect=OSError("synthetic directory fsync")), \
             patch.object(delivery, "invoke_notary") as network:
            with self.assertRaises(OSError): delivery.notarize(self.payload, "synthetic", other, BINDING)
            network.assert_not_called()

    def test_final_rename_syncs_both_parents_and_never_clobbers(self):
        source = self.root / "one/assets"; source.mkdir(parents=True)
        (source / "owned").write_bytes(b"synthetic")
        destination = self.root / "two/release"
        fsync = delivery.os.fsync
        with patch.object(delivery.os, "fsync", wraps=fsync) as barrier:
            delivery.durable_rename(source, destination)
            self.assertGreaterEqual(barrier.call_count, 2)
        self.assertFalse(source.exists()); self.assertEqual((destination / "owned").read_bytes(), b"synthetic")
        with self.assertRaises(PipelineError): delivery.durable_rename(destination, destination)


if __name__ == "__main__": unittest.main()
