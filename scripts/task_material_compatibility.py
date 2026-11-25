"""安装/回退只读扫描：固定目录、正文零读取、最终身份复查；不迁移或清除数据。"""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat

from keydock_common import PipelineError
from invocation_compatibility import DIRECTORY_FLAGS, _open_directory, _identity, _entry_identity
from task_material_format import MAX_CONTROL, MAX_HEADER, MAX_RECORD, parse_control, parse_header, material_name

DIRECTORY = "task-materials"
CONTROL = "control.json"
LOCK = ".owner.lock"
MAX_ENTRIES = 2048
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_RETAINED_BYTES = 64 * 1024 * 1024
_UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
_KEY = r"(?:ai|cli)-" + _UUID + "-" + _UUID
_BODY = re.compile(_KEY + r"\.kdmaterial\Z")
_BODY_TEMP = re.compile(r"\.material-v1-" + _KEY + "-" + _UUID + r"\.tmp\Z")
_CONTROL_TEMP = re.compile(r"\.control-v1-" + _UUID + r"\.tmp\Z")


def _fail(): raise PipelineError("Task material metadata is unavailable, changed, unsafe or unsupported; data was preserved")


def _read_exact(descriptor, count):
    parts = []
    while count:
        chunk = os.read(descriptor, min(count, 8192))
        if not chunk: _fail()
        parts.append(chunk); count -= len(chunk)
    return b"".join(parts)


def _names(directory):
    # 独立cursor；第二次枚举不能沿用第一次已走到末尾的目录游标。
    cursor = os.open(".", DIRECTORY_FLAGS, dir_fd=directory)
    try:
        result = []
        with os.scandir(cursor) as entries:
            for entry in entries:
                if len(result) >= MAX_ENTRIES or len(entry.name.encode("utf-8")) > 255: _fail()
                result.append(entry.name)
        return result
    finally: os.close(cursor)


def _inspect(parent, name, budget):
    descriptor = None
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1 or before.st_mode & 0o077: _fail()
        identity = _identity(before)
        required, material, temporary, pending, read_bytes = [], 0, 0, False, 0
        if name == LOCK:
            if before.st_size != 0: _fail()
        elif name == CONTROL:
            if not 2 <= before.st_size <= MAX_CONTROL: _fail()
            read_bytes = before.st_size
            if read_bytes > budget: _fail()
            value = parse_control(_read_exact(descriptor, read_bytes))
            pending = value.get("deletion") is not None or value.get("pendingWrite") is not None
            if pending: required = [1]
        elif _BODY.fullmatch(name):
            if not 14 <= before.st_size <= MAX_RECORD: _fail()
            if budget < 12: _fail()
            prefix = _read_exact(descriptor, 12)
            from task_material_format import header_length
            count = header_length(prefix)
            read_bytes = 12 + count
            if count > MAX_HEADER or read_bytes > budget: _fail()
            header = parse_header(prefix, _read_exact(descriptor, count), before.st_size)
            if material_name(header["key"]) != name: _fail()
            required, material = [1], 1
        elif _BODY_TEMP.fullmatch(name) or _CONTROL_TEMP.fullmatch(name):
            maximum = MAX_RECORD if _BODY_TEMP.fullmatch(name) else MAX_CONTROL
            if not 0 <= before.st_size <= maximum: _fail()
            required, temporary, pending = [1], 1, True
        else: _fail()
        if identity != _identity(os.fstat(descriptor)) or identity != _entry_identity(parent, name): _fail()
        return identity, required, material, temporary, pending, read_bytes
    finally:
        if descriptor is not None: os.close(descriptor)


def probe_task_materials(root, guard=None):
    root = Path(root)
    result = {"requiredVersions": [], "materialCount": 0, "temporaryCount": 0, "pending": False}
    parent = directory = current_root = None
    try:
        if guard is not None:
            guard.assert_current(); parent = os.dup(guard.directory)
        else: parent = _open_directory(root)
        if parent is None: return result
        mapping = _entry_identity(parent, DIRECTORY)
        if mapping is not None:
            directory = os.open(DIRECTORY, DIRECTORY_FLAGS, dir_fd=parent)
            info = os.fstat(directory)
            if mapping != _identity(info) or info.st_uid != os.geteuid() or info.st_mode & 0o077: _fail()
            names = _names(directory)
            observed = {}; budget = MAX_METADATA_BYTES; total = 0; versions = set()
            for name in sorted(names):
                observation, required, material, temporary, pending, read_bytes = _inspect(directory, name, budget)
                observed[name] = observation; versions.update(required); budget -= read_bytes
                result["materialCount"] += material; result["temporaryCount"] += temporary
                result["pending"] |= pending
                if name not in (CONTROL, LOCK): total += observation[5]
                if total > MAX_RETAINED_BYTES or result["materialCount"] > 200: _fail()
            if set(_names(directory)) != set(names): _fail()
            for name, identity in observed.items():
                if _entry_identity(directory, name) != identity: _fail()
            result["requiredVersions"] = sorted(versions)
        if _entry_identity(parent, DIRECTORY) != mapping: _fail()
        current_root = _open_directory(root)
        if current_root is None or _identity(os.fstat(current_root)) != _identity(os.fstat(parent)): _fail()
        if guard is not None: guard.assert_current()
        return result
    except (OSError, UnicodeError, ValueError, RecursionError): _fail()
    finally:
        for descriptor in (directory, current_root, parent):
            if descriptor is not None: os.close(descriptor)
