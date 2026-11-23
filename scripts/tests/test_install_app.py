"""仅在owned临时目录演练真实macOS原子交换；签名与进程来源均为合成替身。"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from keydock_common import CONFIG, PipelineError, tree_digest

spec = importlib.util.spec_from_file_location("keydock_installer", SCRIPTS / "install-app.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


@unittest.skipUnless(sys.platform == "darwin", "renamex_np qualification runs on macOS")
class InstallAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="keydock-install-test-")
        self.directory = Path(self.temporary.name).resolve()
        self.apps = self.directory / "Applications"; self.apps.mkdir()
        self.destination = self.apps / "KeyDock Preview.app"
        self.helper = self.directory / "synthetic-helper"; self.helper.write_text("never executed"); self.helper.chmod(0o700)
        self.calls = []
        self.processes = []
        self.fail_copy = False
        self.fail_quit = False
        self.patches = [patch.object(installer, "inspect_app", side_effect=self.inspect), patch.object(installer, "run", side_effect=self.fake_run)]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temporary.cleanup()

    def app(self, name, payload):
        app = self.directory / (name + ".app"); app.mkdir()
        (app / "payload").write_text(payload)
        return app

    def inspect(self, app):
        return {"bundle_id": "com.arthurwangwsx.KeyDock.preview", "version": "0.1.0", "release_version": "0.1.0-alpha.1", "build_number": "1",
                "profile": "preview", "commit": "a" * 40, "safe_smoke": True, "source_dirty": True,
                "bundle_sha256": tree_digest(app), "code_signature": {"kind": "adhoc", "team_id": None, "hardened_runtime": True}, "notarized": False}

    def fake_run(self, args, capture=False):
        args = [str(item) for item in args]; self.calls.append(args)
        if args[0] == "/usr/bin/ditto":
            if self.fail_copy: raise PipelineError("synthetic copy failure")
            shutil.copytree(args[1], args[2], dirs_exist_ok=True)
        elif args[0] == "/usr/bin/codesign": pass
        elif args[0] == str(self.helper):
            if args[1] == "quit":
                if self.fail_quit: raise PipelineError("synthetic quit rejection")
                self.processes = []
            return json.dumps({"bundle_id": "com.arthurwangwsx.KeyDock.preview", "processes": self.processes})
        else: raise AssertionError("Unexpected process execution: " + args[0])

    def arguments(self, source, name="install", **overrides):
        values = dict(app=str(source), destination=str(self.destination), receipt=str(self.directory / (name + ".json")), helper=str(self.helper),
                      quit_running=False, dry_run=False, allow_unnotarized_preview=True)
        values.update(overrides)
        return SimpleNamespace(**values)

    def installed_pair(self):
        old, new = self.app("old", "synthetic old"), self.app("new", "synthetic new")
        installer.install(self.arguments(old, "first"))
        args = self.arguments(new, "second")
        record = installer.install(args)
        return old, new, args, record

    def test_dry_run_does_not_create_target_backup_lock_or_receipt(self):
        app = self.app("source", "synthetic")
        before = set(self.directory.rglob("*"))
        record = installer.install(self.arguments(app, dry_run=True))
        self.assertEqual(record["state"], "dry-run")
        self.assertEqual(set(self.directory.rglob("*")), before)

    def test_first_install_keeps_source_and_reports_no_previous_version(self):
        app = self.app("source", "synthetic")
        record = installer.install(self.arguments(app))
        self.assertEqual(record["state"], "installed")
        self.assertFalse(record["rollback_available"])
        self.assertEqual(tree_digest(app), tree_digest(self.destination))
        self.assertFalse(Path(record["exchange_path"]).exists())

    def test_real_ditto_copy_restores_source_root_permissions_before_verification(self):
        app = self.app("source", "synthetic"); app.chmod(0o755)
        def copy(args, capture=False):
            if str(args[0]) == "/usr/bin/ditto":
                subprocess.run([str(value) for value in args], check=True)
                return None
            return self.fake_run(args, capture)
        with patch.object(installer, "run", side_effect=copy): installer.install(self.arguments(app))
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o755)
        self.assertEqual(tree_digest(app), tree_digest(self.destination))

    def test_replace_rollback_and_repeat_preserve_both_versions(self):
        old, new, args, record = self.installed_pair()
        backup = Path(record["backup_path"])
        self.assertEqual(tree_digest(self.destination), tree_digest(new))
        self.assertEqual(tree_digest(backup), tree_digest(old))
        options = SimpleNamespace(rollback=args.receipt, helper=str(self.helper), quit_running=False, dry_run=False)
        rolled_back = installer.rollback(options)
        self.assertEqual(rolled_back["state"], "rolled-back")
        self.assertEqual(tree_digest(self.destination), tree_digest(old))
        self.assertEqual(tree_digest(backup), tree_digest(new))
        self.assertTrue(installer.rollback(options)["already_rolled_back"])

    def test_copy_failure_preserves_existing_app(self):
        old = self.app("old", "synthetic old"); installer.install(self.arguments(old, "first"))
        new = self.app("new", "synthetic new"); self.fail_copy = True
        args = self.arguments(new, "failed-copy")
        with self.assertRaises(PipelineError): installer.install(args)
        self.assertEqual(tree_digest(self.destination), tree_digest(old))
        self.assertEqual(json.loads(Path(args.receipt).read_text())["state"], "failed-before-exchange")

    def test_failure_after_atomic_exchange_compensates_without_deleting_either_app(self):
        old = self.app("old", "synthetic old"); installer.install(self.arguments(old, "first"))
        new = self.app("new", "synthetic new"); args = self.arguments(new, "failed-after-swap")
        original_verify = installer.verify_copy
        failed = False
        def verify(path, expected):
            nonlocal failed
            if Path(path) == self.destination and not failed:
                failed = True
                raise PipelineError("synthetic transient post-swap verification failure")
            return original_verify(path, expected)
        with patch.object(installer, "verify_copy", side_effect=verify):
            with self.assertRaises(PipelineError): installer.install(args)
        record = json.loads(Path(args.receipt).read_text())
        self.assertEqual(record["state"], "compensated")
        self.assertEqual(tree_digest(self.destination), tree_digest(old))
        self.assertEqual(tree_digest(Path(record["exchange_path"])), tree_digest(new))

    def test_unknown_process_path_is_rejected_before_copy_or_quit(self):
        app = self.app("source", "synthetic")
        self.processes = [{"pid": 999999, "bundle_id": "com.arthurwangwsx.KeyDock.preview", "path": str(self.directory / "unknown.app"), "running": True}]
        with self.assertRaises(PipelineError): installer.install(self.arguments(app, quit_running=True))
        self.assertFalse(self.destination.exists())
        self.assertFalse(any(call[0] == "/usr/bin/ditto" or "quit" in call for call in self.calls))

    def test_quit_rejection_keeps_old_target_and_prepared_candidate(self):
        old = self.app("old", "synthetic old"); installer.install(self.arguments(old, "first"))
        new = self.app("new", "synthetic new"); args = self.arguments(new, "quit-failed", quit_running=True)
        self.processes = [{"pid": 999999, "bundle_id": "com.arthurwangwsx.KeyDock.preview", "path": str(self.destination), "running": True}]
        self.fail_quit = True
        with self.assertRaises(PipelineError): installer.install(args)
        self.assertEqual(tree_digest(self.destination), tree_digest(old))
        record = json.loads(Path(args.receipt).read_text())
        self.assertTrue(Path(record["exchange_path"]).is_dir())

    def test_rollback_rechecks_target_after_waiting_for_quit(self):
        old, _, args, record = self.installed_pair()
        backup = Path(record["backup_path"])
        def changed_while_waiting(*unused): (self.destination / "payload").write_text("synthetic later edit")
        options = SimpleNamespace(rollback=args.receipt, helper=str(self.helper), quit_running=True, dry_run=False)
        with patch.object(installer, "quiesce", side_effect=changed_while_waiting):
            with self.assertRaises(PipelineError): installer.rollback(options)
        self.assertEqual((self.destination / "payload").read_text(), "synthetic later edit")
        self.assertEqual(tree_digest(backup), tree_digest(old))

    def test_symlink_destination_parent_cannot_redirect_an_install(self):
        app = self.app("source", "synthetic")
        link = self.directory / "redirect"; link.symlink_to(self.apps, target_is_directory=True)
        with self.assertRaises(PipelineError): installer.install(self.arguments(app, destination=str(link / "KeyDock Preview.app")))
        self.assertFalse(self.destination.exists())

    def test_receipt_helper_field_cannot_execute_an_arbitrary_program(self):
        _, _, args, _ = self.installed_pair()
        path = Path(args.receipt); record = json.loads(path.read_text()); record["helper"] = "/synthetic/untrusted-executable"
        path.write_text(json.dumps(record))
        options = SimpleNamespace(rollback=args.receipt, helper=str(self.helper), quit_running=False, dry_run=False)
        installer.rollback(options)
        self.assertFalse(any(call[0] == record["helper"] for call in self.calls))

    def test_other_signing_team_cannot_install_as_the_canonical_app(self):
        app = self.app("source", "synthetic")
        facts = self.inspect(app)
        facts.update(profile="release", bundle_id=CONFIG["bundleIdentifier"], safe_smoke=False, source_dirty=False, notarized=True,
                     code_signature={"kind": "developer-id", "team_id": "synthetic-other-team", "hardened_runtime": True})
        with patch.object(installer, "inspect_app", return_value=facts):
            with self.assertRaises(PipelineError): installer.install(self.arguments(app))
        self.assertFalse(self.destination.exists())

    def test_existing_other_team_app_is_preserved_even_when_source_is_ours(self):
        app = self.app("source", "synthetic source"); self.destination.mkdir(); (self.destination / "payload").write_text("synthetic existing")
        def facts(path):
            info = self.inspect(path)
            info.update(profile="release", bundle_id=CONFIG["bundleIdentifier"], safe_smoke=False, source_dirty=False, notarized=True,
                        code_signature={"kind": "developer-id", "team_id": "synthetic-other-team" if Path(path) == self.destination else CONFIG["teamID"], "hardened_runtime": True})
            return info
        with patch.object(installer, "inspect_app", side_effect=facts):
            with self.assertRaises(PipelineError): installer.install(self.arguments(app))
        self.assertEqual((self.destination / "payload").read_text(), "synthetic existing")

    def test_preview_exception_cannot_downgrade_canonical_alpha_trust(self):
        app = self.app("source", "synthetic")
        facts = self.inspect(app)
        facts.update(profile="release", bundle_id=CONFIG["bundleIdentifier"], safe_smoke=False, source_dirty=False, notarized=False,
                     code_signature={"kind": "developer-id", "team_id": CONFIG["teamID"], "hardened_runtime": False})
        with patch.object(installer, "inspect_app", return_value=facts):
            with self.assertRaises(PipelineError): installer.install(self.arguments(app))
        self.assertFalse(self.destination.exists())

    def test_parent_creation_happens_after_receipt_outside_app_validation(self):
        app = self.app("source", "synthetic")
        target = self.directory / "new-parent/KeyDock Preview.app"
        args = self.arguments(app, destination=str(target), receipt=str(app / "new-parent/receipt.json"), create_parents=True)
        before = tree_digest(app)
        with self.assertRaises(PipelineError): installer.install(args)
        self.assertEqual(tree_digest(app), before)
        self.assertFalse(target.parent.exists())

    def test_missing_parents_are_only_created_by_a_successful_non_dry_install(self):
        app = self.app("source", "synthetic")
        target = self.directory / "new-parent/KeyDock Preview.app"
        receipt = self.directory / "receipts/install.json"
        args = self.arguments(app, destination=str(target), receipt=str(receipt), create_parents=True, dry_run=True)
        installer.install(args)
        self.assertFalse(target.parent.exists()); self.assertFalse(receipt.parent.exists())
        args.dry_run = False
        installer.install(args)
        self.assertEqual(tree_digest(app), tree_digest(target))
        self.assertEqual(json.loads(receipt.read_text())["state"], "installed")

    def test_forged_receipt_cannot_assign_another_team_to_rollback(self):
        _, _, args, record = self.installed_pair()
        def other_team(path):
            info = self.inspect(path)
            info.update(profile="release", bundle_id=CONFIG["bundleIdentifier"], safe_smoke=False, source_dirty=False, notarized=True,
                        code_signature={"kind": "developer-id", "team_id": "synthetic-other-team", "hardened_runtime": True})
            return info
        record["installed"] = other_team(self.destination)
        record["previous"] = other_team(Path(record["backup_path"]))
        Path(args.receipt).write_text(json.dumps(record))
        options = SimpleNamespace(rollback=args.receipt, helper=str(self.helper), quit_running=False, dry_run=False)
        with patch.object(installer, "inspect_app", side_effect=other_team):
            with self.assertRaises(PipelineError): installer.rollback(options)
        self.assertEqual((self.destination / "payload").read_text(), "synthetic new")


if __name__ == "__main__": unittest.main()
