#!/usr/bin/env python3
"""用隔离Preview的两份签名App在owned目录验证安装、替换和回退。"""
import argparse
import base64
import contextlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
from types import SimpleNamespace

from keydock_common import CONFIG, ROOT, PipelineError, atomic_json, inspect_app, run


@contextlib.contextmanager
def qualification_directory():
    parent = ROOT / ".local/install-qualification"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="owned-", dir=parent)).resolve()
    try:
        yield directory
    except BaseException:
        print("Qualification evidence retained: " + str(directory), file=sys.stderr)
        raise
    else:
        shutil.rmtree(directory)


def require(condition, message):
    if not condition:
        raise PipelineError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()
    original = inspect_app(args.app)
    if original["profile"] != "preview" or not original["safe_smoke"]:
        raise PipelineError("Installation qualification uses only an isolated Preview App")
    with qualification_directory() as directory:
        first, second = directory / "First.app", directory / "Second.app"
        material_legacy = directory / "InvocationV2WithoutMaterials.app"
        destination = directory / "Applications/KeyDock Preview.app"
        for app in (first, second): run(["/usr/bin/ditto", args.app, app])
        # 第一份只模拟旧reader的签名能力声明，不冒充真实旧版二进制运行资格。
        first_metadata = first / "Contents/Resources/BuildInfo.json"
        first_info = json.loads(first_metadata.read_text())
        first_info["dataCompatibility"] = {"schemaVersion": 1, "invocationEnvelope": {"readVersions": [1], "writeVersions": [1]}}
        atomic_json(first_metadata, first_info); first_metadata.chmod(0o644)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", "--identifier", CONFIG["previewBundleIdentifier"], first])
        info_path = second / "Contents/Info.plist"
        with info_path.open("rb") as stream: info = plistlib.load(stream)
        build_number = str(int(info["CFBundleVersion"]) + 1)
        info["CFBundleVersion"] = build_number
        with info_path.open("wb") as stream: plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY)
        metadata_path = second / "Contents/Resources/BuildInfo.json"
        metadata = json.loads(metadata_path.read_text()); metadata["buildNumber"] = build_number; metadata["source"]["dirty"] = True
        atomic_json(metadata_path, metadata); metadata_path.chmod(0o644)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", "--identifier", CONFIG["previewBundleIdentifier"], second])
        expected_first, expected_second = inspect_app(first), inspect_app(second)
        run(["/usr/bin/ditto", args.app, material_legacy])
        legacy_metadata = material_legacy / "Contents/Resources/BuildInfo.json"
        legacy_info = json.loads(legacy_metadata.read_text())
        legacy_info["dataCompatibility"] = {"schemaVersion": 1, "invocationEnvelope": {"readVersions": [1, 2], "writeVersions": [1, 2]}}
        atomic_json(legacy_metadata, legacy_info); legacy_metadata.chmod(0o644)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", "--identifier", CONFIG["previewBundleIdentifier"], material_legacy])
        expected_material_legacy = inspect_app(material_legacy)
        module_spec = importlib.util.spec_from_file_location("keydock_owned_installer", ROOT / "scripts/install-app.py")
        installer = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(installer)
        data_root = directory / "SyntheticRuntimeData"
        resolver = lambda facts: data_root
        def install(app, receipt):
            return installer.install(SimpleNamespace(app=app, destination=destination, receipt=receipt, helper=args.helper,
                create_parents=True, allow_unnotarized_preview=True, quit_running=False, dry_run=False), data_root_resolver=resolver)
        first_receipt, second_receipt = directory / "first.json", directory / "second.json"
        install(first, first_receipt)
        require(inspect_app(destination)["bundle_sha256"] == expected_first["bundle_sha256"], "First installed App differs from source")
        from invocation_compatibility import FILES
        for name in FILES:
            folder = data_root / name; folder.mkdir(mode=0o700)
            atomic_json(folder / "invocations.json", {"version": 1, "receipts": []})
        install(second, second_receipt)
        require(inspect_app(destination)["bundle_sha256"] == expected_second["bundle_sha256"], "Replacement App differs from source")
        installer.rollback(SimpleNamespace(rollback=second_receipt, helper=args.helper, quit_running=False, dry_run=False), data_root_resolver=resolver)
        require(inspect_app(destination)["bundle_sha256"] == expected_first["bundle_sha256"], "Rollback did not restore the original App")
        record = json.loads(second_receipt.read_text())
        require(inspect_app(Path(record["backup_path"]))["bundle_sha256"] == expected_second["bundle_sha256"], "Rollback did not retain the replaced App")
        third_receipt = directory / "third.json"
        # 固定三个库的v2合成字节；升级必须放行，旧reader的install和rollback均必须拒绝。
        for name in FILES:
            atomic_json(data_root / name / "invocations.json", {"version": 2, "receipts": []})
        before_data = {name: (data_root / name / "invocations.json").read_bytes() for name in FILES}
        install(second, third_receipt)
        require(inspect_app(destination)["bundle_sha256"] == expected_second["bundle_sha256"], "Version-two compatible upgrade was not installed")
        for operation in (
            lambda: installer.rollback(SimpleNamespace(rollback=third_receipt, helper=args.helper, quit_running=False, dry_run=False), data_root_resolver=resolver),
            lambda: install(first, directory / "must-not-install.json"),
        ):
            try:
                operation()
            except PipelineError as error:
                require("cannot read the current invocation data" in str(error), "Operation failed for a reason other than data compatibility: " + str(error))
            else:
                raise PipelineError("An incompatible signed capability was admitted")
            require(inspect_app(destination)["bundle_sha256"] == expected_second["bundle_sha256"], "Refused downgrade changed the installed App")
            require(all((data_root / name / "invocations.json").read_bytes() == data for name, data in before_data.items()), "Compatibility qualification changed invocation bytes")
        # invocation v2一致，唯独材料reader不同，避免被较早的envelope门禁抢先挡住。
        install(material_legacy, directory / "material-legacy.json")
        material_receipt = directory / "material-upgrade.json"
        install(second, material_receipt)
        material_record = json.loads(material_receipt.read_text())
        material_backup = Path(material_record["backup_path"])
        require(inspect_app(material_backup)["bundle_sha256"] == expected_material_legacy["bundle_sha256"], "Material reader backup changed")
        golden = json.loads((ROOT / "Tools/Fixtures/task-material-v1.json").read_text())
        material_directory = data_root / "task-materials"; material_directory.mkdir(mode=0o700)
        temporary_name = ".material-v1-" + golden["fileName"].removesuffix(".kdmaterial") + "-00000000-0000-0000-0000-000000000099.tmp"
        cases = [(golden["fileName"], base64.b64decode(golden["frameBase64"])),
                 (temporary_name, b"synthetic interrupted material"),
                 ("control.json", base64.b64decode(golden["controlDeletionBase64"]))]
        for index, (name, data) in enumerate(cases):
            path = material_directory / name; path.write_bytes(data); path.chmod(0o600)
            for operation in (
                lambda: installer.rollback(SimpleNamespace(rollback=material_receipt, helper=args.helper, quit_running=False, dry_run=False), data_root_resolver=resolver),
                lambda: install(material_legacy, directory / ("must-not-install-material-" + str(index) + ".json")),
            ):
                try: operation()
                except PipelineError as error:
                    require("cannot read the current task material data" in str(error), "Unexpected material refusal: " + str(error))
                else: raise PipelineError("A signed App without material readers was admitted")
                require(path.read_bytes() == data, "Material compatibility qualification changed data")
                require(inspect_app(destination)["bundle_sha256"] == expected_second["bundle_sha256"], "Material refusal changed the installed App")
                require(inspect_app(material_backup)["bundle_sha256"] == expected_material_legacy["bundle_sha256"], "Material refusal changed the backup App")
            path.unlink()
        idle_control = material_directory / "control.json"
        idle_control.write_bytes(base64.b64decode(golden["controlIdleBase64"])); idle_control.chmod(0o600)
        installer.rollback(SimpleNamespace(rollback=material_receipt, helper=args.helper, quit_running=False, dry_run=False), data_root_resolver=resolver)
        require(inspect_app(destination)["bundle_sha256"] == expected_material_legacy["bundle_sha256"], "Actually cleared materials did not permit rollback")
        report = {"state": "PASS", "scope": "owned temporary directory, isolated signed Preview, no app launch or personal data",
                  "dataRootResolver": "owned fixture injection; default runtime domain selection is qualified separately",
                  "firstBuild": expected_first["build_number"], "secondBuild": expected_second["build_number"],
                  "installed": True, "replaced": True, "rolledBack": record["state"] == "rolled-back", "retainedBothVersions": True,
                  "dataCompatibilityQualified": True, "versionTwoUpgrade": True, "incompatibleInstallRefused": True,
                  "incompatibleRollbackRefused": True, "dataBytesPreserved": True,
                  "taskMaterialCapabilityQualified": True, "taskMaterialBodyAndTemporaryAndPendingRefused": True,
                  "taskMaterialClearedRollbackAllowed": True,
                  "taskMaterialReaderScope": "synthetic invocation-v2 / no-material-reader capability, ad-hoc signed Preview; not an actual alpha.19 runtime test",
                  "legacyReaderScope": "synthetic read-v1-only capability, ad-hoc signed Preview; not an actual alpha.18 runtime test",
                  "incompatibleCompensationScope": "unit fault-injection coverage; not exercised with signed Apps here"}
        atomic_json(ROOT / ".local/install-qualification-latest.json", report)
        print(json.dumps(report, indent=2))


if __name__ == "__main__": main()
