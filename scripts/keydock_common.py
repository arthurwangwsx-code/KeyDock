"""本地、CI、安装与发行共用的身份和产物校验；仅依赖Python标准库。"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "release/config.json").read_text())


class PipelineError(RuntimeError):
    pass


def current_data_compatibility():
    return {"schemaVersion": 3, "invocationEnvelope": {"readVersions": [1, 2, 3], "writeVersions": [1, 2, 3]},
            "taskMaterial": {"readVersions": [1], "writeVersions": [1]},
            "configuration": {"readVersions": [1, 2, 3, 4], "writeVersions": [4]}}


def validate_data_compatibility(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] not in (1, 2, 3):
        raise PipelineError("Unsupported App data compatibility declaration")
    expected = {"schemaVersion", "invocationEnvelope"} | ({"taskMaterial"} if value["schemaVersion"] >= 2 else set()) | ({"configuration"} if value["schemaVersion"] == 3 else set())
    if set(value) != expected: raise PipelineError("Unsupported App data compatibility declaration")
    result = {"schemaVersion": value["schemaVersion"], "invocationEnvelope": _reader_versions(value["invocationEnvelope"])}
    if value["schemaVersion"] >= 2: result["taskMaterial"] = _reader_versions(value["taskMaterial"], allow_empty=True)
    if value["schemaVersion"] == 3: result["configuration"] = _reader_versions(value["configuration"])
    return result


def _reader_versions(envelope, allow_empty=False):
    if not isinstance(envelope, dict) or set(envelope) != {"readVersions", "writeVersions"}:
        raise PipelineError("Invalid invocation reader declaration")
    normalized = {}
    for key in ("readVersions", "writeVersions"):
        versions = envelope[key]
        if (not isinstance(versions, list) or not (0 if allow_empty else 1) <= len(versions) <= 16 or
                any(type(v) is not int or not 1 <= v <= 64 for v in versions) or len(set(versions)) != len(versions)):
            raise PipelineError("Invalid invocation reader versions")
        normalized[key] = sorted(versions)
    if not set(normalized["writeVersions"]).issubset(normalized["readVersions"]):
        raise PipelineError("App cannot write a format it cannot read")
    return normalized


def task_material_readers(capability):
    value = validate_data_compatibility(capability)
    return value.get("taskMaterial", {}).get("readVersions", [])


def configuration_readers(capability):
    value = validate_data_compatibility(capability)
    return value.get("configuration", {}).get("readVersions", [1])


def app_data_compatibility(metadata, release_version):
    if "dataCompatibility" in metadata:
        return validate_data_compatibility(metadata["dataCompatibility"])
    if re.fullmatch(r"0\.1\.0-alpha\.([1-9]|1[0-8])", str(release_version)):
        return {"schemaVersion": 1, "invocationEnvelope": {"readVersions": [1], "writeVersions": [1]}}
    raise PipelineError("This App has no known data reader declaration")


def run(args, capture=False, cwd=ROOT, env=None):
    """始终使用参数数组；凭据只由系统工具从钥匙串读取，不拼接shell命令。"""
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            stdout=subprocess.PIPE if capture else None, text=True)
    if result.returncode:
        raise PipelineError("%s failed (exit %s)" % (Path(str(args[0])).name, result.returncode))
    return result.stdout if capture else None


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(app):
    """校验复制前后所有资源、权限与相对symlink；不跟随外部链接。"""
    app = Path(app).resolve(strict=True)
    digest = hashlib.sha256()
    digest.update(("root-mode:" + oct(stat.S_IMODE(app.stat().st_mode)) + "\0").encode())
    for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix()):
        relative = path.relative_to(app).as_posix()
        mode = path.lstat().st_mode
        digest.update((relative + "\0" + oct(stat.S_IMODE(mode)) + "\0").encode())
        if path.is_symlink():
            if not path.resolve().is_relative_to(app):
                raise PipelineError("App contains an external symlink: " + relative)
            digest.update(("link:" + os.readlink(path)).encode())
        elif path.is_file():
            digest.update(bytes.fromhex(sha256(path)))
        elif not path.is_dir():
            raise PipelineError("Unsupported App resource: " + relative)
    return digest.hexdigest()


def source_identity(require_clean=True):
    dirty = bool(run(["git", "status", "--porcelain"], capture=True).strip())
    if dirty and require_clean:
        raise PipelineError("Commit the reviewed source before packaging or publishing")
    commit = run(["git", "rev-parse", "HEAD"], capture=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise PipelineError("Source commit is not a complete Git SHA")
    return {"commit": commit, "dirty": dirty}


def validate_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
        raise PipelineError("Use a semantic version such as 0.1.0-alpha.1")
    return version.split("-", 1)[0]


def signature_has_runtime(details):
    return bool(re.search(r"^CodeDirectory .*flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", details, flags=re.M))


def inspect_app(path):
    path = Path(path).absolute()
    if path.is_symlink() or not path.is_dir() or path.suffix.lower() != ".app":
        raise PipelineError("App must be a real directory")
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    bundle_id = info.get("CFBundleIdentifier")
    expected = {CONFIG["bundleIdentifier"]: "release", CONFIG["previewBundleIdentifier"]: "preview"}
    if bundle_id not in expected:
        raise PipelineError("Unexpected application bundle identifier")
    executable_name = info.get("CFBundleExecutable", "")
    if not executable_name or Path(executable_name).name != executable_name:
        raise PipelineError("Invalid App executable")
    executable = path / "Contents/MacOS" / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise PipelineError("App executable is missing or not executable")
    metadata_path = path / "Contents/Resources/BuildInfo.json"
    if not metadata_path.is_file():
        raise PipelineError("App has no pipeline BuildInfo.json; it was preserved")
    metadata = json.loads(metadata_path.read_text())
    profile = expected[bundle_id]
    safe_smoke = info.get("KeyDockSafeSmoke") is True
    if metadata.get("profile") != profile or safe_smoke != (profile == "preview"):
        raise PipelineError("App profile, bundle identity and capture setting disagree")
    commit = metadata.get("source", {}).get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or info.get("KeyDockGitCommit") != commit:
        raise PipelineError("App source identity is inconsistent")
    version = str(info.get("CFBundleShortVersionString", ""))
    release_version = info.get("KeyDockReleaseVersion", "")
    if validate_version(release_version) != version or metadata.get("version") != release_version:
        raise PipelineError("App version does not match its build metadata")
    if str(info.get("CFBundleVersion", "")) != metadata.get("buildNumber"):
        raise PipelineError("App build number does not match its build metadata")
    architecture = run(["xcrun", "lipo", "-archs", executable], capture=True).strip()
    if architecture != "arm64" or metadata.get("architecture") != architecture:
        raise PipelineError("App architecture does not match this arm64 pipeline")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path], capture=True)
    details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", path], capture_output=True, text=True, check=True).stderr
    fields = dict(line.split("=", 1) for line in details.splitlines() if "=" in line)
    if fields.get("Identifier") != bundle_id:
        raise PipelineError("Code signature does not match the bundle identifier")
    authorities = re.findall(r"^Authority=(.+)$", details, flags=re.M)
    kind = "developer-id" if authorities and authorities[0].startswith("Developer ID Application:") else ("adhoc" if fields.get("Signature") == "adhoc" else "other")
    notarized = False
    if kind == "developer-id":
        notarized = subprocess.run(["xcrun", "stapler", "validate", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    return {
        "bundle_id": bundle_id, "profile": profile, "safe_smoke": safe_smoke,
        "data_compatibility": app_data_compatibility(metadata, release_version),
        "version": version, "release_version": release_version,
        "build_number": str(info.get("CFBundleVersion", "")), "commit": commit,
        "source_dirty": bool(metadata.get("source", {}).get("dirty")),
        "qualification_sha256": metadata.get("qualificationSHA256"),
        "executable": str(executable), "binary_sha256": sha256(executable),
        "bundle_sha256": tree_digest(path), "notarized": notarized, "architecture": architecture,
        "code_signature": {"kind": kind, "team_id": fields.get("TeamIdentifier"),
                           "hardened_runtime": signature_has_runtime(details)}
    }
