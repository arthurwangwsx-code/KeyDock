#!/usr/bin/env python3
"""KeyDock统一工程入口：检查、调试、发行、安装、回退与GitHub资产复核。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

from keydock_common import CONFIG, ROOT, PipelineError, atomic_json, inspect_app, run, sha256, source_identity, validate_version

BUILD = ROOT / "build/pipeline"
DIST = ROOT / "build/releases" / CONFIG["version"]
RUN_DIR = ROOT / ".local/pipeline" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
TERMINAL_TIMING_SUITES = r"^(WorkbenchFeatureTests\.TerminalLifecycleTests|MacAdaptersTests\.TerminalHandoffAdapterTests)/"


def stage(name, command):
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    path = RUN_DIR / (name + ".log")
    started = time.monotonic()
    print("[%s] %s" % (name, path.relative_to(ROOT)), flush=True)
    with path.open("w") as stream:
        result = subprocess.run([str(value) for value in command], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    record = {"stage": name, "exitCode": result.returncode, "seconds": round(time.monotonic() - started, 3)}
    atomic_json(RUN_DIR / (name + ".json"), record)
    if result.returncode:
        lines = path.read_text(errors="replace").splitlines()
        failures = [line for line in lines if any(marker in line for marker in ("✘", "error:", "AssertionError", "FAILED", "recorded an issue"))]
        print("\n".join(failures[-40:] + lines[-18:]), file=sys.stderr)
        raise PipelineError("%s failed; log: %s" % (name, path))
    return path


def helper():
    path = BUILD / "tools/KeyDockLifecycle"
    path.parent.mkdir(parents=True, exist_ok=True)
    stage("lifecycle-helper", ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-target", "arm64-apple-macos14.0",
                               ROOT / "Tools/KeyDockLifecycle/main.swift", "-o", path])
    return path


def check(ci=False):
    if not ci:
        stage("branch", [ROOT / "scripts/check-branch-policy.sh", "--allow-master"])
    stage("documents", [sys.executable, ROOT / "scripts/validate-docs.py"])
    stage("localizations", [sys.executable, ROOT / "scripts/update-localizations.py", "--check"])
    stage("pipeline-tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"])
    # Swift Testing默认并行套件；时限合同在独立进程验证，不能被其余主线程负载污染。
    # 两个互补阶段都强制成功，既不删除用例，也不通过失败后重试掩盖问题。
    tests = ["xcrun", "swift", "test", "--jobs", "2"]
    require_swift_tests(stage("swift-tests", tests + ["--skip", TERMINAL_TIMING_SUITES]))
    require_swift_tests(stage("swift-terminal-lifecycle", tests + ["--filter", TERMINAL_TIMING_SUITES]))
    helper()


def require_swift_tests(log):
    counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", Path(log).read_text(errors="replace"))
    if not counts or sum(map(int, counts)) == 0:
        raise PipelineError("Swift test stage ran no cases; check its selector and log: " + str(log))


def build(profile="preview", configuration=None, allow_dirty=False, identity=None):
    if platform.system() != "Darwin" or platform.machine() != CONFIG["architecture"]:
        raise PipelineError("This pipeline currently qualifies macOS arm64 only")
    source = source_identity(require_clean=not allow_dirty)
    xcode = run(["xcrun", "xcodebuild", "-version"], capture=True).strip()
    if not xcode.startswith("Xcode " + CONFIG["xcodeVersion"] + "\n"):
        raise PipelineError("Select Xcode " + CONFIG["xcodeVersion"] + " with DEVELOPER_DIR")
    configuration = configuration or ("Release" if profile == "release" else "Debug")
    if profile == "release" and configuration != "Release":
        raise PipelineError("Distribution must use the Release configuration")
    build_configuration = configuration + "Preview" if profile == "preview" else configuration
    signing = identity or (CONFIG["signingIdentity"] if profile == "release" else "-")
    product = "KeyDock" if profile == "release" else "KeyDockPreview"
    bundle_id = CONFIG["bundleIdentifier"] if profile == "release" else CONFIG["previewBundleIdentifier"]
    output = BUILD / profile
    output.mkdir(parents=True, exist_ok=True)
    stage("xcodegen-" + profile, ["xcodegen", "generate", "--spec", ROOT / "project.yml"])
    command = ["xcrun", "xcodebuild", "-project", ROOT / "KeyDock.xcodeproj", "-scheme", "KeyDock", "-configuration", build_configuration,
               "-jobs", "2", "-derivedDataPath", output / "DerivedData", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
               "MARKETING_VERSION=" + validate_version(CONFIG["version"]), "CURRENT_PROJECT_VERSION=" + CONFIG["buildNumber"],
               "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO", "COPY_PHASE_STRIP=YES", "STRIP_INSTALLED_PRODUCT=YES",
               "OTHER_SWIFT_FLAGS=$(inherited) -debug-prefix-map " + str(ROOT) + "=/KeyDock"]
    if profile == "release":
        archive = output / "KeyDock.xcarchive"
        command += ["-archivePath", archive, "SKIP_INSTALL=NO", "archive"]
        built = archive / "Products/Applications/KeyDock.app"
    else:
        command += ["build"]
        built = output / "DerivedData/Build/Products" / build_configuration / (product + ".app")
    stage("build-" + profile, command)
    if source_identity(require_clean=not allow_dirty) != source:
        raise PipelineError("Source changed while building; rerun against one reviewed commit")
    app = output / ("KeyDock.app" if profile == "release" else "KeyDock Preview.app")
    if app.exists():
        if app.is_symlink():
            raise PipelineError("Refusing to replace a symlink build output")
        shutil.rmtree(app)
    run(["/usr/bin/ditto", built, app])
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    info.update(KeyDockSafeSmoke=profile == "preview", KeyDockGitCommit=source["commit"], KeyDockReleaseVersion=CONFIG["version"])
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY)
    metadata = {"schemaVersion": 1, "version": CONFIG["version"], "buildNumber": CONFIG["buildNumber"], "profile": profile,
                "source": source, "architecture": "arm64", "xcode": xcode.splitlines()[0],
                "swift": run(["xcrun", "swift", "--version"], capture=True).splitlines()[0]}
    atomic_json(app / "Contents/Resources/BuildInfo.json", metadata)
    (app / "Contents/Resources/BuildInfo.json").chmod(0o644)
    shutil.copyfile(ROOT / "LICENSE", app / "Contents/Resources/LICENSE.txt")
    signing_command = ["/usr/bin/codesign", "--force", "--sign", signing, "--options", "runtime", "--identifier", bundle_id,
                       "--timestamp=none" if signing == "-" else "--timestamp", app]
    stage("sign-" + profile, signing_command)
    result = inspect_app(app)
    if profile == "release" and (result["code_signature"]["kind"] != "developer-id" or
                                 result["code_signature"]["team_id"] != CONFIG["teamID"] or
                                 not result["code_signature"]["hardened_runtime"]):
        raise PipelineError("Distribution needs the configured Developer ID team and Hardened Runtime")
    atomic_json(output / "build-result.json", {"app": str(app), "facts": result})
    print("Built: " + str(app), flush=True)
    return app


def notarize(path, profile, name):
    log = stage(name, ["xcrun", "notarytool", "submit", path, "--keychain-profile", profile, "--wait", "--timeout", "20m", "--output-format", "json"])
    text = log.read_text()
    try:
        result = json.loads(text[text.index("{"):text.rindex("}") + 1])
    except (ValueError, json.JSONDecodeError):
        raise PipelineError("Notary service did not return a valid JSON result; retain " + str(log))
    if result.get("status") != "Accepted" or not re.fullmatch(r"[0-9a-fA-F-]{36}", result.get("id", "")):
        raise PipelineError("Notarization was not accepted; no distribution was published")
    return result["id"]


def package(app=None, profile=None):
    identity = source_identity()
    if DIST.exists():
        manifest = verify_assets(DIST)
        if manifest["source"]["commit"] != identity["commit"]:
            raise PipelineError("This release version already has different source; bump release/config.json")
        print("Reused verified immutable package: " + str(DIST), flush=True)
        return DIST
    app = Path(app or BUILD / "release/KeyDock.app")
    facts = inspect_app(app)
    if facts["profile"] != "release" or facts["safe_smoke"] or facts["source_dirty"] or facts["commit"] != identity["commit"]:
        raise PipelineError("Package only the current clean-source regular Release App")
    if facts["release_version"] != CONFIG["version"] or facts["code_signature"]["kind"] != "developer-id" or facts["code_signature"]["team_id"] != CONFIG["teamID"] or not facts["code_signature"]["hardened_runtime"]:
        raise PipelineError("Release identity does not match the configured version, team or runtime")
    profile = profile or os.environ.get("KEYDOCK_NOTARY_PROFILE")
    if not profile:
        raise PipelineError("Set KEYDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile; credentials stay in Keychain")
    work = RUN_DIR / "package"
    work.mkdir(parents=True, exist_ok=True)
    payload = work / "notary-payload.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, payload])
    app_submission = notarize(payload, profile, "notary-app")
    stage("staple-app", ["xcrun", "stapler", "staple", app])
    stage("validate-app-ticket", ["xcrun", "stapler", "validate", app])
    stage("gatekeeper-app", ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])
    facts = inspect_app(app)
    assets = work / "assets"
    assets.mkdir()
    stem = "KeyDock-" + CONFIG["version"] + "-macos-arm64"
    zip_path = assets / (stem + ".zip")
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path])
    image_root = work / "image"
    image_root.mkdir()
    run(["/usr/bin/ditto", app, image_root / "KeyDock.app"])
    os.symlink("/Applications", image_root / "Applications")
    shutil.copyfile(ROOT / "release/INSTALL.txt", image_root / "INSTALL.txt")
    dmg = assets / (stem + ".dmg")
    stage("dmg", ["/usr/bin/hdiutil", "create", "-volname", "KeyDock", "-srcfolder", image_root, "-format", "UDZO", dmg])
    stage("sign-dmg", ["/usr/bin/codesign", "--force", "--sign", CONFIG["signingIdentity"], "--timestamp", dmg])
    dmg_submission = notarize(dmg, profile, "notary-dmg")
    stage("staple-dmg", ["xcrun", "stapler", "staple", dmg])
    stage("validate-dmg-ticket", ["xcrun", "stapler", "validate", dmg])
    stage("gatekeeper-dmg", ["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg])
    manifest = {"schemaVersion": 1, "version": CONFIG["version"], "tag": "v" + CONFIG["version"], "source": identity,
                "architecture": "arm64", "minimumTarget": "14.0", "qualifiedHost": "macOS 27.2 arm64",
                "bundleIdentifier": facts["bundle_id"], "bundleVersion": facts["version"], "buildNumber": facts["build_number"],
                "signature": facts["code_signature"], "notarized": facts["notarized"], "safeSmoke": False,
                "notarizationSubmissions": {"app": app_submission, "dmg": dmg_submission},
                "productAcceptance": "PARTIAL; see release notes for physical-device and external-model limits",
                "assets": [{"name": p.name, "bytes": p.stat().st_size, "sha256": sha256(p)} for p in (zip_path, dmg)]}
    atomic_json(assets / "release-manifest.json", manifest)
    (assets / "SHA256SUMS.txt").write_text("".join(sha256(p) + "  " + p.name + "\n" for p in sorted(assets.iterdir()) if p.is_file()))
    verify_assets(assets)
    if source_identity() != identity:
        raise PipelineError("Source changed during notarization; verified files were kept in the local staging directory")
    DIST.parent.mkdir(parents=True, exist_ok=True)
    os.rename(assets, DIST)
    print("Packaged: " + str(DIST), flush=True)
    return DIST


def verify_assets(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "release-manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("safeSmoke") is not False or not manifest.get("notarized"):
        raise PipelineError("Release manifest does not describe a notarized regular App")
    if manifest.get("tag") != "v" + manifest.get("version", "") or manifest.get("source", {}).get("dirty"):
        raise PipelineError("Release version or source identity is inconsistent")
    if manifest.get("architecture") != "arm64" or manifest.get("bundleIdentifier") != CONFIG["bundleIdentifier"] or manifest.get("signature", {}).get("kind") != "developer-id" or manifest.get("signature", {}).get("team_id") != CONFIG["teamID"] or manifest.get("signature", {}).get("hardened_runtime") is not True:
        raise PipelineError("Release identity, architecture or signing team is not the configured application")
    validate_version(manifest["version"])
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("source", {}).get("commit", "")):
        raise PipelineError("Release has no full source commit")
    assets = manifest.get("assets", [])
    if len(assets) != 2 or {Path(a["name"]).suffix for a in assets} != {".zip", ".dmg"}:
        raise PipelineError("Release must contain one ZIP and one DMG")
    expected_names = {"release-manifest.json", "SHA256SUMS.txt"}
    for asset in assets:
        name = asset["name"]
        if Path(name).name != name or name in expected_names or not name.startswith("KeyDock-" + manifest["version"] + "-macos-arm64."):
            raise PipelineError("Unsafe or unexpected asset filename")
        expected_names.add(name)
        path = directory / name
        if path.is_symlink() or path.stat().st_size != asset["bytes"] or sha256(path) != asset["sha256"]:
            raise PipelineError("Release asset differs from its manifest: " + name)
    sums = {}
    for line in (directory / "SHA256SUMS.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        if not match or match[2] in sums:
            raise PipelineError("Invalid or duplicate checksum entry")
        sums[match[2]] = match[1]
    if set(sums) != expected_names - {"SHA256SUMS.txt"} or {p.name for p in directory.iterdir()} != expected_names:
        raise PipelineError("Release asset set differs from its checksum list")
    for name, digest in sums.items():
        path = directory / name
        if path.is_symlink() or sha256(path) != digest:
            raise PipelineError("Checksum mismatch: " + name)
    validate_zip(directory / next(a["name"] for a in assets if a["name"].endswith(".zip")))
    return manifest


def validate_zip(path):
    with zipfile.ZipFile(path) as archive:
        total = 0
        found_app = False
        seen = set()
        for entry in archive.infolist():
            name = entry.filename
            parts = Path(name).parts
            total += entry.file_size
            if not parts or Path(name).is_absolute() or ".." in parts or "\\" in name or "\0" in name or total > 512 * 1024 * 1024 or name.casefold() in seen:
                raise PipelineError("Unsafe release ZIP path or expanded size")
            seen.add(name.casefold())
            if parts[0] not in ("KeyDock.app", "__MACOSX"):
                raise PipelineError("Unexpected file outside the release App")
            found_app |= parts[0] == "KeyDock.app" and len(parts) > 1
            if stat.S_ISLNK(entry.external_attr >> 16):
                if entry.file_size > 4096:
                    raise PipelineError("Oversized ZIP symlink")
                target = archive.read(entry).decode("utf-8")
                normalized = Path(os.path.normpath(str(Path(name).parent / target)))
                if Path(target).is_absolute() or not normalized.parts or normalized.parts[0] != "KeyDock.app":
                    raise PipelineError("Release ZIP symlink escapes the App")
        if not found_app:
            raise PipelineError("Release ZIP contains no KeyDock.app")


def unpack_release(directory, destination):
    manifest = verify_assets(directory)
    archive = Path(directory) / next(a["name"] for a in manifest["assets"] if a["name"].endswith(".zip"))
    run(["/usr/bin/ditto", "-x", "-k", archive, destination])
    app = Path(destination) / "KeyDock.app"
    facts = inspect_app(app)
    if facts["commit"] != manifest["source"]["commit"] or facts["release_version"] != manifest["version"] or facts["source_dirty"] or facts["safe_smoke"] or facts["code_signature"]["team_id"] != CONFIG["teamID"] or not facts["notarized"] or not facts["code_signature"]["hardened_runtime"]:
        raise PipelineError("Packaged App identity or trust differs from its release manifest")
    run(["/usr/sbin/spctl", "--assess", "--type", "execute", app], capture=True)
    return app


def verify_remote(repository, tag):
    with tempfile.TemporaryDirectory(prefix="keydock-release-check-") as temporary:
        run(["gh", "release", "download", tag, "--repo", repository, "--dir", temporary])
        manifest = verify_assets(temporary)
        if manifest["tag"] != tag:
            raise PipelineError("Remote release tag does not match the downloaded manifest")
        expected = run(["git", "rev-parse", tag + "^{commit}"], capture=True).strip()
        if manifest["source"]["commit"] != expected:
            raise PipelineError("Remote release source does not match its Git tag")
        verify_dmg(temporary, manifest)
        unpack_release(temporary, Path(temporary) / "unpacked")
    return manifest


def verify_dmg(directory, manifest):
    dmg = Path(directory) / next(a["name"] for a in manifest["assets"] if a["name"].endswith(".dmg"))
    run(["/usr/bin/codesign", "--verify", "--strict", dmg], capture=True)
    details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", dmg], capture_output=True, text=True, check=True).stderr
    if not re.search(r"^Authority=Developer ID Application:", details, flags=re.M) or not re.search(r"^TeamIdentifier=" + re.escape(CONFIG["teamID"]) + r"$", details, flags=re.M):
        raise PipelineError("DMG is not signed by the configured Developer ID team")
    run(["xcrun", "stapler", "validate", dmg], capture=True)
    run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg], capture=True)


def publish():
    identity = source_identity()
    manifest = verify_assets(DIST)
    if identity != manifest["source"]:
        raise PipelineError("Publishing checkout differs from the packaged source")
    repo = CONFIG["repository"]
    origin = run(["git", "remote", "get-url", "origin"], capture=True).strip().removesuffix(".git")
    if origin not in ("https://github.com/" + repo, "git@github.com:" + repo):
        raise PipelineError("origin is not the configured release repository")
    remote = run(["git", "ls-remote", "origin", "refs/heads/master", "refs/tags/" + manifest["tag"], "refs/tags/" + manifest["tag"] + "^{}"], capture=True)
    refs = {line.split()[1]: line.split()[0] for line in remote.splitlines()}
    if not refs.get("refs/heads/master") or refs.get("refs/tags/" + manifest["tag"] + "^{}", refs.get("refs/tags/" + manifest["tag"])) != identity["commit"]:
        raise PipelineError("Push the verified master and exact release tag before publishing")
    run(["git", "fetch", "--no-tags", "origin", "master"])
    run(["git", "merge-base", "--is-ancestor", identity["commit"], refs["refs/heads/master"]])
    tag = manifest["tag"]
    notes = ROOT / "docs/releases" / (tag + ".md")
    if not notes.is_file():
        raise PipelineError("Commit release notes before packaging")
    existing = subprocess.run(["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,isPrerelease,url"], capture_output=True, text=True)
    if existing.returncode == 0:
        info = json.loads(existing.stdout)
        if not info["isDraft"]:
            verify_remote(repo, tag)
            print(info["url"])
            return
        remote_info = json.loads(run(["gh", "api", "repos/" + repo + "/releases/tags/" + tag], capture=True))
        names = {asset["name"] for asset in remote_info["assets"]}
        local = {p.name: p for p in DIST.iterdir()}
        if not names.issubset(local):
            raise PipelineError("Existing draft contains unexpected assets; it was preserved")
        with tempfile.TemporaryDirectory(prefix="keydock-draft-check-") as temporary:
            for name in sorted(names):
                run(["gh", "release", "download", tag, "--repo", repo, "--pattern", name, "--dir", temporary])
                if sha256(Path(temporary) / name) != sha256(local[name]):
                    raise PipelineError("Existing draft asset has different bytes; it was preserved: " + name)
        missing = [local[name] for name in sorted(set(local) - names)]
        if missing:
            run(["gh", "release", "upload", tag, "--repo", repo] + missing)
    else:
        command = ["gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--latest=false", "--title", "KeyDock " + tag, "--notes-file", notes]
        if "-" in CONFIG["version"]:
            command += ["--prerelease"]
        run(command + sorted(DIST.iterdir()))
    verify_remote(repo, tag)
    if source_identity() != identity:
        raise PipelineError("Source changed before publication; the verified draft was preserved")
    run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest=false", "--prerelease=" + ("true" if "-" in CONFIG["version"] else "false")])
    verify_remote(repo, tag)
    print(run(["gh", "release", "view", tag, "--repo", repo, "--json", "url", "--jq", ".url"], capture=True).strip())


def install(app, destination=None, quit_running=False, dry_run=False, receipt=None):
    app = Path(app).expanduser().resolve(strict=True)
    facts = inspect_app(app)
    target = Path(destination).expanduser().absolute() if destination else (Path("/Applications/KeyDock.app") if facts["profile"] == "release" else Path.home() / "Applications/KeyDock Preview.app")
    receipt = Path(receipt).expanduser().absolute() if receipt else RUN_DIR / "install-receipt.json"
    command = [sys.executable, ROOT / "scripts/install-app.py", "--app", app, "--destination", target, "--receipt", receipt, "--helper", helper(), "--create-parents"]
    if quit_running:
        command += ["--quit-running"]
    if dry_run:
        command += ["--dry-run"]
    if facts["profile"] == "preview":
        command += ["--allow-unnotarized-preview"]
    run(command)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    p = sub.add_parser("check"); p.add_argument("--ci", action="store_true")
    p = sub.add_parser("build"); p.add_argument("--profile", choices=["release", "preview"], default="preview"); p.add_argument("--configuration", choices=["Release", "Debug"]); p.add_argument("--allow-dirty", action="store_true")
    p = sub.add_parser("package"); p.add_argument("--app", type=Path); p.add_argument("--notary-profile")
    sub.add_parser("publish")
    p = sub.add_parser("verify-release"); p.add_argument("--repo", default=CONFIG["repository"]); p.add_argument("--tag", default="v" + CONFIG["version"])
    p = sub.add_parser("verify-assets"); p.add_argument("directory", type=Path)
    p = sub.add_parser("qualify-install"); p.add_argument("--app", type=Path, default=BUILD / "preview/KeyDock Preview.app")
    p = sub.add_parser("install"); p.add_argument("--app", type=Path, required=True); p.add_argument("--destination", type=Path); p.add_argument("--quit-running", action="store_true"); p.add_argument("--dry-run", action="store_true"); p.add_argument("--receipt", type=Path)
    p = sub.add_parser("rollback"); p.add_argument("receipt", type=Path); p.add_argument("--dry-run", action="store_true"); p.add_argument("--quit-running", action="store_true")
    p = sub.add_parser("debug"); p.add_argument("--no-launch", action="store_true")
    p = sub.add_parser("release"); p.add_argument("--publish", action="store_true"); p.add_argument("--install", action="store_true")
    args = parser.parse_args()
    if args.command == "doctor":
        print(json.dumps({"source": source_identity(False), "platform": platform.system(), "architecture": platform.machine(), "version": CONFIG["version"],
                          "repository": CONFIG["repository"], "tools": {tool: shutil.which(tool) is not None for tool in ["xcrun", "xcodegen", "gh", "codesign", "hdiutil"]},
                          "notaryProfileConfigured": bool(os.environ.get("KEYDOCK_NOTARY_PROFILE"))}, indent=2))
    elif args.command == "check": check(args.ci)
    elif args.command == "build": build(args.profile, args.configuration, args.allow_dirty)
    elif args.command == "package": package(args.app, args.notary_profile)
    elif args.command == "publish": publish()
    elif args.command == "verify-release": print(json.dumps(verify_remote(args.repo, args.tag), indent=2))
    elif args.command == "verify-assets": print(json.dumps(verify_assets(args.directory), indent=2))
    elif args.command == "qualify-install": run([sys.executable, ROOT / "scripts/qualify-install.py", "--app", args.app.expanduser().resolve(), "--helper", helper()])
    elif args.command == "install": install(args.app, args.destination, args.quit_running, args.dry_run, args.receipt)
    elif args.command == "rollback":
        command = [sys.executable, ROOT / "scripts/install-app.py", "--rollback", args.receipt.expanduser().absolute(), "--helper", helper()]
        run(command + (["--dry-run"] if args.dry_run else []) + (["--quit-running"] if args.quit_running else []))
    elif args.command == "debug":
        path = install(build("preview", allow_dirty=True), quit_running=True)
        if not args.no_launch: run(["/usr/bin/open", "-a", path])
    elif args.command == "release":
        check()
        if not DIST.exists(): package(build("release"))
        else:
            if verify_assets(DIST)["source"] != source_identity():
                raise PipelineError("Existing release version differs from the current source")
        if args.install:
            with tempfile.TemporaryDirectory(prefix="keydock-install-release-") as temporary:
                install(unpack_release(DIST, temporary), quit_running=True)
        if args.publish: publish()


if __name__ == "__main__":
    try:
        main()
    except (PipelineError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
