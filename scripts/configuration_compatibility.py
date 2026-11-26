"""只读、有界探测配置reader版本，不转换、记录或导出配置正文。"""
import json
import os
import stat
import uuid

from invocation_compatibility import (_open_directory, _identity, _entry_identity, _unique_object,
                                     _reject_constant, _bounded_integer, _bounded_float)
from keydock_common import PipelineError

MAX_BYTES = 16 * 1_048_576
NAME = "configuration.json"


def probe_configuration(root, guard=None):
    parent = descriptor = None
    try:
        if guard is not None:
            guard.assert_current()
            parent = os.dup(guard.directory)
        else:
            parent = _open_directory(root)
        if parent is None:
            return None
        before_entry = _entry_identity(parent, NAME)
        if before_entry is None:
            if _entry_identity(parent, NAME) is not None:
                raise PipelineError("Configuration changed while checking")
            if guard is not None: guard.assert_current()
            return None
        descriptor = os.open(NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        info = os.fstat(descriptor)
        if (_identity(info) != before_entry or not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or info.st_mode & 0o022 or not 0 < info.st_size <= MAX_BYTES):
            raise PipelineError("Configuration is not a bounded owned regular file")
        chunks = []; count = 0
        while count <= MAX_BYTES:
            chunk = os.read(descriptor, min(65_536, MAX_BYTES + 1 - count))
            if not chunk: break
            chunks.append(chunk); count += len(chunk)
        if count > MAX_BYTES or _identity(info) != _identity(os.fstat(descriptor)) or _identity(info) != _entry_identity(parent, NAME):
            raise PipelineError("Configuration changed while checking")
        value = json.loads(b"".join(chunks), object_pairs_hook=_unique_object, parse_constant=_reject_constant,
                           parse_int=_bounded_integer, parse_float=_bounded_float)
        if not isinstance(value, dict): raise ValueError("invalid configuration")
        version = value.get("schemaVersion", 1)
        if type(version) is not int or version not in (1, 2): raise ValueError("unsupported configuration")
        if version == 1 and any(key in value for key in ("aiModelSettings", "aiSettingsRevision")):
            raise ValueError("new settings in legacy configuration")
        if version == 2:
            if not isinstance(value.get("aiModelSettings"), dict) or not isinstance(value.get("aiSettingsRevision"), str):
                raise ValueError("missing model settings or revision")
            uuid.UUID(value["aiSettingsRevision"])
        if guard is not None: guard.assert_current()
        return version
    except (OSError, ValueError, UnicodeError, RecursionError):
        raise PipelineError("Configuration is unavailable, changed, malformed or unsupported; data was preserved") from None
    finally:
        if descriptor is not None: os.close(descriptor)
        if parent is not None: os.close(parent)
