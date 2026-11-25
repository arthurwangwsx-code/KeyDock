"""只读检查默认运行数据域；不加载Store、不转换或删除任何调用记录。"""
from __future__ import annotations

import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import pwd
import stat

from keydock_common import PipelineError, run

FILES = ("invocations", "ai-invocations", "agent-tool-invocations")
MAX_BYTES = 16 * 1_048_576
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def runtime_data_root(facts):
    uid = os.getuid()
    if uid <= 0 or uid != os.geteuid() or "SUDO_UID" in os.environ:
        raise PipelineError("Installation data checks require the normal signed-in user")
    if facts.get("profile") == "release":
        return Path(pwd.getpwuid(uid).pw_dir) / "Library/Application Support/KeyDock"
    if facts.get("profile") != "preview":
        raise PipelineError("Unknown runtime data profile")
    # gate的TMPDIR用于构建隔离；定位正常GUI域时只查询UID的OS默认目录，不继承它。
    raw = run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    if not isinstance(raw, str) or len(raw.encode()) > 16_384 or not raw.endswith("\n") or "\n" in raw[:-1] or "\0" in raw:
        raise PipelineError("Cannot identify the default Preview data domain")
    base = Path(raw[:-1])
    if not base.is_absolute():
        raise PipelineError("Preview temporary directory is not absolute")
    base = base.resolve(strict=True)  # 只解析OS返回的系统/var别名，不接受外部目录参数。
    info = base.stat()
    if base in (Path("/"), Path("/tmp"), Path("/var/tmp"), Path("/private/tmp"), Path("/private/var/tmp")) or not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise PipelineError("Preview data domain is not a private directory for this user")
    return base / "KeyDock-Smoke"


def _open_directory(path, create=False):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or "\0" in str(path):
        raise PipelineError("Invalid runtime data directory")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.parts[1:]:
            try:
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    return None
                if os.fstat(descriptor).st_uid != os.geteuid():
                    raise PipelineError("Cannot create data directories outside the user's domain")
                os.mkdir(component, 0o700, dir_fd=descriptor)
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor); descriptor = child
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise PipelineError("Runtime data directory is not owned and protected")
        result = descriptor; descriptor = None; return result
    except OSError:
        raise PipelineError("Cannot safely open the runtime data directory") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _entry_identity(parent, name):
    try:
        return _identity(os.stat(name, dir_fd=parent, follow_symlinks=False))
    except FileNotFoundError:
        return None


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_):
    raise ValueError("non-finite JSON")


def _bounded_integer(value):
    if len(value) > 64: raise ValueError("unbounded integer")
    return int(value)


def _bounded_float(value):
    if len(value) > 64: raise ValueError("unbounded number")
    result = float(value)
    if not math.isfinite(result): raise ValueError("non-finite number")
    return result


def _read_version(parent):
    descriptor = None
    try:
        try:
            descriptor = os.open("invocations.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        except FileNotFoundError:
            return None
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1 or before.st_size > MAX_BYTES:
            raise PipelineError("Invocation metadata is not a bounded owned regular file")
        chunks = []; count = 0
        while count <= MAX_BYTES:
            chunk = os.read(descriptor, min(65_536, MAX_BYTES + 1 - count))
            if not chunk:
                break
            chunks.append(chunk); count += len(chunk)
        if count > MAX_BYTES or _identity(before) != _identity(os.fstat(descriptor)) or _identity(before) != _identity(os.stat("invocations.json", dir_fd=parent, follow_symlinks=False)):
            raise PipelineError("Invocation metadata changed while checking")
        value = json.loads(b"".join(chunks), object_pairs_hook=_unique_object, parse_constant=_reject_constant,
                           parse_int=_bounded_integer, parse_float=_bounded_float)
        if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] not in (1, 2) or not isinstance(value.get("receipts"), list) or not all(isinstance(row, dict) for row in value["receipts"]):
            raise ValueError("unsupported envelope")
        if value["version"] == 1 and any(row.get("runAttempt") is not None for row in value["receipts"]):
            raise ValueError("typed data in a legacy envelope")
        return value["version"]
    except (OSError, ValueError, UnicodeError, RecursionError):
        raise PipelineError("Invocation metadata is unavailable, changed, malformed or unsupported; data was preserved") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def probe_versions(root, guard=None):
    if guard is not None:
        guard.assert_current()
        descriptor = os.dup(guard.directory)
    else:
        descriptor = _open_directory(root)
    result = {}; children = []; observations = []
    try:
        for name in FILES:
            try:
                if descriptor is None:
                    result[name] = None; continue
                directory_identity = _entry_identity(descriptor, name)
                try:
                    child = os.open(name, DIRECTORY_FLAGS, dir_fd=descriptor)
                except FileNotFoundError:
                    if directory_identity is not None:
                        raise PipelineError("Invocation directory changed while checking")
                    observations.append((name, None, None, None))
                    result[name] = None; continue
                children.append(child)
                if directory_identity != _identity(os.fstat(child)):
                    raise PipelineError("Invocation directory changed while checking")
                if os.fstat(child).st_uid != os.geteuid():
                    raise PipelineError("Invocation directory is not owned")
                file_identity = _entry_identity(child, "invocations.json")
                result[name] = _read_version(child)
                if file_identity != _entry_identity(child, "invocations.json"):
                    raise PipelineError("Invocation file changed while checking")
                observations.append((name, directory_identity, child, file_identity))
            except OSError:
                raise PipelineError("Cannot safely inspect invocation metadata") from None
        for name, directory_identity, child, file_identity in observations:
            if _entry_identity(descriptor, name) != directory_identity:
                raise PipelineError("Invocation directory mapping changed while checking")
            if child is not None and _entry_identity(child, "invocations.json") != file_identity:
                raise PipelineError("Invocation file mapping changed while checking")
        if guard is not None: guard.assert_current()
        return result
    finally:
        for child in children: os.close(child)
        if descriptor is not None: os.close(descriptor)


class RuntimeDataGuard:
    def __init__(self, root, directory, lock):
        self.root, self.directory, self.lock = Path(root), directory, lock

    def assert_current(self):
        current = _open_directory(self.root)
        try:
            if current is None or (os.fstat(current).st_dev, os.fstat(current).st_ino) != (os.fstat(self.directory).st_dev, os.fstat(self.directory).st_ino):
                raise PipelineError("Runtime data directory identity changed")
            lock = os.stat("runtime-owner.lock", dir_fd=current, follow_symlinks=False)
            if (lock.st_dev, lock.st_ino) != (os.fstat(self.lock).st_dev, os.fstat(self.lock).st_ino):
                raise PipelineError("Runtime data ownership lock changed")
        finally:
            if current is not None: os.close(current)


@contextlib.contextmanager
def runtime_data_lease(root):
    directory = _open_directory(root, create=True)
    lock = None
    try:
        lock = os.open("runtime-owner.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise PipelineError("Invalid runtime ownership lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PipelineError("The App still owns its runtime data; replacement was not attempted") from None
        guard = RuntimeDataGuard(root, directory, lock); guard.assert_current(); yield guard
    finally:
        if lock is not None: os.close(lock)
        os.close(directory)
