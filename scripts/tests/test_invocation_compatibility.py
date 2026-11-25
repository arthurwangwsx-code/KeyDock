"""全部使用owned合成数据；不读取正常KeyDock/Preview域。"""
import contextlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import invocation_compatibility as compatibility
from keydock_common import PipelineError, app_data_compatibility, current_data_compatibility, validate_data_compatibility, task_material_readers


class CapabilityTests(unittest.TestCase):
    def test_known_legacy_is_v1_but_unknown_and_present_invalid_declarations_fail(self):
        for version in ("0.1.0-alpha.1", "0.1.0-alpha.18"):
            self.assertEqual(app_data_compatibility({}, version)["invocationEnvelope"]["readVersions"], [1])
        for version in ("0.1.0-alpha.19", "0.1.0", "unknown"):
            with self.subTest(version=version), self.assertRaises(PipelineError): app_data_compatibility({}, version)
        for value in (None, {}, {"schemaVersion": True}, {"schemaVersion": 2}):
            with self.subTest(value=value), self.assertRaises(PipelineError): app_data_compatibility({"dataCompatibility": value}, "0.1.0-alpha.18")

    def test_lists_are_strict_and_writes_cannot_exceed_reads(self):
        for versions in ([], [True], [1.0], ["1"], [0], [-1], [65], [1, 1]):
            value = current_data_compatibility(); value["invocationEnvelope"]["readVersions"] = versions
            with self.subTest(versions=versions), self.assertRaises(PipelineError): validate_data_compatibility(value)
        value = current_data_compatibility(); value["invocationEnvelope"]["readVersions"] = [1]
        with self.assertRaises(PipelineError): validate_data_compatibility(value)
        value = current_data_compatibility(); value["invocationEnvelope"]["readVersions"] = [2, 1]
        self.assertEqual(validate_data_compatibility(value), current_data_compatibility())

    def test_schema_one_has_no_material_readers_and_schema_two_lists_are_strict(self):
        old = {"schemaVersion": 1, "invocationEnvelope": {"readVersions": [1, 2], "writeVersions": [1, 2]}}
        self.assertEqual(validate_data_compatibility(old), old)
        self.assertEqual(task_material_readers(old), [])
        self.assertEqual(task_material_readers(current_data_compatibility()), [1])
        for versions in ([True], [1.0], ["1"], [0], [65], [1, 1], []):
            value = current_data_compatibility(); value["taskMaterial"]["readVersions"] = versions
            with self.subTest(versions=versions), self.assertRaises(PipelineError): validate_data_compatibility(value)
        modern = current_data_compatibility(); modern["taskMaterial"] = {"readVersions": [], "writeVersions": []}
        self.assertEqual(task_material_readers(modern), [])
        for extra in ({"schemaVersion": 3}, {"unknown": 1}):
            value = dict(current_data_compatibility(), **extra)
            with self.assertRaises(PipelineError): validate_data_compatibility(value)


class InvocationDataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="keydock-data-gate-")
        self.root = Path(self.temporary.name).resolve() / "SyntheticData"

    def tearDown(self): self.temporary.cleanup()

    def file(self, name="invocations", version=1):
        folder = self.root / name; folder.mkdir(parents=True, mode=0o700, exist_ok=True)
        path = folder / "invocations.json"
        path.write_text(json.dumps({"version": version, "receipts": []}))
        return path

    def test_missing_probe_creates_nothing_and_each_domain_version_is_preserved(self):
        self.assertEqual(compatibility.probe_versions(self.root), dict.fromkeys(compatibility.FILES))
        self.assertFalse(self.root.exists())
        for name in compatibility.FILES:
            path = self.file(name, 2); original = path.read_bytes()
            self.assertEqual(compatibility.probe_versions(self.root)[name], 2)
            self.assertEqual(path.read_bytes(), original)

    def test_malformed_unknown_nonregular_and_oversized_entries_are_refused(self):
        path = self.file()
        for body in (b"broken", b'{"version":3,"receipts":[]}', b'{"version":true,"receipts":[]}',
                     b'{"version":1,"version":2,"receipts":[]}', b'{"version":1,"receipts":[{"runAttempt":{}}]}',
                     b'{"version":2,"receipts":[],"n":NaN}', b'{"version":2,"receipts":[],"n":1e999}'):
            path.write_bytes(body)
            with self.subTest(body=body), self.assertRaises(PipelineError): compatibility.probe_versions(self.root)
            self.assertEqual(path.read_bytes(), body)
        path.unlink(); os.mkfifo(path)
        with self.assertRaises(PipelineError): compatibility.probe_versions(self.root)
        path.unlink(); path.write_bytes(b"x" * 129)
        with patch.object(compatibility, "MAX_BYTES", 128), self.assertRaises(PipelineError): compatibility.probe_versions(self.root)

    def test_symlink_file_and_directory_are_never_followed(self):
        target = self.file("ai-invocations", 2)
        folder = self.root / "invocations"; folder.mkdir()
        (folder / "invocations.json").symlink_to(target)
        with self.assertRaises(PipelineError): compatibility.probe_versions(self.root)
        (folder / "invocations.json").unlink(); folder.rmdir(); folder.symlink_to(target.parent, target_is_directory=True)
        with self.assertRaises(PipelineError): compatibility.probe_versions(self.root)

    def test_subdirectory_rebind_and_missing_markers_are_rechecked(self):
        for mode in ("rebind", "missing-directory", "missing-file"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir=self.temporary.name) as scope:
                # OS tempfile在CI可能返回/var别名；只在owned夹具建立时解析，不放宽生产no-follow。
                root = Path(scope).resolve() / "SyntheticData"; root.mkdir(mode=0o700)
                second = root / "ai-invocations"; second.mkdir(mode=0o700)
                (second / "invocations.json").write_text('{"version":1,"receipts":[]}')
                first = root / "invocations"
                if mode != "missing-directory": first.mkdir(mode=0o700)
                if mode == "rebind": (first / "invocations.json").write_text('{"version":1,"receipts":[]}')
                original = compatibility._read_version; calls = 0
                def read(parent):
                    nonlocal calls
                    calls += 1
                    mutate = calls == (2 if mode != "missing-directory" else 1)
                    if mutate:
                        if mode == "rebind": first.rename(root / "prior-directory")
                        first.mkdir(mode=0o700, exist_ok=True)
                        (first / "invocations.json").write_text('{"version":2,"receipts":[]}')
                    return original(parent)
                with compatibility.runtime_data_lease(root) as guard:
                    with patch.object(compatibility, "_read_version", side_effect=read), self.assertRaises(PipelineError):
                        compatibility.probe_versions(root, guard)

    def test_cross_process_runtime_lease_prevents_replacement(self):
        self.root.mkdir(mode=0o700)
        script = "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.readline()"
        child = subprocess.Popen([sys.executable, "-c", script, str(self.root / "runtime-owner.lock")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
            self.assertEqual(child.stdout.readline().strip(), "locked")
            with self.assertRaises(PipelineError):
                with compatibility.runtime_data_lease(self.root): self.fail("Competing owner admitted")
        finally:
            child.communicate("done\n", timeout=5)
        with compatibility.runtime_data_lease(self.root) as guard:
            self.assertEqual(compatibility.probe_versions(self.root, guard), dict.fromkeys(compatibility.FILES))

    def test_preview_locator_does_not_inherit_build_tmpdir_and_rejects_shared_fallback(self):
        private = Path(self.temporary.name).resolve(); private.chmod(0o700)
        with patch.dict(os.environ, {"TMPDIR": "/synthetic-gate-scratch"}), patch.object(compatibility, "run", return_value=str(private) + "\n") as command:
            result = compatibility.runtime_data_root({"profile": "preview"})
            self.assertEqual(result, private / "KeyDock-Smoke")
            self.assertNotIn("TMPDIR", command.call_args.kwargs["env"])
            self.assertEqual(command.call_args.args[0], ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"])
        with patch.object(compatibility, "run", return_value="/tmp\n"), self.assertRaises(PipelineError):
            compatibility.runtime_data_root({"profile": "preview"})
