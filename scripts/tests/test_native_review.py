import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid

from keydock_common import PipelineError

spec = importlib.util.spec_from_file_location("native_review", Path(__file__).parents[1] / "native-review.py")
review = importlib.util.module_from_spec(spec); spec.loader.exec_module(review)


class NativeReviewTests(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="keydock-owned-review-test-")
        self.addCleanup(self.owner.cleanup)
        self.parent = Path(self.owner.name).resolve()
        self.root = self.parent / ("KeyDock-Review-" + str(uuid.uuid4()))
        self.root.mkdir(mode=0o700)
        self.marker = self.root / "synthetic-review.json"
        self.marker.write_text(json.dumps({"fixture": "keydock-native-review-v1"})); self.marker.chmod(0o600)

    def test_owned_restart_marker_and_private_log(self):
        review.validate_fixture(self.root, self.parent)
        with review.open_private_log(self.root) as output: output.write(b"synthetic")
        self.assertEqual((self.root / "process.log").read_bytes(), b"synthetic")

    def test_wrong_name_mode_marker_and_outside_are_refused_before_writes(self):
        self.root.chmod(0o755)
        with self.assertRaises(PipelineError): review.validate_fixture(self.root, self.parent)
        self.root.chmod(0o700); self.marker.write_text('{}')
        with self.assertRaises(PipelineError): review.validate_fixture(self.root, self.parent)
        self.assertFalse((self.root / "process.log").exists())
        (self.parent / "another").mkdir()
        with self.assertRaises(PipelineError): review.validate_fixture(self.root, self.parent / "another")

    def test_symlink_and_hardlinked_log_do_not_touch_target(self):
        target = self.parent / "synthetic-protected"; target.write_bytes(b"preserve")
        log = self.root / "process.log"; log.symlink_to(target)
        with self.assertRaises(OSError): review.open_private_log(self.root)
        log.unlink(); os.link(target, log)
        with self.assertRaises(PipelineError): review.open_private_log(self.root)
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_marker_symlink_and_fifo_are_refused(self):
        self.marker.unlink(); self.marker.symlink_to(self.parent / "missing")
        with self.assertRaises(OSError): review.validate_fixture(self.root, self.parent)
        self.marker.unlink(); os.mkfifo(self.marker, 0o600)
        with self.assertRaises(PipelineError): review.validate_fixture(self.root, self.parent)
