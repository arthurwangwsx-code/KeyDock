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


def _application_actions(value):
    # null是尚未确认的旧源，不能转换为空数组。这里只检查reader合同，不迁移数据。
    if value is None: return
    if not isinstance(value, list) or len(value) > 100: raise ValueError("invalid actions")
    seen = set()
    for action in value:
        if not isinstance(action, dict): raise ValueError("invalid action")
        identifier = uuid.UUID(action["id"])
        if identifier in seen or type(action.get("version")) is not int or action["version"] != 1:
            raise ValueError("invalid action identity")
        seen.add(identifier)
        name, application = action["name"], action["applicationID"]
        if not isinstance(name, str) or not isinstance(application, str): raise ValueError("invalid action")
        name = name.strip()
        forbidden = "\0\n\r\v\f\x85\u2028\u2029"
        if (not name or len(name.encode("utf-8")) > 160 or any(c in name for c in forbidden)
                or not application.startswith("app./") or len(application.encode("utf-8")) > 4096
                or any(c in application for c in forbidden) or not application.rstrip("/").lower().endswith(".app")
                or action.get("behavior") not in ("launchOrActivate", "toggleVisibility", "hide", "show", "showAllWindows", "requestQuit")):
            raise ValueError("invalid action")


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
        if type(version) is not int or version not in (1, 2, 3, 4): raise ValueError("unsupported configuration")
        if version == 1 and any(key in value for key in ("aiModelSettings", "aiSettingsRevision")):
            raise ValueError("new settings in legacy configuration")
        if version >= 2:
            if not isinstance(value.get("aiModelSettings"), dict) or not isinstance(value.get("aiSettingsRevision"), str):
                raise ValueError("missing model settings or revision")
            uuid.UUID(value["aiSettingsRevision"])
        if version < 3 and "savedApplicationActions" in value: raise ValueError("new actions in legacy configuration")
        if version >= 3:
            if "savedApplicationActions" not in value: raise ValueError("missing action source state")
            _application_actions(value["savedApplicationActions"])
        agents = value.get("agents")
        if version >= 4 or agents is not None:
            if not isinstance(agents, list) or not all(isinstance(row, dict) for row in agents): raise ValueError("invalid agents")
            for row in agents:
                if version < 4:
                    if "maxRunTokens" in row: raise ValueError("new token threshold in legacy configuration")
                else:
                    if "maxRunTokens" not in row: raise ValueError("missing token threshold state")
                    threshold = row["maxRunTokens"]
                    if threshold is not None and (type(threshold) is not int or not 1 <= threshold <= 1_000_000_000): raise ValueError("invalid token threshold")
        if guard is not None: guard.assert_current()
        return version
    except (OSError, ValueError, KeyError, TypeError, AttributeError, UnicodeError, RecursionError):
        raise PipelineError("Configuration is unavailable, changed, malformed or unsupported; data was preserved") from None
    finally:
        if descriptor is not None: os.close(descriptor)
        if parent is not None: os.close(parent)
