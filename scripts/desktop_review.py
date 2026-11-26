"""独立本地Review配对流水线；不进入生产安装或发行profile白名单。"""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import time
import uuid
import release_delivery as delivery

from keydock_common import ROOT, CONFIG, PipelineError, atomic_json, run, sha256, source_identity, tree_digest, validate_version

REVIEW_ID = "com.arthurwangwsx.KeyDock.desktopreview"
FIXTURE_ID = REVIEW_ID + ".fixture"
PARENT = ROOT / ".local/desktop-review"
PAIR = ROOT / "build/pipeline/desktop-review/pair"
HELPER = ROOT / "build/pipeline/tools/KeyDockReviewLifecycle"


def real_ancestors(path):
    path = Path(path)
    if not path.is_absolute(): raise PipelineError("Review output must be absolute")
    current = Path(path.anchor)
    for name in path.parts[1:]:
        current /= name
        try: info = current.lstat()
        except FileNotFoundError: continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise PipelineError("Review output has a symlink or non-directory ancestor")


def durable_json(path, value):
    private_directory(Path(path).parent)
    atomic_json(path, value)
    fd = os.open(Path(path).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def private_directory(path, create=False):
    path = Path(path)
    if create:
        real_ancestors(path)
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise PipelineError("Review path must not traverse symbolic links")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PipelineError("Review directory must be private and owned")
    return path


def read_private(path, limit=65536):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > limit:
            raise PipelineError("Review receipt must be a bounded private owned file")
        return json.loads(os.read(fd, limit + 1))
    finally: os.close(fd)


@contextmanager
def launcher_lock():
    private_directory(PARENT, create=True)
    fd = os.open(PARENT / "launcher.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise PipelineError("Review launcher lock is not private and owned")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally: os.close(fd)


def lifecycle(role, operation="probe", identity=None):
    args = [HELPER, operation, role["bundleID"], role["path"]]
    if identity is not None: args += [str(identity["pid"]), repr(identity["birth"])]
    value = json.loads(run(args, capture=True))
    if not isinstance(value, list) or len(value) > 1: raise PipelineError("Review instance identity is ambiguous")
    for item in value:
        if (set(item) != {"pid", "birth", "bundleID", "path", "executablePath"} or
                type(item["pid"]) is not int or item["pid"] <= 1 or
                item["bundleID"] != role["bundleID"] or item["path"] != role["path"] or
                item["executablePath"] != role["executablePath"] or
                type(item["birth"]) not in (float, int) or not 0 < item["birth"] < float("inf")):
            raise PipelineError("Review process identity could not be confirmed")
    return value


def inspect_role(path, bundle_id, executable, profile, source):
    path = Path(path)
    if path.resolve(strict=True) != path or path.suffix != ".app": raise PipelineError("Review App path changed")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    metadata = json.loads((path / "Contents/Resources/BuildInfo.json").read_bytes())
    if (info.get("CFBundleIdentifier") != bundle_id or info.get("CFBundleExecutable") != executable or
            info.get("KeyDockSafeSmoke") is not True or info.get("KeyDockGitCommit") != source["commit"] or
            metadata.get("source") != source or source.get("dirty") is not False or metadata.get("profile") != profile or
            metadata.get("architecture") != "arm64" or metadata.get("version") != info.get("KeyDockReleaseVersion") or
            metadata.get("buildNumber") != info.get("CFBundleVersion")):
        raise PipelineError("Review signed metadata disagrees with its role")
    binary = path / "Contents/MacOS" / executable
    if run(["xcrun", "lipo", "-archs", binary], capture=True).strip() != "arm64": raise PipelineError("Review requires arm64")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path], capture=True)
    details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", path], capture_output=True, text=True, check=True).stderr
    if ("Identifier=" + bundle_id + "\n" not in details or "TeamIdentifier=" + CONFIG["teamID"] + "\n" not in details or
            "Authority=Developer ID Application:" not in details or "runtime" not in details):
        raise PipelineError("Review requires its configured Developer ID and hardened runtime")
    return {"path": str(path), "bundleID": bundle_id, "executablePath": str(binary),
            "binarySHA256": sha256(binary), "infoSHA256": sha256(path / "Contents/Info.plist"), "metadata": metadata}


def inspect_pair(pair):
    pair = Path(pair).absolute()
    if pair != PAIR or pair.resolve(strict=True) != pair: raise PipelineError("Review pair must use the canonical local output")
    manifest = read_private(pair / "pair.json")
    source = manifest["source"]
    if not re.fullmatch(r"[0-9a-f]{40}", source.get("commit", "")) or source.get("dirty") is not False: raise PipelineError("Review source is not frozen")
    fixture = inspect_role(pair / "KeyDock Desktop Review Fixture.app", FIXTURE_ID, "KeyDockDesktopReviewFixture", "desktop-review-fixture", source)
    review = inspect_role(pair / "KeyDock Desktop Review.app", REVIEW_ID, "KeyDockDesktopReview", "desktop-review", source)
    binding = {"rootParent": str(PARENT / "sessions"), "reviewBundleIdentifier": REVIEW_ID, "fixtureBundleIdentifier": FIXTURE_ID,
               "fixtureAppPath": fixture["path"], "fixtureBinarySHA256": fixture["binarySHA256"], "fixtureInfoSHA256": fixture["infoSHA256"]}
    if review["metadata"].get("desktopReview") != binding or manifest.get("binding") != binding:
        raise PipelineError("Review companion binding changed")
    if manifest.get("review") != review or manifest.get("fixture") != fixture: raise PipelineError("Review pair receipt changed")
    if sha256(HELPER) != manifest.get("helperSHA256"): raise PipelineError("Review lifecycle helper changed")
    return manifest


def archive_pair(stage):
    if not PAIR.exists() or not any(PAIR.iterdir()): return
    real_ancestors(PAIR)
    original = tree_digest(PAIR)
    history = PARENT / "pair-history" / str(uuid.uuid4())
    private_directory(history, create=True)
    archive = history / "pair.zip"
    stage("review-retain-pair", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", PAIR, archive])
    verification = history / "verify"; verification.mkdir(mode=0o700)
    stage("review-retain-verify", ["/usr/bin/ditto", "-x", "-k", archive, verification])
    restored = verification / PAIR.name
    if tree_digest(restored) != original: raise PipelineError("Review archive failed full resource verification; original was preserved")
    helper_hash = None
    if HELPER.exists():
        if HELPER.is_symlink() or not HELPER.is_file(): raise PipelineError("Review helper cannot be archived safely")
        helper_hash = sha256(HELPER); shutil.copy2(HELPER, history / "KeyDockReviewLifecycle")
        if sha256(history / "KeyDockReviewLifecycle") != helper_hash: raise PipelineError("Review helper archive mismatch")
    durable_json(history / "retention.json", {"schemaVersion": 1, "originalPath": str(PAIR), "treeSHA256": original, "zipSHA256": sha256(archive), "helperSHA256": helper_hash, "restoredTreeMatched": True, "productAcceptance": False})
    # 仅清理刚创建且已逐资源验证的还原scratch；原App和zip仍保留到后续替换。
    shutil.rmtree(verification)


def build_pair(stage):
    with launcher_lock():
        source = source_identity()
        # 独立helper只查询Review身份，绝不操作生产／Preview。
        cache = ROOT / "build/pipeline/desktop-review/DerivedData"
        real_ancestors(PAIR); real_ancestors(HELPER.parent); real_ancestors(cache)
        HELPER.parent.mkdir(parents=True, exist_ok=True)
        candidate_helper = HELPER.parent / (".KeyDockReviewLifecycle-" + str(uuid.uuid4()))
        stage("review-lifecycle", ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors", "-target", "arm64-apple-macos14.0", ROOT / "Tools/KeyDockReviewLifecycle/main.swift", "-o", candidate_helper])
        paths = [(REVIEW_ID, PAIR / "KeyDock Desktop Review.app"), (FIXTURE_ID, PAIR / "KeyDock Desktop Review Fixture.app")]
        for bid, path in paths:
            if run([candidate_helper, "probe", bid, path], capture=True).strip() != "[]": raise PipelineError("Close the existing review pair before rebuilding")
        if HELPER.is_symlink(): raise PipelineError("Review helper must not be a symlink")
        archive_pair(stage)
        os.replace(candidate_helper, HELPER)
        stage("review-xcodegen", ["xcodegen", "generate", "--spec", ROOT / "project.yml"])
        real_ancestors(cache)
        stage("review-build", ["xcrun", "xcodebuild", "-project", ROOT / "KeyDock.xcodeproj", "-scheme", "KeyDock", "-configuration", "ReleaseDesktopReview", "-jobs", "2", "-derivedDataPath", cache, "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "MARKETING_VERSION=" + validate_version(CONFIG["version"]), "CURRENT_PROJECT_VERSION=" + CONFIG["buildNumber"], "build"])
        if PAIR.exists():
            real_ancestors(PAIR)
            if PAIR.is_symlink(): raise PipelineError("Refusing a symlink review output")
            shutil.rmtree(PAIR)
        PAIR.mkdir(mode=0o700, parents=True)
        fixture = PAIR / "KeyDock Desktop Review Fixture.app"
        binary = fixture / "Contents/MacOS/KeyDockDesktopReviewFixture"; binary.parent.mkdir(parents=True)
        (fixture / "Contents/Resources").mkdir()
        stage("review-fixture-build", ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors", "-D", "KEYDOCK_DESKTOP_REVIEW_FIXTURE", "-target", "arm64-apple-macos14.0", ROOT / "Tools/KeyDockDesktopFixture/main.swift", "-o", binary])
        info = {"CFBundleIdentifier": FIXTURE_ID, "CFBundleExecutable": binary.name, "CFBundleName": "KeyDock Desktop Review Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": CONFIG["buildNumber"], "CFBundleShortVersionString": validate_version(CONFIG["version"]), "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True}
        metadata = {"schemaVersion": 1, "profile": "desktop-review-fixture", "source": source, "version": CONFIG["version"], "buildNumber": CONFIG["buildNumber"], "architecture": "arm64"}
        def finalize(app, bid, info, metadata):
            info.update(KeyDockSafeSmoke=True, KeyDockGitCommit=source["commit"], KeyDockReleaseVersion=CONFIG["version"])
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            atomic_json(app / "Contents/Resources/BuildInfo.json", metadata)
            stage("review-sign-" + metadata["profile"], ["/usr/bin/codesign", "--force", "--sign", CONFIG["signingIdentity"], "--options", "runtime", "--timestamp", "--identifier", bid, app])
        finalize(fixture, FIXTURE_ID, info, metadata)
        binding = {"rootParent": str(PARENT / "sessions"), "reviewBundleIdentifier": REVIEW_ID, "fixtureBundleIdentifier": FIXTURE_ID, "fixtureAppPath": str(fixture), "fixtureBinarySHA256": sha256(binary), "fixtureInfoSHA256": sha256(fixture / "Contents/Info.plist")}
        review = PAIR / "KeyDock Desktop Review.app"
        run(["/usr/bin/ditto", cache / "Build/Products/ReleaseDesktopReview/KeyDockDesktopReview.app", review])
        info = plistlib.loads((review / "Contents/Info.plist").read_bytes())
        finalize(review, REVIEW_ID, info, dict(metadata, profile="desktop-review", desktopReview=binding))
        if source_identity() != source: raise PipelineError("Source changed during review build")
        manifest = {"schemaVersion": 1, "source": source, "binding": binding, "helperSHA256": sha256(HELPER),
                    "fixture": inspect_role(fixture, FIXTURE_ID, "KeyDockDesktopReviewFixture", "desktop-review-fixture", source),
                    "review": inspect_role(review, REVIEW_ID, "KeyDockDesktopReview", "desktop-review", source)}
        durable_json(PAIR / "pair.json", manifest)
        inspect_pair(PAIR)
        print(str(PAIR / "pair.json"), flush=True)
        return PAIR


def wait_started(role):
    for _ in range(100):
        values = lifecycle(role)
        if values: return values[0]
        time.sleep(0.1)
    raise PipelineError("Review process did not start; no readiness was assumed")


def require_root(root):
    root = private_directory(root)
    if root.parent != PARENT / "sessions" or not root.name.startswith("KeyDock-DesktopReview-"):
        raise PipelineError("Unexpected Review session root")
    uuid.UUID(root.name.removeprefix("KeyDock-DesktopReview-"))
    return root


def launch(pair, reuse_root=None):
    with launcher_lock():
        manifest = inspect_pair(pair)
        private_directory(PARENT / "sessions", create=True)
        review, fixture = manifest["review"], manifest["fixture"]
        if lifecycle(review): raise PipelineError("A Review instance is already running")
        root = require_root(reuse_root) if reuse_root else PARENT / "sessions" / ("KeyDock-DesktopReview-" + str(uuid.uuid4()))
        if reuse_root:
            marker = read_private(root / "review-session.json", 4096)
            fixture_values = lifecycle(fixture)
            expected = {"schemaVersion": 1, "rootID": root.name.removeprefix("KeyDock-DesktopReview-"), "reviewBundleIdentifier": REVIEW_ID,
                        "fixturePID": marker.get("fixturePID"), "fixtureLaunchTime": marker.get("fixtureLaunchTime")}
            if marker != expected or not fixture_values or fixture_values[0]["pid"] != marker["fixturePID"] or fixture_values[0]["birth"] != marker["fixtureLaunchTime"]:
                raise PipelineError("Reuse requires the same live companion and marker")
            companion = fixture_values[0]
        else:
            if lifecycle(fixture): raise PipelineError("An existing companion is not owned by this new session")
            root.mkdir(mode=0o700)
            companion = None
        # Scope持有自己的独占锁；launcher不得跨App启动持有它。
        fd = os.open(root / "review-owner.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1: raise PipelineError("Review owner lock changed")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally: os.close(fd)
        receipt = root / ("launch-" + str(uuid.uuid4()) + ".json")
        record = {"schemaVersion": 1, "state": "launch-intent", "root": str(root), "pair": str(PAIR), "source": manifest["source"], "fixture": companion, "review": None, "syntheticOnly": True, "ready": False}
        durable_json(receipt, record)
        print("Review launch intent: " + str(receipt), flush=True)
        with delivery.cancellation_signals() as cancellation:
            try:
                if not reuse_root:
                    # 创建窗口只记取消意图；拿到精确身份并落盘后才进入可中断等待。
                    run(["/usr/bin/open", "-n", "-a", fixture["path"]])
                    companion = wait_started(fixture)
                    record.update(state="companion-started", fixture=companion); durable_json(receipt, record)
                    if cancellation["signal"] is not None: raise PipelineError("Review start cancelled")
                    durable_json(root / "review-session.json", {"schemaVersion": 1, "rootID": root.name.removeprefix("KeyDock-DesktopReview-"), "reviewBundleIdentifier": REVIEW_ID, "fixturePID": companion["pid"], "fixtureLaunchTime": companion["birth"]})
                if cancellation["signal"] is not None: raise PipelineError("Review start cancelled")
                run(["/usr/bin/open", "-n", "-a", review["path"], "--args", "--desktop-review-root", root])
                record.update(state="processes-started", review=wait_started(review)); durable_json(receipt, record)
                if cancellation["signal"] is not None: raise PipelineError("Review start cancelled")
            except BaseException as error:
                cancellation["interruptible"] = False
                record["state"] = "partial-start"; record["compensation"] = {}; record["signal"] = cancellation["signal"]; record["failureKind"] = type(error).__name__
                durable_json(receipt, record)
                for role in ("review", "fixture"):
                    # 重用宿主不是本次新建资源；没有确认birth的实例也不认领。
                    if (role == "fixture" and reuse_root) or record[role] is None: continue
                    try:
                        if role == "fixture" and lifecycle(review):
                            record["compensation"][role] = "live-review-preserved"; durable_json(receipt, record); continue
                        if lifecycle(manifest[role]) == [record[role]]:
                            lifecycle(manifest[role], "quit", record[role]); record["compensation"][role] = "normally-stopped"
                        else: record["compensation"][role] = "identity-changed-preserved"
                    except Exception: record["compensation"][role] = "normal-stop-unconfirmed"
                    durable_json(receipt, record)
                raise
        print(str(receipt), flush=True)
        return receipt


def session_receipt(receipt):
    receipt = Path(receipt).absolute()
    root = require_root(receipt.parent)
    if not re.fullmatch(r"launch-[0-9a-f-]{36}\.json", receipt.name): raise PipelineError("Unexpected Review receipt name")
    record = read_private(receipt)
    if record.get("root") != str(root) or record.get("pair") != str(PAIR) or record.get("syntheticOnly") is not True: raise PipelineError("Review receipt identity changed")
    manifest = inspect_pair(PAIR)
    if record.get("source") != manifest["source"]: raise PipelineError("Review source changed")
    return receipt, record, manifest


def status(receipt, stop=False, review_only=False):
    with launcher_lock():
        receipt, record, manifest = session_receipt(receipt)
        states = {}
        for role in ("review", "fixture"):
            current = lifecycle(manifest[role])
            expected = record[role]
            if current and current != [expected]: raise PipelineError("Review process changed; no action was sent")
            states[role] = current
        if stop:
            for role in (("review",) if review_only else ("review", "fixture")):
                if states[role]: lifecycle(manifest[role], "quit", record[role])
            record["state"] = "review-stopped" if review_only else "stopped"
            durable_json(receipt, record)
        result = {"state": record["state"], "review": lifecycle(manifest["review"]), "fixture": lifecycle(manifest["fixture"]), "ready": False}
        print(json.dumps(result, indent=2), flush=True)
        return result
