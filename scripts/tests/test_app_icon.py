"""原生 AppIcon 必须随正式及 Preview 的共同资源编入应用。"""
import struct
import unittest
from pathlib import Path


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
        self.assertIn("INFOPLIST_KEY_CFBundleIconFile: AppIcon.icns", (root / "project.yml").read_text())
