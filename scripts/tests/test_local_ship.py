"""本机一键发布的顺序、重试与拒绝边界；不联网、不真实创建tag。"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock
import release_quality as quality
import build_storage_gate
from keydock_common import CONFIG, PipelineError

SOURCE = {"commit": "a" * 40, "dirty": False}
TAG = "v" + CONFIG["version"]
REF = "refs/tags/" + TAG


class LocalShipTests(unittest.TestCase):
    def test_preflight_requires_exact_remote_master_and_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "docs/releases" / (TAG + ".md")
            notes.parent.mkdir(parents=True); notes.write_text("synthetic")
            for branch, master, local, remote, origin, success in [
                ("master", "a", None, None, CONFIG["repository"], True),
                ("master", "a", "a", "a", CONFIG["repository"], True),
                ("feature/test", "a", None, None, CONFIG["repository"], False),
                ("master", "b", None, None, CONFIG["repository"], False),
                ("master", "a", "b", None, CONFIG["repository"], False),
                ("master", "a", None, "b", CONFIG["repository"], False),
                ("master", "a", None, None, "other/repo", False),
            ]:
                def command(args, **kwargs):
                    if args[1] == "branch": return branch
                    if args[1] == "remote": return "https://github.com/" + origin + ".git"
                    if args[1] == "ls-remote":
                        return master * 40 + "\trefs/heads/master\n" + (remote * 40 + "\t" + REF + "\n" if remote else "")
                    self.fail("Unexpected command: " + str(args))
                with self.subTest(branch=branch, master=master, local=local, remote=remote, origin=origin), patch.object(keydock, "ROOT", root), patch.object(keydock, "source_identity", return_value=SOURCE), patch.object(keydock, "run", side_effect=command), patch.object(keydock.subprocess, "run", return_value=subprocess.CompletedProcess([], 0 if local else 1, stdout=local * 40 if local else "")):
                    if success: self.assertEqual(keydock.ship_preflight()[:2], (SOURCE, TAG))
                    else:
                        with self.assertRaises(PipelineError): keydock.ship_preflight()

    def test_plan_never_builds_tags_publishes_or_installs(self):
        with patch.object(keydock, "ship_preflight", return_value=(SOURCE, TAG, None, None)), patch.object(keydock, "prepare_local_release") as prepare, patch.object(keydock, "run") as run, patch.object(keydock, "publish") as publish, patch.object(keydock, "install_release") as install, patch.object(keydock, "atomic_json") as receipt:
            keydock.ship(plan=True)
            for action in (prepare, run, publish, install, receipt): action.assert_not_called()

    def test_local_qualification_and_candidate_are_reused(self):
        for state in ("new", "candidate", "dist"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); dist = root / "dist"
                qualification = root / "qualification.json"
                if state != "new": qualification.touch()
                if state == "candidate":
                    registry = root / ".local/release-delivery/candidates" / (CONFIG["version"] + ".json")
                    registry.parent.mkdir(parents=True); registry.touch()
                if state == "dist": dist.mkdir()
                with patch.object(keydock, "ROOT", root), patch.object(keydock, "DIST", dist), patch.object(quality, "receipt_path", return_value=qualification), patch.object(quality, "require_local"), patch.object(quality, "wait_for_core_ci"), patch.object(keydock, "source_identity", return_value=SOURCE), patch.object(keydock, "check") as check, patch.object(keydock, "build", return_value=Path("/synthetic/KeyDock.app")) as build, patch.object(keydock, "package") as package:
                    keydock.prepare_local_release(SOURCE, "synthetic-profile" if state != "dist" else None)
                    self.assertEqual(check.call_count, int(state == "new"))
                    self.assertEqual(build.call_count, int(state == "new"))
                    if state == "new": package.assert_called_once_with(Path("/synthetic/KeyDock.app"), profile="synthetic-profile")
                    else: package.assert_called_once_with(profile="synthetic-profile" if state == "candidate" else None)

    def test_bad_qualification_or_failed_ci_does_not_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); receipt = root / "qualification.json"; receipt.touch()
            for failing in ("require_local", "wait_for_core_ci"):
                with self.subTest(failing=failing), patch.object(keydock, "ROOT", root), patch.object(keydock, "DIST", root / "dist"), patch.object(quality, "receipt_path", return_value=receipt), patch.object(quality, "require_local"), patch.object(quality, "wait_for_core_ci"), patch.object(quality, failing, side_effect=PipelineError("failed")), patch.object(keydock, "build") as build, patch.object(keydock, "package") as package:
                    with self.assertRaises(PipelineError): keydock.prepare_local_release(SOURCE, "synthetic")
                    build.assert_not_called(); package.assert_not_called()

    def test_tag_is_pushed_only_after_package_and_install_is_explicit(self):
        for existing, install_after in ((False, False), (True, True)):
            order = []
            preflight = (SOURCE, TAG, SOURCE["commit"] if existing else None, SOURCE["commit"] if existing else None)
            with tempfile.TemporaryDirectory() as directory, patch.object(keydock, "RUN_DIR", Path(directory)), patch.object(keydock, "ship_preflight", return_value=preflight), patch.object(keydock, "prepare_local_release", side_effect=lambda *_: order.append("package")), patch.object(keydock, "run", side_effect=lambda args: order.append(args[1])), patch.object(keydock, "publish", side_effect=lambda: order.append("publish")), patch.object(keydock, "install_release", side_effect=lambda: order.append("install")):
                keydock.ship("synthetic", install_after=install_after)
                self.assertEqual(order, ["package"] + ([] if existing else ["tag", "push"]) + ["publish"] + (["install"] if install_after else []))
                self.assertEqual(json.loads((Path(directory) / "ship.json").read_text())["stage"], "installed" if install_after else "published-and-verified")

    def test_failed_package_or_source_drift_preserves_tags_and_draft(self):
        for failure in ("package", "drift"):
            initial = (SOURCE, TAG, None, None)
            drift = ({"commit": "b" * 40, "dirty": False}, TAG, None, None)
            with tempfile.TemporaryDirectory() as directory, patch.object(keydock, "RUN_DIR", Path(directory)), patch.object(keydock, "ship_preflight", side_effect=[initial, drift]), patch.object(keydock, "prepare_local_release", side_effect=PipelineError("failed") if failure == "package" else None), patch.object(keydock, "run") as run, patch.object(keydock, "publish") as publish:
                with self.assertRaises(PipelineError): keydock.ship("synthetic")
                run.assert_not_called(); publish.assert_not_called()

    def test_core_wait_does_not_accept_pending_or_failed_workflow(self):
        for status in ("in_progress", "completed"):
            payload = {"workflow_runs": [{"id": 42, "path": ".github/workflows/ci.yml", "head_sha": SOURCE["commit"], "event": "push", "status": status}]}
            with self.subTest(status=status), patch.object(quality, "run", return_value=json.dumps(payload)), patch.object(quality, "core_ci", side_effect=PipelineError("failed CI")) as verify:
                with self.assertRaises(PipelineError): quality.wait_for_core_ci(SOURCE, timeout=0)
                self.assertEqual(verify.call_count, int(status == "completed"))

    def test_ship_storage_budget_covers_whole_pipeline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); tool = root / "governor.py"; tool.touch()
            for args, budget in ((["ship"], "12"), (["ship", "--plan"], "0")):
                command = build_storage_gate.entry(args, root, tool=tool)
                self.assertEqual(command[command.index("--expected-gib") + 1], budget)

    def test_cloud_core_does_not_build_or_archive_application(self):
        workflow = (keydock.ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("keydock.py check --ci", workflow)
        self.assertNotIn("keydock.py build", workflow)
        self.assertNotIn("KeyDock-CI-preview", workflow)


if __name__ == "__main__": unittest.main()
