"""只验证工程薄入口，不修改共享策略、启动真实构建或清理其他工程。"""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_storage_gate
import keydock
from keydock_common import PipelineError


class BuildStorageGateTests(unittest.TestCase):
    def test_unknown_root_keeps_exact_arguments_and_uses_source_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "synthetic root"
            tool = Path(temporary) / "governor.py"; tool.write_text("# synthetic tool, never executed\n")
            result = build_storage_gate.entry(["release", "--publish", "--install"], root, tool=tool, cwd=Path(temporary))
            self.assertEqual(result[result.index("--source-root") + 1], str(root))
            self.assertNotIn("--project", result)
            self.assertEqual(result[result.index("--expected-gib") + 1], "12")
            self.assertEqual(result[-3:], ["release", "--publish", "--install"])
            self.assertIn("from keydock import run_cli", result[-4])
            self.assertNotIn("cli_entry", result[-4])

    def test_inherited_marker_does_not_bypass_shared_validation(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict("os.environ", {"PERSONAL_BUILD_STORAGE_RUN": "synthetic-unverified"}):
            tool = Path(temporary) / "governor.py"; tool.write_text("# synthetic\n")
            result = build_storage_gate.entry(["check"], Path(temporary), tool=tool)
            self.assertEqual(result[1:3], [str(tool), "run"])
            self.assertEqual(result[result.index("--expected-gib") + 1], "4")

    def test_explicit_missing_governor_fails_without_unwrapped_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(RuntimeError, "no pipeline was started"):
                build_storage_gate.entry(["build"], Path(temporary), tool=Path(temporary) / "missing.py")

    def test_payload_preserves_failure_and_success_exit_status(self):
        with patch.object(keydock, "main", return_value=None): self.assertEqual(keydock.run_cli(), 0)
        with patch.object(keydock, "main", side_effect=PipelineError("synthetic refusal")), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(keydock.run_cli(), 1)
