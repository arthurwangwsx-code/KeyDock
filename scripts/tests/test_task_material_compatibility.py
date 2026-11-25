"""仅owned合成v1材料；安装扫描不得读取payload。"""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import task_material_compatibility as compatibility
from invocation_compatibility import runtime_data_lease
from keydock_common import PipelineError


class MaterialCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="keydock-material-compatibility-")
        self.root = Path(self.temporary.name).resolve() / "SyntheticData"
        self.folder = self.root / compatibility.DIRECTORY
        fixture = Path(__file__).resolve().parents[2] / "Tools/Fixtures/task-material-v1.json"
        self.golden = json.loads(fixture.read_text())

    def tearDown(self): self.temporary.cleanup()

    def write(self, name, data):
        self.folder.mkdir(parents=True, mode=0o700, exist_ok=True)
        path = self.folder / name; path.write_bytes(data); path.chmod(0o600)
        return path

    def body(self): return self.write(self.golden["fileName"], base64.b64decode(self.golden["frameBase64"]))
    def control(self, field): return self.write(compatibility.CONTROL, base64.b64decode(self.golden[field]))

    def test_absent_and_idle_only_states_create_nothing_and_need_no_reader(self):
        before = set(Path(self.temporary.name).rglob("*"))
        self.assertEqual(compatibility.probe_task_materials(self.root)["requiredVersions"], [])
        self.assertEqual(set(Path(self.temporary.name).rglob("*")), before)
        control = self.control("controlIdleBase64"); self.write(compatibility.LOCK, b"")
        original = control.read_bytes()
        with runtime_data_lease(self.root) as guard:
            self.assertEqual(compatibility.probe_task_materials(self.root, guard),
                {"requiredVersions": [], "materialCount": 0, "temporaryCount": 0, "pending": False})
        self.assertEqual(control.read_bytes(), original)

    def test_formal_body_reads_only_prefix_and_header_and_requires_v1(self):
        path = self.body(); original = path.read_bytes()
        reads = 0; original_read = compatibility.os.read
        def read(descriptor, count):
            nonlocal reads
            result = original_read(descriptor, count); reads += len(result); return result
        with patch.object(compatibility.os, "read", side_effect=read):
            result = compatibility.probe_task_materials(self.root)
        self.assertEqual(result, {"requiredVersions": [1], "materialCount": 1, "temporaryCount": 0, "pending": False})
        self.assertEqual(reads, 12 + int.from_bytes(original[8:12], "big"))
        self.assertLess(reads, len(original)); self.assertEqual(path.read_bytes(), original)

    def test_pending_controls_and_known_plaintext_temporaries_require_reader_without_reading_them(self):
        for field in ("controlPendingWriteBase64", "controlDeletionBase64"):
            self.control(field)
            result = compatibility.probe_task_materials(self.root)
            self.assertEqual(result["requiredVersions"], [1]); self.assertTrue(result["pending"])
        self.control("controlIdleBase64")
        key = self.golden["fileName"].removesuffix(".kdmaterial")
        for name in (".material-v1-" + key + "-00000000-0000-0000-0000-000000000099.tmp",
                     ".control-v1-00000000-0000-0000-0000-000000000099.tmp"):
            path = self.write(name, b"synthetic interrupted plaintext")
            result = compatibility.probe_task_materials(self.root)
            self.assertEqual(result["requiredVersions"], [1]); self.assertEqual(result["temporaryCount"], 1)
            self.assertTrue(result["pending"]); path.unlink()
        self.assertEqual(compatibility.probe_task_materials(self.root)["requiredVersions"], [])

    def test_unknown_corrupt_and_unsafe_entries_are_preserved_and_refused(self):
        path = self.body(); original = path.read_bytes()
        path.write_bytes(b"FUTURE01" + original[8:])
        with self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        path.unlink()
        foreign = self.write("unknown.txt", b"unchanged")
        with self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        self.assertEqual(foreign.read_bytes(), b"unchanged"); foreign.unlink()
        path = self.body(); other = self.folder / "second-link"; os.link(path, other)
        with self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        other.unlink(); path.unlink(); os.mkfifo(path, 0o600)
        with self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        path.unlink(); target = self.write("foreign.txt", b"foreign"); path.symlink_to(target)
        with self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        self.assertEqual(target.read_bytes(), b"foreign")

    def test_directory_missing_marker_and_file_rebind_are_rechecked(self):
        for mode in ("directory", "file", "missing"):
            with self.subTest(mode=mode):
                if mode != "missing": self.body()
                else:
                    self.root.mkdir(mode=0o700, exist_ok=True)
                original_inspect = compatibility._inspect
                changed = False
                def inspect(parent, name, budget):
                    nonlocal changed
                    value = original_inspect(parent, name, budget)
                    if not changed:
                        changed = True
                        if mode == "directory": self.folder.rename(self.root / "retained"); self.folder.mkdir(mode=0o700)
                        elif mode == "file":
                            path = self.folder / name; data = path.read_bytes(); path.rename(self.root / "retained-file"); self.write(name, data)
                    return value
                if mode == "missing":
                    original_entry = compatibility._entry_identity; calls = 0
                    def entry(parent, name):
                        nonlocal calls
                        result = original_entry(parent, name); calls += 1
                        if calls == 1: self.body()
                        return result
                    with patch.object(compatibility, "_entry_identity", side_effect=entry), self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
                else:
                    with patch.object(compatibility, "_inspect", side_effect=inspect), self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
                # 每种故障只清理该测试拥有的随机根，下一种不复用异常路径。
                import shutil
                shutil.rmtree(self.root)

    def test_enumeration_and_read_budget_are_bounded(self):
        self.body()
        with patch.object(compatibility, "MAX_ENTRIES", 0), self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)
        with patch.object(compatibility, "MAX_METADATA_BYTES", 12), self.assertRaises(PipelineError): compatibility.probe_task_materials(self.root)

    def test_directory_iterator_stops_at_limit_plus_one_and_is_closed(self):
        import contextlib
        from types import SimpleNamespace
        self.folder.mkdir(parents=True, mode=0o700)
        iterations = 0; closed = False
        @contextlib.contextmanager
        def scan(_):
            nonlocal closed
            def entries():
                nonlocal iterations
                for count in range(1000):
                    iterations += 1
                    if iterations > 4: self.fail("Enumeration continued after limit + 1")
                    yield SimpleNamespace(name=str(count))
            try: yield entries()
            finally: closed = True
        descriptor = os.open(self.folder, compatibility.DIRECTORY_FLAGS)
        try:
            with patch.object(compatibility, "MAX_ENTRIES", 3), patch.object(compatibility.os, "scandir", side_effect=scan), self.assertRaises(PipelineError):
                compatibility._names(descriptor)
        finally: os.close(descriptor)
        self.assertEqual(iterations, 4); self.assertTrue(closed)
