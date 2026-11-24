"""发行边界使用合成ZIP/临时目录；不签名、不联网、不操作真实App。"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import keydock
from quality_fixture import HOST, fixture_summary, fixture_ci
from keydock_common import CONFIG, PipelineError, atomic_json, sha256, signature_has_runtime, tree_digest, validate_version


class ReleasePipelineTests(unittest.TestCase):
    def test_build_storage_boundary_and_refusal_use_available_space(self):
        minimum = keydock.MINIMUM_BUILD_FREE_BYTES
        for free, ready in [(minimum - 1, False), (minimum, True), (minimum + 1, True)]:
            with self.subTest(free=free), patch.object(keydock.shutil, "disk_usage", return_value=SimpleNamespace(free=free)):
                self.assertEqual(keydock.build_storage_status(), {"freeBytes": free, "minimumFreeBytes": minimum, "ready": ready})
                if ready: keydock.require_build_space()
                else:
                    with self.assertRaisesRegex(PipelineError, "at least 2 GiB"): keydock.require_build_space()

    def test_low_space_check_records_failure_before_running_any_stage(self):
        attempt = Path("/synthetic/check-attempt.json")
        with patch.object(keydock, "require_build_space", side_effect=PipelineError("synthetic low space")), patch.object(keydock.quality, "begin_check", return_value=attempt), patch.object(keydock.quality, "finish_check") as finish, patch.object(keydock, "stage") as stage:
            with self.assertRaises(PipelineError): keydock.check(ci=True)
            stage.assert_not_called()
            finish.assert_called_once_with(attempt, False)

    def test_low_space_build_does_not_start_xcodegen_or_reuse_qualification(self):
        with patch.object(keydock.platform, "system", return_value="Darwin"), patch.object(keydock.platform, "machine", return_value=CONFIG["architecture"]), patch.object(keydock, "require_build_space", side_effect=PipelineError("synthetic low space")), patch.object(keydock, "stage") as stage, patch.object(keydock.quality, "require_local") as qualification:
            with self.assertRaises(PipelineError): keydock.build("release")
            stage.assert_not_called(); qualification.assert_not_called()

    def test_check_requires_both_complementary_swift_partitions_before_helper(self):
        for failed_stage in (None, "swift-tests", "swift-terminal-lifecycle"):
            with self.subTest(failed_stage=failed_stage), tempfile.TemporaryDirectory() as temporary:
                log = Path(temporary) / "synthetic.log"
                log.write_text("✔ Test run with 4 tests in 1 suite passed after 0.3 seconds.\n")
                stages = []
                def stage(name, command, **kwargs):
                    stages.append((name, command))
                    if name == failed_stage: raise PipelineError("synthetic failure")
                    return log
                with patch.object(keydock, "stage", side_effect=stage), patch.object(keydock, "helper") as helper, patch.object(keydock.quality, "record_check"), patch.object(keydock.quality,"host_facts",return_value=HOST), patch.object(keydock, "require_build_space"):
                    if failed_stage:
                        with self.assertRaises(PipelineError): keydock.check(ci=True)
                        helper.assert_not_called()
                    else:
                        keydock.check(ci=True)
                        commands = dict(stages)
                        primary, timing = commands["swift-tests"], commands["swift-terminal-lifecycle"]
                        self.assertIn(timing[timing.index("--filter") + 1], primary[primary.index("--skip") + 1])
                        self.assertIn(keydock.quality.OCR_FILTER, primary[primary.index("--skip") + 1])
                        self.assertNotIn(keydock.quality.OCR_STAGE, commands)
                        self.assertIn("--no-parallel", primary)
                        self.assertIn("--no-parallel", timing)
                        helper.assert_called_once()

    def test_empty_or_missing_swift_test_summary_cannot_pass_a_partition(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "synthetic.log"
            for output in ("warning: No matching test cases were run", "✔ Test run with 0 tests passed."):
                log.write_text(output)
                with self.assertRaises(PipelineError): keydock.require_swift_tests(log)

    def test_dmg_verification_rejects_other_signing_team_before_trust_checks(self):
        manifest = {"assets": [{"name": "synthetic.dmg"}]}
        details = subprocess.CompletedProcess([], 0, stderr="Authority=Developer ID Application: Synthetic\nTeamIdentifier=OTHER\n")
        with patch.object(keydock, "run") as command, patch.object(keydock.subprocess, "run", return_value=details):
            with self.assertRaises(PipelineError): keydock.verify_dmg(Path("/synthetic"), manifest)
            self.assertEqual(command.call_count, 1)

    def test_runtime_flag_accepts_combined_flags_without_trusting_other_text(self):
        self.assertTrue(signature_has_runtime("CodeDirectory v=20500 size=8 flags=0x10002(adhoc,runtime) hashes=1+3"))
        self.assertTrue(signature_has_runtime("CodeDirectory v=20500 size=8 flags=0x10000(runtime) hashes=1+3"))
        self.assertFalse(signature_has_runtime("CodeDirectory v=20500 size=8 flags=0x2(adhoc)\nIdentifier=runtime"))

    def fixture(self, directory, entries=None):
        version = CONFIG["version"]
        stem = "KeyDock-" + version + "-macos-arm64"
        zip_path, dmg = directory / (stem + ".zip"), directory / (stem + ".dmg")
        with zipfile.ZipFile(zip_path, "w") as archive:
            for name, value in entries or [("KeyDock.app/Contents/Resources/synthetic.txt", b"synthetic")]:
                archive.writestr(name, value)
        dmg.write_bytes(b"synthetic dmg; never mounted")
        qualification = fixture_summary()
        manifest = {"schemaVersion": 2, "version": version, "tag": "v" + version, "buildNumber": CONFIG["buildNumber"],
                    "qualification": qualification, "qualificationSHA256": keydock.quality.digest(qualification), "coreCI": fixture_ci(), "cloudOCR": "NOT_QUALIFIED",
                    "source": {"commit": "a" * 40, "dirty": False}, "safeSmoke": False,
                    "architecture": "arm64", "bundleIdentifier": CONFIG["bundleIdentifier"],
                    "signature": {"kind": "developer-id", "team_id": CONFIG["teamID"], "hardened_runtime": True},
                    "notarized": True,
                    "assets": [{"name": p.name, "bytes": p.stat().st_size, "sha256": sha256(p)} for p in (zip_path, dmg)]}
        self.save_manifest(directory, manifest)
        return manifest

    def save_manifest(self, directory, manifest):
        atomic_json(directory / "release-manifest.json", manifest)
        files = [p for p in directory.iterdir() if p.name != "SHA256SUMS.txt"]
        (directory / "SHA256SUMS.txt").write_text("".join(sha256(p) + "  " + p.name + "\n" for p in sorted(files)))

    def test_exact_asset_set_and_manifest_round_trip(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); expected = self.fixture(directory)
            self.assertEqual(keydock.verify_assets(directory), expected)

    def test_tampered_asset_does_not_pass_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); manifest = self.fixture(directory)
            (directory / manifest["assets"][0]["name"]).write_bytes(b"changed")
            with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_unlisted_files_cannot_be_uploaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); self.fixture(directory)
            (directory / "private-build.log").write_text("synthetic")
            with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_release_rejects_preview_dirty_source_wrong_team_and_missing_notarization(self):
        for field, value in [("safeSmoke", True), ("notarized", False), ("source", {"commit": "a" * 40, "dirty": True}),
                             ("signature", {"kind": "developer-id", "team_id": "synthetic-other-team", "hardened_runtime": True})]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary); manifest = self.fixture(directory)
                manifest[field] = value; self.save_manifest(directory, manifest)
                with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_zip_traversal_and_external_payload_are_rejected_before_extraction(self):
        for name in ["../outside", "/absolute", "KeyDock.app/../outside", "unrelated-secret.txt"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary); self.fixture(directory, [(name, b"synthetic")])
                with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_zip_symlink_cannot_escape_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            link = zipfile.ZipInfo("KeyDock.app/Contents/escape")
            link.create_system = 3; link.external_attr = (stat.S_IFLNK | 0o777) << 16
            self.fixture(directory, [(link, b"../../outside")])
            with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_duplicate_zip_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory, [("KeyDock.app/Contents/Value", b"first"), ("KeyDock.app/Contents/value", b"second")])
            with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_checksum_list_cannot_redirect_to_parent_or_duplicate_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); self.fixture(directory)
            (directory / "SHA256SUMS.txt").write_text("a" * 64 + "  ../outside\n")
            with self.assertRaises(PipelineError): keydock.verify_assets(directory)

    def test_failed_notarization_never_advances_to_stapling_or_publishing(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "notary.json"
            log.write_text(json.dumps({"id": "11111111-2222-3333-4444-555555555555", "status": "Invalid"}))
            with patch.object(keydock, "stage", return_value=log) as command:
                with self.assertRaises(PipelineError): keydock.notarize(Path("synthetic.zip"), "synthetic-profile", "synthetic-notary")
                self.assertEqual(command.call_count, 1)

    def test_packaging_refuses_a_debug_app_without_notary_or_file_mutations(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(keydock, "DIST", directory / "absent"), patch.object(keydock, "source_identity", return_value={"commit": "a" * 40, "dirty": False}), patch.object(keydock, "inspect_app", return_value={"profile": "preview", "safe_smoke": True, "source_dirty": False, "commit": "a" * 40}), patch.object(keydock, "notarize") as notary:
                with self.assertRaises(PipelineError): keydock.package(directory / "synthetic.app", "synthetic-profile")
                notary.assert_not_called()
                self.assertEqual(list(directory.iterdir()), [])

    def test_tree_copy_digest_covers_resources_modes_and_external_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); app = directory / "Synthetic.app"; app.mkdir()
            resource = app / "resource"; resource.write_text("synthetic")
            original = tree_digest(app); resource.write_text("changed")
            self.assertNotEqual(tree_digest(app), original)
            (app / "escape").symlink_to(directory / "outside")
            with self.assertRaises(PipelineError): tree_digest(app)

    def test_versions_cannot_be_shell_or_path_input(self):
        self.assertEqual(validate_version("0.1.0-alpha.1"), "0.1.0")
        for version in ["../../private", "1.0.0;exit", "v1.0.0", "1.0"]:
            with self.assertRaises(PipelineError): validate_version(version)

    def test_install_wrapper_preserves_caller_relative_paths_without_early_mkdir(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve(); app = directory / "Synthetic.app"; app.mkdir()
            previous = Path.cwd()
            try:
                os.chdir(directory)
                with patch.object(keydock, "inspect_app", return_value={"profile": "preview"}), patch.object(keydock, "helper", return_value=directory / "helper"), patch.object(keydock, "run") as command:
                    keydock.install(app, destination=Path("Apps/Preview.app"), receipt=Path("receipts/install.json"))
                    values = [str(value) for value in command.call_args[0][0]]
                    self.assertEqual(values[values.index("--destination") + 1], str(directory / "Apps/Preview.app"))
                    self.assertEqual(values[values.index("--receipt") + 1], str(directory / "receipts/install.json"))
                    self.assertFalse((directory / "Apps").exists())
                    self.assertFalse((directory / "receipts").exists())
            finally:
                os.chdir(previous)


if __name__ == "__main__": unittest.main()
