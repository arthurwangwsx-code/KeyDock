#!/usr/bin/env python3
"""KeyDock统一工程入口：检查、调试、发行、安装、回退与GitHub资产复核。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

from keydock_common import CONFIG, ROOT, PipelineError, atomic_json, inspect_app, run, sha256, source_identity, validate_version, current_data_compatibility, app_data_compatibility
import release_quality as quality
import release_delivery as delivery

BUILD = ROOT / "build/pipeline"
DIST = ROOT / "build/releases" / CONFIG["version"]
RUN_DIR = ROOT / ".local/pipeline" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
TERMINAL_TIMING_SUITES = r"^(WorkbenchFeatureTests\.TerminalLifecycleTests|MacAdaptersTests\.TerminalHandoffAdapterTests)/"
MINIMUM_BUILD_FREE_BYTES = 2 * 1024 ** 3


def build_storage_status():
    free = shutil.disk_usage(ROOT).free
    return {"freeBytes": free, "minimumFreeBytes": MINIMUM_BUILD_FREE_BYTES, "ready": free >= MINIMUM_BUILD_FREE_BYTES}


def require_build_space():
    status = build_storage_status()
    if not status["ready"]:
        raise PipelineError("Build requires at least 2 GiB free; available %.2f GiB. Reclaim rebuildable caches before retrying." % (status["freeBytes"] / 1024 ** 3))


def stage(name, command, timeout=None):
    delivery.mkdir_durable(RUN_DIR)
    path = RUN_DIR / (name + ".log")
    started = time.monotonic()
    print("[%s] %s" % (name, path.relative_to(ROOT)), flush=True)
    with path.open("w") as stream:
        with delivery.cancellation_signals() as cancellation:
            process = subprocess.Popen([str(value) for value in command], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            def stop():
                cancellation["interruptible"] = False
                if process.poll() is not None: return
                # hdiutil只收口自有client，不能借进程组处理系统image helper。
                group = Path(str(command[0])).name not in ("hdiutil", "diskutil")
                if group: os.killpg(process.pid, signal.SIGTERM)
                else: process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if group: os.killpg(process.pid, signal.SIGKILL)
                    else: process.kill()
                    process.wait()
            try:
                cancellation["interruptible"] = True
                if cancellation["signal"] is not None: raise delivery.OperatorCancelled("Stage cancelled during child creation")
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                stop()
                exit_code = 124
            except BaseException as error:
                stop()
                stream.write("stage stopped: " + type(error).__name__ + "\n")
                exit_code = 128 + (cancellation["signal"] or signal.SIGINT)
            finally: cancellation["interruptible"] = False
    record = {"stage": name, "exitCode": exit_code, "seconds": round(time.monotonic() - started, 3)}
    atomic_json(RUN_DIR / (name + ".json"), record)
    if exit_code:
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


def desktop_fixture():
    # 独立bundle和全新目录，不替换用户应用或复用生产数据。
    parent = Path.home() / "Applications/KeyDock Acceptance Fixtures"
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="synthetic-", dir=parent))
    app = folder / "KeyDock Desktop Fixture.app"
    executable = app / "Contents/MacOS/KeyDockDesktopFixture"
    executable.parent.mkdir(parents=True)
    info = {"CFBundleIdentifier": "com.arthurwangwsx.KeyDock.DesktopFixture", "CFBundleName": "KeyDock Desktop Fixture",
            "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    stage("desktop-fixture-compile", ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                                       "-target", "arm64-apple-macos14.0", ROOT / "Tools/KeyDockDesktopFixture/main.swift", "-o", executable])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"], app])
    run(["/usr/bin/codesign", "--verify", "--strict", app])
    receipt = {"app": str(app), "bundleIdentifier": info["CFBundleIdentifier"], "source": source_identity(False),
               "binarySHA256": sha256(executable), "syntheticOnly": True, "launched": False}
    atomic_json(RUN_DIR / "desktop-fixture.json", receipt)
    print(json.dumps(receipt, indent=2))
    return app


def check(ci=False):
    source = source_identity(False)
    attempt = quality.begin_check(RUN_DIR, source, ci)
    try:
        require_build_space()
        _check(ci, source, quality.host_facts())
    except BaseException:
        quality.finish_check(attempt, False)
        raise
    quality.finish_check(attempt, True)


def _check(ci, source, host):
    if not ci:
        stage("branch", [ROOT / "scripts/check-branch-policy.sh", "--allow-master"])
    stage("documents", [sys.executable, ROOT / "scripts/validate-docs.py"])
    stage("localizations", [sys.executable, ROOT / "scripts/update-localizations.py", "--check"])
    stage("pipeline-tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"])
    # Swift Testing默认并行套件；时限合同在独立进程验证，不能被其余主线程负载污染。
    # 两个互补阶段都强制成功，既不删除用例，也不通过失败后重试掩盖问题。
    # 显式关闭套件并发；CLI默认值并未让Swift Testing套件串行，进程夹具会争用MainActor。
    tests = ["xcrun", "swift", "test", "--jobs", "2", "--no-parallel"]
    excluded = TERMINAL_TIMING_SUITES + "|" + quality.OCR_FILTER
    require_swift_tests(stage("swift-tests", tests + ["--skip", excluded]))
    require_swift_tests(stage("swift-terminal-lifecycle", tests + ["--filter", TERMINAL_TIMING_SUITES]))
    if not ci:
        require_swift_tests(stage(quality.OCR_STAGE, tests + ["--filter", quality.OCR_FILTER], timeout=180))
    stage("swift-inventory", ["xcrun", "swift", "test", "list", "--skip-build"])
    helper()
    if source_identity(False) != source:
        raise PipelineError("Source changed while checking; no qualification was issued")
    quality.record_check(RUN_DIR, source, ci, TERMINAL_TIMING_SUITES, host)


def require_swift_tests(log):
    counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", Path(log).read_text(errors="replace"))
    if not counts or sum(map(int, counts)) == 0:
        raise PipelineError("Swift test stage ran no cases; check its selector and log: " + str(log))


def build(profile="preview", configuration=None, allow_dirty=False, identity=None):
    if profile not in ("release", "preview"):
        raise PipelineError("Use the independent desktop-review-build pipeline for local Review pairs")
    if platform.system() != "Darwin" or platform.machine() != CONFIG["architecture"]:
        raise PipelineError("This pipeline currently qualifies macOS arm64 only")
    require_build_space()
    source = source_identity(require_clean=not allow_dirty)
    qualification = quality.require_local(source, current_host=True) if profile == "release" else None
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
    if qualification is not None and qualification["host"] != quality.host_facts():
        raise PipelineError("Build environment changed after qualification")
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
    metadata = {"schemaVersion": 1, "version": CONFIG["version"], "buildNumber": CONFIG["buildNumber"], "profile": profile, "configuration": build_configuration,
                "source": source, "architecture": "arm64", "xcode": xcode.splitlines()[0],
                "swift": run(["xcrun", "swift", "--version"], capture=True).splitlines()[0]}
    metadata["dataCompatibility"] = current_data_compatibility()
    if qualification is not None: metadata["qualificationSHA256"] = quality.digest(qualification)
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


def notarize(path, profile, name, binding):
    return delivery.notarize(path, profile, Path(path).parent / (name + ".json"), binding)


def package(app=None, profile=None, resume_work=None):
    if app is not None:
        if inspect_app(app)["profile"] != "release":
            raise PipelineError("Only production Release Apps can be packaged for distribution")
    with delivery.exclusive(ROOT / ".local/release-delivery/package.lock"):
        return package_candidate(app, profile, resume_work)


def package_candidate(app=None, profile=None, resume_work=None):
    identity = source_identity()
    qualification = quality.require_local(identity)
    if DIST.exists():
        manifest = verify_assets(DIST)
        if manifest["source"]["commit"] != identity["commit"] or manifest["version"] != CONFIG["version"] or manifest.get("qualificationSHA256") != quality.digest(qualification):
            raise PipelineError("This release version already has different source; bump release/config.json")
        quality.core_ci(identity, manifest["coreCI"]["id"])
        print("Reused verified immutable package: " + str(DIST), flush=True)
        return DIST
    registry = ROOT / ".local/release-delivery/candidates" / (CONFIG["version"] + ".json")
    work = None
    if registry.exists():
        registered = delivery.read_receipt(registry)
        delivery.require_schema(registered)
        if registered.get("source") != identity:
            raise PipelineError("This version has a candidate from another source; preserve it and bump the version")
        work = Path(registered["work"])
        if resume_work and Path(resume_work).absolute() != work:
            raise PipelineError("Resume path differs from the registered candidate")
    elif resume_work:
        work = Path(resume_work).absolute()
    else:
        # 索引缺失时仅发现并拒绝遗留候选，不按时间或名称认领／重新提交。
        known = list((ROOT / ".local/pipeline").glob("*/package/candidate.json"))
        if len(known) > 2048: raise PipelineError("Candidate discovery exceeds its budget; use an explicit resume path")
        for path in known:
            delivery.require_candidate(path.parent, ROOT / ".local/pipeline")
            previous = delivery.read_receipt(path)
            delivery.require_schema(previous)
            if previous.get("version") == CONFIG["version"]:
                raise PipelineError("An unindexed candidate was retained; resume its explicit work path")
    if work:
        delivery.require_candidate(work, ROOT / ".local/pipeline")
        candidate = delivery.read_receipt(work / "candidate.json")
        delivery.require_schema(candidate)
        if (candidate.get("source") != identity or candidate.get("version") != CONFIG["version"] or
                candidate.get("buildNumber") != CONFIG["buildNumber"] or candidate.get("teamID") != CONFIG["teamID"] or
                candidate.get("qualificationSHA256") != quality.digest(qualification)):
            raise PipelineError("Frozen candidate no longer matches the release source, signing team or qualification")
        app = work / "app/KeyDock.app"
        delivery.require_candidate(app.parent, ROOT / ".local/pipeline")
        facts = inspect_app(app)
        compare_unstapled_app(facts, candidate["appFacts"])
        core_ci = quality.core_ci(identity, candidate["coreCI"]["id"])
        if not registry.exists():
            delivery.durable_json(registry, {"schemaVersion": 1, "source": identity, "work": str(work)})
    else:
        app = Path(app or BUILD / "release/KeyDock.app")
        facts = inspect_app(app)
    if facts.get("qualification_sha256") != quality.digest(qualification):
        raise PipelineError("Release App was not built with the current native OCR qualification")
    if facts["profile"] != "release" or facts["safe_smoke"] or facts["source_dirty"] or facts["commit"] != identity["commit"]:
        raise PipelineError("Package only the current clean-source regular Release App")
    if facts["release_version"] != CONFIG["version"] or facts["code_signature"]["kind"] != "developer-id" or facts["code_signature"]["team_id"] != CONFIG["teamID"] or not facts["code_signature"]["hardened_runtime"]:
        raise PipelineError("Release identity does not match the configured version, team or runtime")
    profile = profile or os.environ.get("KEYDOCK_NOTARY_PROFILE")
    if not profile:
        raise PipelineError("Set KEYDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile; credentials stay in Keychain")
    if work is None:
        core_ci = quality.core_ci(identity)
        work = RUN_DIR / "package"
        delivery.mkdir_durable(work)
        staged = work / "app/KeyDock.app"
        delivery.mkdir_durable(staged.parent)
        stage("copy-release-app", ["/usr/bin/ditto", app, staged])
        copied = inspect_app(staged)
        compare_app_payloads(copied, facts)
        app = staged
        candidate = {"schemaVersion": 1, "source": identity, "version": CONFIG["version"], "buildNumber": CONFIG["buildNumber"],
                     "teamID": CONFIG["teamID"], "qualificationSHA256": quality.digest(qualification), "coreCI": core_ci, "appFacts": copied}
        delivery.durable_json(work / "candidate.json", candidate)
        delivery.durable_json(registry, {"schemaVersion": 1, "source": identity, "work": str(work)})
    print("Frozen package candidate: " + str(work), flush=True)
    files = delivery.FrozenFiles(work)
    binding = {"source": identity, "version": CONFIG["version"], "teamID": CONFIG["teamID"],
               "qualificationSHA256": quality.digest(qualification), "coreCI": core_ci["id"]}
    payload = work / "inputs/notary-app.zip"
    delivery.mkdir_durable(payload.parent)
    delivery.require_candidate(payload.parent, ROOT / ".local/pipeline")
    files.file("app-input", payload, lambda: stage("archive-app-input", ["/usr/bin/ditto", "-c", "-k", "--keepParent", app, payload]),
               rebuild=not os.path.lexists(payload.parent / "notary-app.json"))
    app_submission = notarize(payload, profile, "notary-app", dict(binding, role="app"))
    stage("staple-app", ["xcrun", "stapler", "staple", app])
    stage("validate-app-ticket", ["xcrun", "stapler", "validate", app])
    stage("gatekeeper-app", ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])
    facts = inspect_app(app)
    compare_unstapled_app(facts, candidate["appFacts"])
    app_receipt = work / "stapled-app.json"
    if app_receipt.exists(): compare_app_payloads(facts, delivery.read_receipt(app_receipt))
    else: delivery.durable_json(app_receipt, facts)
    assets = work / "assets"
    delivery.mkdir_durable(assets)
    delivery.require_candidate(assets, ROOT / ".local/pipeline")
    stem = "KeyDock-" + CONFIG["version"] + "-macos-arm64"
    zip_path = assets / (stem + ".zip")
    files.file("zip", zip_path, lambda: stage("archive-release-zip", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path]), rebuild=True)
    image_root = work / "image"
    image_receipt = work / "image-complete.json"
    dmg_request = work / "inputs/notary-dmg.json"
    if not image_receipt.exists():
        if os.path.lexists(dmg_request): raise PipelineError("Submitted candidate has no confirmed image contents; preserve its input")
        if image_root.exists() or image_root.is_symlink():
            delivery.require_candidate(image_root, ROOT / ".local/pipeline")
            delivery.durable_rename(image_root, work / ("incomplete-image-" + str(uuid.uuid4())))
        delivery.mkdir_durable(image_root)
        stage("copy-image-app", ["/usr/bin/ditto", app, image_root / "KeyDock.app"])
        os.symlink("/Applications", image_root / "Applications")
        shutil.copyfile(ROOT / "release/INSTALL.txt", image_root / "INSTALL.txt")
    delivery.require_candidate(image_root, ROOT / ".local/pipeline")
    if ({p.name for p in image_root.iterdir()} != {"KeyDock.app", "Applications", "INSTALL.txt"} or
            not (image_root / "Applications").is_symlink() or os.readlink(image_root / "Applications") != "/Applications" or
            (image_root / "INSTALL.txt").is_symlink() or sha256(image_root / "INSTALL.txt") != sha256(ROOT / "release/INSTALL.txt")):
        raise PipelineError("Frozen DMG contents changed or were never completed")
    compare_app_payloads(inspect_app(image_root / "KeyDock.app"), facts)
    image_facts = {"schemaVersion": 1, "appBundleSHA256": facts["bundle_sha256"], "installSHA256": sha256(ROOT / "release/INSTALL.txt")}
    if image_receipt.exists():
        if delivery.read_receipt(image_receipt) != image_facts: raise PipelineError("Confirmed image contents changed")
    else: delivery.durable_json(image_receipt, image_facts)
    dmg = assets / (stem + ".dmg")
    creator = work / "creator/generated.dmg"
    delivery.mkdir_durable(creator.parent)
    delivery.require_candidate(creator.parent, ROOT / ".local/pipeline")
    allow_dmg_rebuild = not os.path.lexists(dmg_request)
    files.file("creator", creator, lambda: stage("dmg", ["/usr/bin/hdiutil", "create", "-volname", "KeyDock", "-srcfolder", image_root, "-format", "UDZO", creator]), rebuild=allow_dmg_rebuild)
    # creator可能仍被系统helper持有。消费独立inode；不杀系统helper、不强制detach。
    signed_input = work / "inputs" / (stem + ".dmg")
    def prepare_dmg():
        copied = delivery.copy_payload(creator, signed_input)
        if copied["source"] != delivery.read_receipt(work / "creator-file.json"):
            raise PipelineError("Creator image changed before consumption; both files were retained")
        delivery.durable_json(work / "creator-copy.json", copied)
        stage("verify-generated-dmg", ["/usr/bin/hdiutil", "verify", signed_input], timeout=120)
        stage("sign-dmg", ["/usr/bin/codesign", "--sign", CONFIG["signingIdentity"], "--timestamp", signed_input], timeout=120)
        stage("verify-signed-dmg", ["/usr/bin/codesign", "--verify", "--strict", signed_input], timeout=60)
    files.file("dmg-input", signed_input, prepare_dmg, rebuild=allow_dmg_rebuild)
    dmg_submission = notarize(signed_input, profile, "notary-dmg", dict(binding, role="dmg"))
    def finish_dmg():
        delivery.copy_payload(signed_input, dmg)
        stage("staple-dmg", ["xcrun", "stapler", "staple", dmg], timeout=120)
        stage("validate-dmg-ticket", ["xcrun", "stapler", "validate", dmg], timeout=60)
        stage("gatekeeper-dmg", ["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg], timeout=60)
    files.file("final-dmg", dmg, finish_dmg, rebuild=True)
    manifest = {"schemaVersion": 2, "version": CONFIG["version"], "tag": "v" + CONFIG["version"], "source": identity,
                "architecture": "arm64", "minimumTarget": "14.0", "qualifiedHost": "macOS " + qualification["host"]["osVersion"] + " arm64",
                "qualification": qualification, "qualificationSHA256": quality.digest(qualification), "coreCI": core_ci, "cloudOCR": "NOT_QUALIFIED",
                "bundleIdentifier": facts["bundle_id"], "bundleVersion": facts["version"], "buildNumber": facts["build_number"],
                "signature": facts["code_signature"], "notarized": facts["notarized"], "safeSmoke": False,
                "dataCompatibility": facts["data_compatibility"],
                "notarizationSubmissions": {"app": app_submission, "dmg": dmg_submission},
                "productAcceptance": "PARTIAL; see release notes for physical-device and external-model limits",
                "assets": [{"name": p.name, "bytes": p.stat().st_size, "sha256": sha256(p)} for p in (zip_path, dmg)]}
    atomic_json(assets / "release-manifest.json", manifest)
    (assets / "SHA256SUMS.txt").write_text("".join(sha256(p) + "  " + p.name + "\n" for p in sorted(assets.iterdir()) if p.is_file()))
    verify_assets(assets)
    verify_dmg(assets, manifest, expected_app=facts)
    if source_identity() != identity:
        raise PipelineError("Source changed during notarization; verified files were kept in the local staging directory")
    if quality.digest(quality.require_local(identity)) != manifest["qualificationSHA256"]:
        raise PipelineError("Qualification changed during packaging")
    delivery.durable_rename(assets, DIST)
    print("Packaged: " + str(DIST), flush=True)
    return DIST


def compare_unstapled_app(actual, expected):
    fields = ("bundle_id", "profile", "safe_smoke", "source_dirty", "commit", "release_version", "build_number", "architecture",
              "qualification_sha256", "binary_sha256", "code_signature", "data_compatibility")
    if any(key not in expected or actual.get(key) != expected[key] for key in fields):
        raise PipelineError("Staged App differs from its original signed build")


def verify_assets(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "release-manifest.json").read_text())
    legacy = manifest.get("schemaVersion") == 1 and manifest.get("version") in ("0.1.0-alpha.1", "0.1.0-alpha.2")
    if (manifest.get("schemaVersion") != 2 and not legacy) or manifest.get("safeSmoke") is not False or not manifest.get("notarized"):
        raise PipelineError("Release manifest does not describe a notarized regular App")
    if manifest.get("tag") != "v" + manifest.get("version", "") or manifest.get("source", {}).get("dirty"):
        raise PipelineError("Release version or source identity is inconsistent")
    if manifest.get("architecture") != "arm64" or manifest.get("bundleIdentifier") != CONFIG["bundleIdentifier"] or manifest.get("signature", {}).get("kind") != "developer-id" or manifest.get("signature", {}).get("team_id") != CONFIG["teamID"] or manifest.get("signature", {}).get("hardened_runtime") is not True:
        raise PipelineError("Release identity, architecture or signing team is not the configured application")
    validate_version(manifest["version"])
    app_data_compatibility(manifest, manifest["version"])
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("source", {}).get("commit", "")):
        raise PipelineError("Release has no full source commit")
    if not legacy:
        quality.validate_public(manifest.get("qualification", {}), manifest["source"], manifest["version"], manifest.get("buildNumber"))
        if manifest.get("qualificationSHA256") != quality.digest(manifest["qualification"]) or manifest.get("cloudOCR") != "NOT_QUALIFIED":
            raise PipelineError("Release qualification digest or environment scope is inconsistent")
        quality.validate_ci(manifest.get("coreCI", {}), manifest["source"])
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
    if facts["data_compatibility"] != app_data_compatibility(manifest, manifest["version"]):
        raise PipelineError("Packaged App data reader differs from its release manifest")
    if manifest.get("qualificationSHA256") and facts.get("qualification_sha256") != manifest["qualificationSHA256"]:
        raise PipelineError("Packaged App qualification differs from its manifest")
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
        if "qualification" in manifest:
            quality.verify_source(manifest["qualification"])
            quality.core_ci(manifest["source"], manifest["coreCI"]["id"])
        app = unpack_release(temporary, Path(temporary) / "unpacked")
        verify_dmg(temporary, manifest, expected_app=inspect_app(app))
    return manifest


def verify_dmg(directory, manifest, expected_app=None):
    dmg = Path(directory) / next(a["name"] for a in manifest["assets"] if a["name"].endswith(".dmg"))
    run(["/usr/bin/codesign", "--verify", "--strict", dmg], capture=True)
    details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", dmg], capture_output=True, text=True, check=True).stderr
    if not re.search(r"^Authority=Developer ID Application:", details, flags=re.M) or not re.search(r"^TeamIdentifier=" + re.escape(CONFIG["teamID"]) + r"$", details, flags=re.M):
        raise PipelineError("DMG is not signed by the configured Developer ID team")
    run(["xcrun", "stapler", "validate", dmg], capture=True)
    run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg], capture=True)
    if expected_app is None:
        with tempfile.TemporaryDirectory(prefix="keydock-zip-identity-") as temporary:
            app = unpack_release(directory, temporary)
            verify_dmg_contents(dmg, inspect_app(app))
    else: verify_dmg_contents(dmg, expected_app)


def compare_app_payloads(actual, expected):
    fields = ("bundle_id", "profile", "safe_smoke", "source_dirty", "commit", "release_version", "build_number", "architecture", "qualification_sha256", "bundle_sha256", "binary_sha256", "code_signature", "notarized", "data_compatibility")
    if any(field not in actual or field not in expected or actual[field] != expected[field] for field in fields):
        raise PipelineError("DMG App differs from the qualified ZIP App")


def verify_dmg_contents(dmg, expected_app):
    # 只读挂载到独占目录；从不选择用户现有卷，也不force detach。
    directory = Path(tempfile.mkdtemp(prefix="keydock-dmg-identity-")).resolve()
    mount = directory / "volume"; mount.mkdir()
    try:
        data = run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, "-plist", dmg], capture=True)
        entities = plistlib.loads(data.encode())["system-entities"]
        owned = [item for item in entities if item.get("mount-point") and Path(item["mount-point"]).resolve() == mount.resolve()]
        if len(owned) != 1 or not re.fullmatch(r"/dev/disk\d+(?:s\d+)*", owned[0].get("dev-entry", "")) or not mount.is_mount():
            raise PipelineError("Image did not mount at the owned verification directory")
        actual = inspect_app(mount / "KeyDock.app")
        compare_app_payloads(actual, expected_app)
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", mount / "KeyDock.app"], capture=True)
    finally:
        if mount.is_mount():
            result = subprocess.run(["/usr/bin/hdiutil", "detach", mount], capture_output=True, text=True)
            if result.returncode or mount.is_mount():
                raise PipelineError("Read-only verification volume retained for normal detach: " + str(mount))
        shutil.rmtree(directory)


def publish():
    identity = source_identity()
    manifest = verify_assets(DIST)
    if identity != manifest["source"]:
        raise PipelineError("Publishing checkout differs from the packaged source")
    qualification = quality.require_local(identity)
    if manifest["version"] != CONFIG["version"] or manifest.get("qualificationSHA256") != quality.digest(qualification):
        raise PipelineError("Publishing requires the packaged same-source native qualification")
    quality.core_ci(identity, manifest["coreCI"]["id"])
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
    if quality.digest(quality.require_local(identity)) != manifest["qualificationSHA256"]:
        raise PipelineError("Native qualification is no longer current; the draft was preserved")
    quality.core_ci(identity, manifest["coreCI"]["id"])
    run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest=false", "--prerelease=" + ("true" if "-" in CONFIG["version"] else "false")])
    verify_remote(repo, tag)
    print(run(["gh", "release", "view", tag, "--repo", repo, "--json", "url", "--jq", ".url"], capture=True).strip())


def install(app, destination=None, quit_running=False, dry_run=False, receipt=None):
    app = Path(app).expanduser().resolve(strict=True)
    facts = inspect_app(app)
    if facts["profile"] == "release" and facts.get("release_version") not in ("0.1.0-alpha.1", "0.1.0-alpha.2") and not re.fullmatch(r"[0-9a-f]{64}", facts.get("qualification_sha256") or ""):
        raise PipelineError("Regular App has no native qualification; use a verified packaged release")
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


def install_release():
    manifest = verify_assets(DIST)
    if manifest["version"] != CONFIG["version"]:
        raise PipelineError("The packaged release is not the configured installation version")
    quality.verify_source(manifest["qualification"])
    with tempfile.TemporaryDirectory(prefix="keydock-install-release-") as temporary:
        app = unpack_release(DIST, temporary)
        verify_dmg(DIST, manifest, expected_app=inspect_app(app))
        return install(app, quit_running=True)


def mcp_interop(environment, run_name, scenario):
    # 与日常检查串行执行；环境需先显式准备，绝不借用个人已有服务／凭据。
    stage("mcp-interop-probe", ["xcrun", "swift", "build", "--jobs", "2", "--product", "KeyDockMCPInteropProbe"])
    binaries = Path(run(["xcrun", "swift", "build", "--show-bin-path"], capture=True).strip())
    stage("mcp-interop-" + scenario, [sys.executable, ROOT / "scripts/run-mcp-interop.py",
          "--environment", environment, "--probe", binaries / "KeyDockMCPInteropProbe",
          "--run-name", run_name, "--scenario", scenario], timeout=300)


def performance(mode, app=None, pid=None, duration=1800, interval=5, condition="declared-idle-hidden"):
    if mode not in {"query", "resident", "probe-check"}:
        raise PipelineError("Unknown performance mode")
    if platform.system() != "Darwin" or platform.machine() != CONFIG["architecture"]:
        raise PipelineError("Performance sampling currently qualifies macOS arm64 only")
    if mode != "resident" and (app is not None or pid is not None):
        raise PipelineError("--app and --pid require resident mode")
    if mode == "resident" and (app is None or type(pid) is not int or pid <= 1 or not math.isfinite(duration) or not math.isfinite(interval)
                              or not 1 <= duration <= 28800 or not 1 <= interval <= 60):
        raise PipelineError("Resident sampling requires --app, --pid > 1, duration 1...28800 and interval 1...60")
    require_build_space()
    xcode = run(["xcrun", "xcodebuild", "-version"], capture=True).strip()
    if not xcode.startswith("Xcode " + CONFIG["xcodeVersion"] + "\n"):
        raise PipelineError("Select Xcode " + CONFIG["xcodeVersion"] + " before performance sampling")
    product = "KeyDockDiagnostics" if mode == "query" else "KeyDockProcessProbe"
    stage("performance-build-" + mode, ["xcrun", "swift", "build", "--jobs", "2", "--configuration", "release", "--product", product])
    binary_directory = Path(run(["xcrun", "swift", "build", "--configuration", "release", "--show-bin-path"], capture=True).strip())
    command = [sys.executable, ROOT / "scripts/keydock_performance.py", "--mode", mode, "--probe", binary_directory / product,
               "--output", RUN_DIR / "performance"]
    if mode == "resident":
        command += ["--app", app, "--pid", str(pid), "--duration-seconds", str(duration), "--interval-seconds", str(interval), "--condition", condition]
    stage("performance-" + mode, command, timeout=None if mode == "resident" else 90)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    p = sub.add_parser("performance")
    p.add_argument("--mode", choices=["query", "resident", "probe-check"], default="query")
    p.add_argument("--app", type=Path); p.add_argument("--pid", type=int)
    p.add_argument("--duration-seconds", type=float, default=1800); p.add_argument("--interval-seconds", type=float, default=5)
    p.add_argument("--condition", choices=["declared-idle-hidden", "synthetic-interaction", "recovery-idle"], default="declared-idle-hidden")
    p = sub.add_parser("check"); p.add_argument("--ci", action="store_true")
    p = sub.add_parser("build"); p.add_argument("--profile", choices=["release", "preview"], default="preview"); p.add_argument("--configuration", choices=["Release", "Debug"]); p.add_argument("--allow-dirty", action="store_true")
    p = sub.add_parser("package"); p.add_argument("--app", type=Path); p.add_argument("--notary-profile"); p.add_argument("--resume-work", type=Path)
    p = sub.add_parser("notary-status"); p.add_argument("--receipt", type=Path, required=True); p.add_argument("--notary-profile"); p.add_argument("--submission-id")
    sub.add_parser("publish")
    sub.add_parser("install-release")
    p = sub.add_parser("verify-release"); p.add_argument("--repo", default=CONFIG["repository"]); p.add_argument("--tag", default="v" + CONFIG["version"])
    p = sub.add_parser("verify-assets"); p.add_argument("directory", type=Path)
    p = sub.add_parser("qualify-install"); p.add_argument("--app", type=Path, default=BUILD / "preview/KeyDock Preview.app")
    p = sub.add_parser("native-review"); p.add_argument("--app", type=Path, default=BUILD / "preview/KeyDock Preview.app"); p.add_argument("--fixture", type=Path)
    p.add_argument("--task-views", nargs=2, metavar=("FIRST", "SECOND"))
    p = sub.add_parser("install"); p.add_argument("--app", type=Path, required=True); p.add_argument("--destination", type=Path); p.add_argument("--quit-running", action="store_true"); p.add_argument("--dry-run", action="store_true"); p.add_argument("--receipt", type=Path)
    p = sub.add_parser("rollback"); p.add_argument("receipt", type=Path); p.add_argument("--dry-run", action="store_true"); p.add_argument("--quit-running", action="store_true")
    p = sub.add_parser("debug"); p.add_argument("--no-launch", action="store_true")
    sub.add_parser("desktop-fixture")
    sub.add_parser("desktop-review-build")
    p = sub.add_parser("desktop-review"); p.add_argument("--pair", type=Path, default=ROOT / "build/pipeline/desktop-review/pair"); p.add_argument("--reuse-root", type=Path)
    for command in ("desktop-review-status", "desktop-review-stop"):
        p = sub.add_parser(command); p.add_argument("--receipt", type=Path, required=True)
        if command == "desktop-review-stop": p.add_argument("--review-only", action="store_true")
    p = sub.add_parser("prepare-mcp-interop"); p.add_argument("--python", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("mcp-interop"); p.add_argument("--environment", type=Path, required=True); p.add_argument("--run-name", required=True); p.add_argument("--scenario", choices=["time", "sdk-lifecycle"], default="time")
    p = sub.add_parser("release"); p.add_argument("--publish", action="store_true"); p.add_argument("--install", action="store_true")
    args = parser.parse_args()
    if args.command == "doctor":
        print(json.dumps({"source": source_identity(False), "platform": platform.system(), "architecture": platform.machine(), "version": CONFIG["version"],
                          "repository": CONFIG["repository"], "tools": {tool: shutil.which(tool) is not None for tool in ["xcrun", "xcodegen", "gh", "codesign", "hdiutil"]},
                          "notaryProfileConfigured": bool(os.environ.get("KEYDOCK_NOTARY_PROFILE")), "buildStorage": build_storage_status()}, indent=2))
    elif args.command == "performance": performance(args.mode, args.app, args.pid, args.duration_seconds, args.interval_seconds, args.condition)
    elif args.command == "desktop-fixture": desktop_fixture()
    elif args.command == "desktop-review-build":
        import desktop_review
        desktop_review.build_pair(stage)
    elif args.command == "desktop-review":
        import desktop_review
        desktop_review.launch(args.pair, args.reuse_root)
    elif args.command in ("desktop-review-status", "desktop-review-stop"):
        import desktop_review
        desktop_review.status(args.receipt, args.command == "desktop-review-stop", getattr(args, "review_only", False))
    elif args.command == "prepare-mcp-interop":
        stage("mcp-interop-prepare", [sys.executable, ROOT / "scripts/prepare-mcp-interop.py", "--python", args.python, "--output", args.output], timeout=900)
    elif args.command == "mcp-interop": mcp_interop(args.environment, args.run_name, args.scenario)
    elif args.command == "check": check(args.ci)
    elif args.command == "build": build(args.profile, args.configuration, args.allow_dirty)
    elif args.command == "package": package(args.app, args.notary_profile, args.resume_work)
    elif args.command == "notary-status":
        profile = args.notary_profile or os.environ.get("KEYDOCK_NOTARY_PROFILE")
        if not profile: raise PipelineError("Provide an existing notarytool Keychain profile")
        receipt = args.receipt.absolute()
        delivery.require_candidate(receipt.parent.parent, ROOT / ".local/pipeline")
        delivery.require_candidate(receipt.parent, ROOT / ".local/pipeline")
        registered = delivery.read_receipt(ROOT / ".local/release-delivery/candidates" / (CONFIG["version"] + ".json"))
        delivery.require_schema(registered)
        if registered.get("work") != str(receipt.parent.parent) or receipt.parent.name != "inputs":
            raise PipelineError("Status receipt is not inside the registered candidate")
        state = delivery.read_receipt(receipt)
        delivery.validate_request(state, receipt)
        identity = source_identity()
        qualification = quality.require_local(identity)
        role = state.get("binding", {}).get("role")
        payload_name = "notary-app.zip" if role == "app" else "KeyDock-" + CONFIG["version"] + "-macos-arm64.dmg"
        if receipt.name != "notary-" + str(role) + ".json" or state.get("payload", {}).get("path") != str(receipt.parent / payload_name):
            raise PipelineError("Status receipt does not name its frozen role input")
        delivery.preflight_request(receipt)
        expected = {"source": identity, "version": CONFIG["version"], "teamID": CONFIG["teamID"], "role": role,
                    "qualificationSHA256": quality.digest(qualification), "coreCI": state["binding"]["coreCI"]}
        quality.core_ci(identity, expected["coreCI"])
        print(delivery.query_request(receipt, profile, expected_binding=expected, attach_id=args.submission_id))
    elif args.command == "publish": publish()
    elif args.command == "install-release": install_release()
    elif args.command == "verify-release": print(json.dumps(verify_remote(args.repo, args.tag), indent=2))
    elif args.command == "verify-assets": print(json.dumps(verify_assets(args.directory), indent=2))
    elif args.command == "qualify-install": run([sys.executable, ROOT / "scripts/qualify-install.py", "--app", args.app.expanduser().resolve(), "--helper", helper()])
    elif args.command == "native-review":
        command = [sys.executable, ROOT / "scripts/native-review.py", "--app", args.app.expanduser().resolve()]
        if args.fixture is not None: command += ["--fixture", args.fixture.expanduser().absolute()]
        if args.task_views: command += ["--task-views", *args.task_views]
        run(command)
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
        else: package()
        if args.install:
            with tempfile.TemporaryDirectory(prefix="keydock-install-release-") as temporary:
                install(unpack_release(DIST, temporary), quit_running=True)
        if args.publish: publish()


def run_cli():
    try:
        main()
        return 0
    except (PipelineError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        from build_storage_gate import entry
        guarded = entry(sys.argv[1:], ROOT)
        sys.exit(subprocess.call(guarded) if guarded is not None else run_cli())
    except (OSError, RuntimeError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
