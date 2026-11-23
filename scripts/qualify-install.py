#!/usr/bin/env python3
"""用隔离Preview的两份签名App在owned目录验证安装、替换和回退。"""
import argparse
import contextlib
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile

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
        destination = directory / "Applications/KeyDock Preview.app"
        for app in (first, second): run(["/usr/bin/ditto", args.app, app])
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
        installer = ROOT / "scripts/install-app.py"
        def install(app, receipt):
            run([sys.executable, installer, "--app", app, "--destination", destination, "--receipt", receipt,
                 "--helper", args.helper, "--create-parents", "--allow-unnotarized-preview"])
        first_receipt, second_receipt = directory / "first.json", directory / "second.json"
        install(first, first_receipt)
        require(inspect_app(destination)["bundle_sha256"] == expected_first["bundle_sha256"], "First installed App differs from source")
        install(second, second_receipt)
        require(inspect_app(destination)["bundle_sha256"] == expected_second["bundle_sha256"], "Replacement App differs from source")
        run([sys.executable, installer, "--rollback", second_receipt, "--helper", args.helper])
        require(inspect_app(destination)["bundle_sha256"] == expected_first["bundle_sha256"], "Rollback did not restore the original App")
        record = json.loads(second_receipt.read_text())
        require(inspect_app(Path(record["backup_path"]))["bundle_sha256"] == expected_second["bundle_sha256"], "Rollback did not retain the replaced App")
        report = {"state": "PASS", "scope": "owned temporary directory, isolated signed Preview, no app launch or personal data",
                  "firstBuild": expected_first["build_number"], "secondBuild": expected_second["build_number"],
                  "installed": True, "replaced": True, "rolledBack": record["state"] == "rolled-back", "retainedBothVersions": True}
        atomic_json(ROOT / ".local/install-qualification-latest.json", report)
        print(json.dumps(report, indent=2))


if __name__ == "__main__": main()
