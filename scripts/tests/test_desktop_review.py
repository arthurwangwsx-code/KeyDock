"""本地Review流水线用合成文件和进程端口验证；不调用系统App或权限。"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import desktop_review as review
import keydock
from keydock_common import PipelineError, inspect_app


class DesktopReviewPipelineTests(unittest.TestCase):
    @contextlib.contextmanager
    def environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            parent = base / "review"; parent.mkdir(mode=0o700)
            sessions = parent / "sessions"; sessions.mkdir(mode=0o700)
            pair = base / "pair"; pair.mkdir(mode=0o700)
            fixture = {"path": str(pair / "Fixture.app"), "bundleID": review.FIXTURE_ID, "executablePath": str(pair / "Fixture.app/Contents/MacOS/Fixture")}
            app = {"path": str(pair / "Review.app"), "bundleID": review.REVIEW_ID, "executablePath": str(pair / "Review.app/Contents/MacOS/Review")}
            manifest = {"source": {"commit": "a" * 40, "dirty": False}, "fixture": fixture, "review": app}
            with patch.object(review, "PARENT", parent), patch.object(review, "PAIR", pair), patch.object(review, "inspect_pair", return_value=manifest):
                yield base, sessions, manifest

    def identity(self, role, pid):
        return dict(role, pid=pid, birth=1234.5)

    def test_private_marker_rejects_symlink_hardlink_and_public_modes(self):
        with self.environment() as (base, _, _):
            path = base / "marker.json"; path.write_text('{}'); path.chmod(0o600)
            self.assertEqual(review.read_private(path), {})
            link = base / "link"; link.symlink_to(path)
            with self.assertRaises(OSError): review.read_private(link)
            hard = base / "hard"; os.link(path, hard)
            with self.assertRaises(PipelineError): review.read_private(path)
            hard.unlink(); path.chmod(0o644)
            with self.assertRaises(PipelineError): review.read_private(path)

    def test_build_symlink_ancestor_refuses_before_compiler_or_deletion(self):
        with self.environment() as (base, _, manifest):
            outside = base / "outside"; outside.mkdir(); sentinel = outside / "sentinel"; sentinel.write_text("preserve")
            link = base / "link"; link.symlink_to(outside, target_is_directory=True)
            with patch.object(review, "PAIR", link / "pair"), patch.object(review, "source_identity", return_value=manifest["source"]), patch.object(review, "HELPER", base / "tools/helper"):
                with self.assertRaises(PipelineError): review.build_pair(lambda *args: self.fail("Compiler was called"))
            self.assertEqual(sentinel.read_text(), "preserve")
            self.assertFalse((outside / "pair").exists())

    def test_active_pair_does_not_replace_old_helper(self):
        with self.environment() as (base, _, manifest):
            helper = base / "tools/helper"; helper.parent.mkdir(); helper.write_text("old helper")
            def stage(name, args): Path(args[-1]).write_text("candidate helper")
            with patch.object(review, "HELPER", helper), patch.object(review, "source_identity", return_value=manifest["source"]), patch.object(review, "run", return_value='[{"pid":42}]'):
                with self.assertRaises(PipelineError): review.build_pair(stage)
            self.assertEqual(helper.read_text(), "old helper")

    def test_symlink_cache_refuses_before_native_build(self):
        with self.environment() as (base, _, manifest):
            repo = base / "repo"; output = repo / "build/pipeline/desktop-review"; output.mkdir(parents=True)
            outside = base / "external-cache"; outside.mkdir(); sentinel = outside / "sentinel"; sentinel.write_text("preserve")
            (output / "DerivedData").symlink_to(outside, target_is_directory=True)
            helper = base / "tools/helper"; stages = []
            def stage(name, args):
                stages.append(name)
                if name == "review-lifecycle": Path(args[-1]).write_text("candidate")
            with patch.object(review, "ROOT", repo), patch.object(review, "HELPER", helper), patch.object(review, "source_identity", return_value=manifest["source"]), patch.object(review, "run", return_value="[]"):
                with self.assertRaises(PipelineError): review.build_pair(stage)
            self.assertNotIn("review-build", stages); self.assertEqual(sentinel.read_text(), "preserve")

    def test_marker_failure_records_identity_then_normally_compensates(self):
        with self.environment() as (_, sessions, manifest):
            identity = self.identity(manifest["fixture"], 42); stops = []
            def lifecycle(role, operation="probe", expected=None):
                if operation == "quit": stops.append((role["bundleID"], expected)); return []
                return [identity] if role == manifest["fixture"] and identities[0] else []
            identities = [False]
            def started(role): identities[0] = True; return identity
            writer = review.durable_json
            def write(path, value):
                if Path(path).name == "review-session.json": raise OSError("synthetic marker write failure")
                writer(path, value)
            with patch.object(review, "run"), patch.object(review, "lifecycle", side_effect=lifecycle), patch.object(review, "wait_started", side_effect=started), patch.object(review, "durable_json", side_effect=write):
                with self.assertRaises(OSError): review.launch(review.PAIR)
            receipt = next(sessions.glob("*/launch-*.json")); record = review.read_private(receipt)
            self.assertEqual(record["fixture"], identity); self.assertEqual(record["state"], "partial-start")
            self.assertEqual(stops, [(review.FIXTURE_ID, identity)])
            self.assertEqual(record["compensation"], {"fixture": "normally-stopped"})

    def test_stop_review_refusal_never_quits_companion_or_marks_stopped(self):
        with self.environment() as (_, sessions, manifest):
            root = sessions / ("KeyDock-DesktopReview-" + str(review.uuid.uuid4())); root.mkdir(mode=0o700)
            receipt = root / ("launch-" + str(review.uuid.uuid4()) + ".json")
            record = {"root": str(root), "pair": str(review.PAIR), "source": manifest["source"], "syntheticOnly": True, "state": "processes-started", "review": self.identity(manifest["review"], 41), "fixture": self.identity(manifest["fixture"], 42)}
            review.durable_json(receipt, record); stops = []
            def lifecycle(role, operation="probe", expected=None):
                if operation == "quit": stops.append(role["bundleID"]); raise PipelineError("synthetic normal quit refusal")
                return [record["review" if role["bundleID"] == review.REVIEW_ID else "fixture"]]
            with patch.object(review, "lifecycle", side_effect=lifecycle):
                with self.assertRaises(PipelineError): review.status(receipt, stop=True)
            self.assertEqual(stops, [review.REVIEW_ID]); self.assertEqual(review.read_private(receipt)["state"], "processes-started")

    def test_reuse_busy_owner_never_opens_or_changes_marker(self):
        with self.environment() as (_, sessions, manifest):
            root = sessions / ("KeyDock-DesktopReview-" + str(review.uuid.uuid4())); root.mkdir(mode=0o700)
            identity = self.identity(manifest["fixture"], 42)
            marker = {"schemaVersion": 1, "rootID": root.name.removeprefix("KeyDock-DesktopReview-"), "reviewBundleIdentifier": review.REVIEW_ID, "fixturePID": 42, "fixtureLaunchTime": identity["birth"]}
            review.durable_json(root / "review-session.json", marker); before = (root / "review-session.json").read_bytes()
            fd = os.open(root / "review-owner.lock", os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(review, "lifecycle", side_effect=lambda role: [] if role["bundleID"] == review.REVIEW_ID else [identity]), patch.object(review, "run") as run:
                    with self.assertRaises(BlockingIOError): review.launch(review.PAIR, root)
                    run.assert_not_called()
            finally: os.close(fd)
            self.assertEqual((root / "review-session.json").read_bytes(), before)

    def test_review_profiles_are_rejected_before_ordinary_pipeline_effects(self):
        for bid in (review.REVIEW_ID, review.FIXTURE_ID):
            with self.subTest(bid=bid), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "Review.app"; (app / "Contents").mkdir(parents=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bid}))
                with patch.object(keydock, "helper") as helper, patch.object(keydock.delivery, "exclusive") as lock:
                    with self.assertRaises(PipelineError): keydock.install(app)
                    with self.assertRaises(PipelineError): keydock.package(app)
                    with self.assertRaises(PipelineError): inspect_app(app)
                    helper.assert_not_called(); lock.assert_not_called()
        with patch.object(keydock, "stage") as stage:
            with self.assertRaises(PipelineError): keydock.build("desktop-review")
            stage.assert_not_called()

    def test_owned_python_term_and_hup_leave_receipt_and_exact_compensation(self):
        code = '''
import json, os, signal, sys
from unittest.mock import patch
from test_desktop_review import DesktopReviewPipelineTests
import desktop_review as r
from keydock_common import PipelineError
case = DesktopReviewPipelineTests()
with case.environment() as (_, sessions, manifest):
    identity = case.identity(manifest['fixture'], 42)
    confirmed = [False]; stops = []
    def lifecycle(role, operation='probe', expected=None):
        if operation == 'quit': stops.append(expected); confirmed[0] = False; return []
        return [identity] if role['bundleID'] == r.FIXTURE_ID and confirmed[0] else []
    def run(args): os.kill(os.getpid(), int(sys.argv[1]))
    def started(role): confirmed[0] = True; return identity
    with patch.object(r, 'run', side_effect=run), patch.object(r, 'lifecycle', side_effect=lifecycle), patch.object(r, 'wait_started', side_effect=started):
        try: r.launch(r.PAIR)
        except PipelineError: pass
        else: raise AssertionError('Cancellation was ignored')
    receipt = next(sessions.glob('*/launch-*.json')); record = r.read_private(receipt)
    assert record['state'] == 'partial-start' and record['signal'] == int(sys.argv[1])
    assert stops == [identity] and record['compensation'] == {'fixture':'normally-stopped'}
    print('SIGNAL_COMPENSATION_PASS')
'''
        environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent) + os.pathsep + str(Path(__file__).parents[1]))
        for sig in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                result = subprocess.run([sys.executable, "-c", code, str(int(sig))], env=environment, text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("SIGNAL_COMPENSATION_PASS", result.stdout)
