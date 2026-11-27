"""原生 AppIcon 必须随正式及 Preview 的共同资源编入应用。"""
import struct
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock
from keydock_common import PipelineError


class AppIconTests(unittest.TestCase):
    def test_icon_bundle_has_standard_png_resolutions(self):
        root = Path(__file__).resolve().parents[2]
        icon = (root / "Apps/KeyDock/Resources/AppIcon.icns").read_bytes()
        self.assertEqual(icon[:4], b"icns")
        self.assertEqual(struct.unpack_from(">I", icon, 4)[0], len(icon))
        dimensions = set()
        offset = 8
        while offset < len(icon):
            length = struct.unpack_from(">I", icon, offset + 4)[0]
            self.assertGreaterEqual(length, 8)
            self.assertLessEqual(offset + length, len(icon))
            payload = icon[offset + 8:offset + length]
            if payload.startswith(b"\x89PNG\r\n\x1a\n"):
                dimensions.add(struct.unpack_from(">II", payload, 16))
            offset += length
        self.assertEqual(offset, len(icon))
        self.assertIn((1024, 1024), dimensions)
        self.assertIn((512, 512), dimensions)
        self.assertIn((256, 256), dimensions)
        self.assertIn("INFOPLIST_FILE: Apps/KeyDock/Info.plist", (root / "project.yml").read_text())
        self.assertEqual(plistlib.loads((root / "Apps/KeyDock/Info.plist").read_bytes())["CFBundleIconFile"], "AppIcon.icns")

    def test_built_bundle_needs_exact_icon_metadata_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Synthetic.app"
            resource = app / "Contents/Resources/AppIcon.icns"
            resource.parent.mkdir(parents=True)
            resource.write_bytes((keydock.ROOT / "Apps/KeyDock/Resources/AppIcon.icns").read_bytes())
            with self.assertRaises(PipelineError): keydock.require_app_icon(app, {})
            keydock.require_app_icon(app, {"CFBundleIconFile": "AppIcon.icns"})
            resource.write_bytes(b"wrong icon")
            with self.assertRaises(PipelineError): keydock.require_app_icon(app, {"CFBundleIconFile": "AppIcon.icns"})
