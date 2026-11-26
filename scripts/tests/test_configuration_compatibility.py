"""仅检查owned合成配置，含实际安装/回退测试使用的reader合同。"""
import os
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from keydock_common import PipelineError, current_data_compatibility, configuration_readers, validate_data_compatibility
import configuration_compatibility as compatibility
from invocation_compatibility import runtime_data_lease


class ConfigurationCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="keydock-config-reader-")
        self.root = Path(self.temporary.name).resolve() / "SyntheticData"

    def tearDown(self): self.temporary.cleanup()

    def write(self, data):
        self.root.mkdir(mode=0o700, exist_ok=True)
        path = self.root / "configuration.json"; path.write_bytes(data); path.chmod(0o600)
        return path

    def test_missing_and_legacy_probe_are_read_only(self):
        self.assertIsNone(compatibility.probe_configuration(self.root))
        self.assertFalse(self.root.exists())
        for data, version in ((b'{}', 1), (b'{"schemaVersion":1,"model":"synthetic"}', 1),
                              (b'{"schemaVersion":2,"aiModelSettings":{},"aiSettingsRevision":"00000000-0000-0000-0000-000000000001"}', 2)):
            path = self.write(data)
            with runtime_data_lease(self.root) as guard:
                self.assertEqual(compatibility.probe_configuration(self.root, guard), version)
            self.assertEqual(path.read_bytes(), data)

    def test_bad_versions_duplicates_special_numbers_and_new_fields_in_legacy_fail(self):
        for data in (b'', b'bad', b'[]', b'{"schemaVersion":3}', b'{"schemaVersion":true}',
                     b'{"schemaVersion":1,"schemaVersion":2}', b'{"schemaVersion":2,"n":NaN}',
                     b'{"schemaVersion":2,"n":1e999}', b'{"schemaVersion":1,"aiModelSettings":{}}', b'{"schemaVersion":2,"aiModelSettings":null,"aiSettingsRevision":null}'):
            path = self.write(data)
            with self.subTest(data=data), self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
            self.assertEqual(path.read_bytes(), data)

    def test_links_fifo_growth_budget_and_rebind_are_refused(self):
        path = self.write(b'{"schemaVersion":2}')
        linked = self.root / "retained"; os.link(path, linked)
        with self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        linked.unlink(); path.unlink(); os.mkfifo(path, 0o600)
        with self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        path.unlink(); target = self.write(b'{"schemaVersion":2}'); target.rename(linked); path.symlink_to(linked)
        with self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        path.unlink(); path = self.write(b'{"schemaVersion":2}')
        with patch.object(compatibility, "MAX_BYTES", 2), self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        read = compatibility.os.read; changed = False
        def rebind(fd, size):
            nonlocal changed
            data = read(fd, size)
            if not changed:
                changed = True; path.rename(self.root / "old"); self.write(b'{"schemaVersion":1}')
            return data
        with patch.object(compatibility.os, "read", side_effect=rebind), self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        self.assertEqual((self.root / "old").read_bytes(), b'{"schemaVersion":2}')

    def test_old_signed_capabilities_remain_unmodified_and_only_read_v1(self):
        for old in ({"schemaVersion":1,"invocationEnvelope":{"readVersions":[1],"writeVersions":[1]}},
                    {"schemaVersion":2,"invocationEnvelope":{"readVersions":[1,2],"writeVersions":[1,2]},"taskMaterial":{"readVersions":[1],"writeVersions":[1]}}):
            self.assertEqual(validate_data_compatibility(old), old)
            self.assertEqual(configuration_readers(old), [1])
        modern = current_data_compatibility()
        self.assertEqual(modern["schemaVersion"], 3)
        self.assertEqual(configuration_readers(modern), [1,2,3])
        self.assertEqual(modern["configuration"]["writeVersions"], [3])
        modern["configuration"]["writeVersions"] = [4]
        with self.assertRaises(PipelineError): validate_data_compatibility(modern)

    def test_v3_nullable_canonical_actions_and_legacy_field_rejection(self):
        base = {"schemaVersion":3, "aiModelSettings":{}, "aiSettingsRevision":"00000000-0000-0000-0000-000000000001"}
        action = {"id":"00000000-0000-0000-0000-000000000002", "version":1, "name":"Synthetic app", "applicationID":"app./Synthetic.app", "behavior":"hide"}
        for value in (None, [], [action]):
            data = json.dumps(dict(base, savedApplicationActions=value)).encode()
            path = self.write(data)
            self.assertEqual(compatibility.probe_configuration(self.root), 3)
            self.assertEqual(path.read_bytes(), data)
        for value in ({}, 1, "", [action, action], [dict(action, behavior="forceQuit")], [dict(action, name="a\nb")]):
            self.write(json.dumps(dict(base, savedApplicationActions=value)).encode())
            with self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
        for version in (1, 2):
            self.write(json.dumps(dict(base, schemaVersion=version, savedApplicationActions=None)).encode())
            with self.assertRaises(PipelineError): compatibility.probe_configuration(self.root)
