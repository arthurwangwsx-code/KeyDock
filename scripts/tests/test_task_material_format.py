"""只读合成golden的前缀、header和control，不引入正文文件I/O。"""
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from keydock_common import PipelineError
import task_material_format as codec


class TaskMaterialFormatTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads((Path(__file__).resolve().parents[2] / "Tools/Fixtures/task-material-v1.json").read_text())
        self.frame = base64.b64decode(self.fixture["frameBase64"], validate=True)
        self.prefix = self.frame[:12]
        self.header_bytes = self.frame[12:12 + self.fixture["headerBytes"]]

    def parse(self, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        prefix = codec.MAGIC + len(data).to_bytes(4, "big")
        return codec.parse_header(prefix, data, len(data) + 12 + value["payloadBytes"])

    def test_fixed_golden_matches_hash_and_header_framing_without_passing_body(self):
        self.assertEqual(hashlib.sha256(self.frame).hexdigest(), self.fixture["frameSHA256"])
        self.assertEqual(codec.header_length(self.prefix), self.fixture["headerBytes"])
        header = codec.parse_header(self.prefix, self.header_bytes, len(self.frame))
        self.assertEqual(codec.material_name(header["key"]), self.fixture["fileName"])
        self.assertEqual(header["payloadBytes"], self.fixture["payloadBytes"])

    def test_golden_control_idle_pending_write_and_clear_are_distinct(self):
        for field, pending, deleting in (("controlIdleBase64", False, False), ("controlPendingWriteBase64", True, False), ("controlDeletionBase64", False, True)):
            with self.subTest(field=field):
                value = codec.parse_control(base64.b64decode(self.fixture[field], validate=True))
                self.assertEqual(value.get("pendingWrite") is not None, pending)
                self.assertEqual(value.get("deletion") is not None, deleting)

    def test_future_noninteger_schema_nested_fields_and_size_drift_are_rejected(self):
        original = codec.parse_header(self.prefix, self.header_bytes, len(self.frame))
        for schema in (2, True, 1.0, "1"):
            with self.subTest(schema=schema):
                changed = copy.deepcopy(original); changed["formatVersion"] = schema
                with self.assertRaises(PipelineError): self.parse(changed)
        changed = copy.deepcopy(original); changed["key"]["grant"] = "forbidden"
        with self.assertRaises(PipelineError): self.parse(changed)
        with self.assertRaises(PipelineError): codec.parse_header(self.prefix, self.header_bytes, len(self.frame) + 1)
        with self.assertRaises(PipelineError): codec.header_length(b"KDMAT002" + b"\0\0\0\1")
        with self.assertRaises(PipelineError): codec.header_length(codec.MAGIC + (8193).to_bytes(4, "big"))

    def test_unknown_control_fields_and_malformed_nested_key_are_rejected(self):
        data = base64.b64decode(self.fixture["controlPendingWriteBase64"])
        value = json.loads(data); value["pendingWrite"]["key"]["runtimeGrant"] = True
        with self.assertRaises(PipelineError): codec.parse_control(json.dumps(value).encode())
        value = json.loads(data); value["formatVersion"] = True
        with self.assertRaises(PipelineError): codec.parse_control(json.dumps(value).encode())
        with self.assertRaises(PipelineError): codec.parse_control(b'{"formatVersion":1,"formatVersion":1}')


if __name__ == "__main__": unittest.main()
