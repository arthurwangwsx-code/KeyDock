"""任务材料v1的有界元数据协议；本模块不打开文件，也不读取正文。"""
import json
import math
import re
import uuid

from keydock_common import PipelineError

MAGIC = b"KDMAT001"
PREFIX_BYTES = 12
MAX_HEADER = 8192
MAX_RECORD = 4 * 1024 * 1024
MAX_CONTROL = 64 * 1024


def _fail(): raise PipelineError("Invalid or unsupported task material metadata")


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value: _fail()
        value[key] = item
    return value


def _integer(value):
    if len(value) > 24: _fail()
    return int(value)


def _json(data, limit):
    if not isinstance(data, bytes) or len(data) > limit: _fail()
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_unique, parse_int=_integer,
                          parse_constant=lambda _: _fail())
    except (UnicodeError, ValueError, RecursionError): _fail()


def _keys(value, allowed, required=None):
    if not isinstance(value, dict) or not set(value).issubset(allowed) or not (allowed if required is None else required).issubset(value): _fail()


def _uuid(value):
    if not isinstance(value, str) or len(value) != 36: _fail()
    try: parsed = str(uuid.UUID(value))
    except (ValueError, AttributeError): _fail()
    if parsed != value.lower(): _fail()
    return parsed


def _uint(value, maximum, minimum=0):
    if type(value) is not int or not minimum <= value <= maximum: _fail()


def _time(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0: _fail()


def _digest(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value): _fail()


def material_key(value):
    _keys(value, {"receiptStore", "invocationID", "receiptRecordIdentity"})
    if value["receiptStore"] not in ("cli", "ai"): _fail()
    return value["receiptStore"], _uuid(value["invocationID"]), _uuid(value["receiptRecordIdentity"])


def material_name(value):
    return "-".join(material_key(value)) + ".kdmaterial"


def _version(value):
    _keys(value, {"identity", "revision"})
    _uuid(value["identity"]); _uint(value["revision"], 2 ** 64 - 1, 1)


def header_length(prefix):
    if not isinstance(prefix, bytes) or len(prefix) != PREFIX_BYTES or prefix[:8] != MAGIC: _fail()
    count = int.from_bytes(prefix[8:], "big")
    if not 2 <= count <= MAX_HEADER: _fail()
    return count


def parse_header(prefix, data, file_bytes):
    count = header_length(prefix)
    _uint(file_bytes, MAX_RECORD)
    if len(data) != count: _fail()
    header = _json(data, MAX_HEADER)
    required = {"formatVersion", "key", "version", "createdAt", "expiresAt", "fields", "rawBytes", "payloadBytes", "payloadSHA256"}
    _keys(header, required | {"resultKind", "resultWasPartial", "resultCapturedAt"}, required)
    if type(header["formatVersion"]) is not int or header["formatVersion"] != 1: _fail()
    key = material_key(header["key"]); _version(header["version"])
    _time(header["createdAt"]); _time(header["expiresAt"])
    if not 0 <= header["expiresAt"] - header["createdAt"] <= 7 * 86400: _fail()
    fields = header["fields"]
    if not isinstance(fields, list) or not fields or any(type(x) is not str for x in fields) or len(fields) != len(set(fields)) or not set(fields).issubset({"input", "visibleResult", "successfulCheckpoint"}): _fail()
    has_result = "visibleResult" in fields
    if has_result:
        if header.get("resultKind") not in ("visibleResult", "agentIncludingToolReturns") or type(header.get("resultWasPartial")) is not bool: _fail()
        _time(header.get("resultCapturedAt"))
    elif any(header.get(key) is not None for key in ("resultKind", "resultWasPartial", "resultCapturedAt")): _fail()
    if key[0] == "cli" and (fields != ["visibleResult"] or header.get("resultKind") != "visibleResult"): _fail()
    _uint(header["rawBytes"], 2 * (128 * 1024 + 1024 * 1024))
    _uint(header["payloadBytes"], MAX_RECORD, 2); _digest(header["payloadSHA256"])
    if file_bytes != PREFIX_BYTES + count + header["payloadBytes"]: _fail()
    return header


def parse_control(data):
    value = _json(data, MAX_CONTROL)
    _keys(value, {"formatVersion", "epoch", "deletion", "pendingWrite"}, {"formatVersion", "epoch"})
    if type(value["formatVersion"]) is not int or value["formatVersion"] != 1: _fail()
    _uuid(value["epoch"])
    deletion = value.get("deletion")
    if deletion is not None:
        _keys(deletion, {"id", "all", "keys", "targets"})
        _uuid(deletion["id"])
        if type(deletion["all"]) is not bool or not isinstance(deletion["keys"], list) or not isinstance(deletion["targets"], list): _fail()
        keys = [material_key(x) for x in deletion["keys"]]
        targets = []
        for target in deletion["targets"]:
            _keys(target, {"key", "version"}); targets.append(material_key(target["key"])); _version(target["version"])
        if len(keys) + len(targets) > 200 or len(set(keys)) != len(keys) or len(set(targets)) != len(targets) or set(keys) & set(targets): _fail()
        if deletion["all"]:
            if keys or targets: _fail()
        elif not keys and not targets: _fail()
    pending = value.get("pendingWrite")
    if pending is not None:
        _keys(pending, {"key", "proposed", "previous", "payloadSHA256", "fileBytes"}, {"key", "proposed", "payloadSHA256", "fileBytes"})
        key = material_key(pending["key"]); _version(pending["proposed"])
        _digest(pending["payloadSHA256"]); _uint(pending["fileBytes"], MAX_RECORD, 12)
        previous = pending.get("previous")
        if previous is None:
            if pending["proposed"]["revision"] != 1: _fail()
        else:
            _version(previous)
            if _uuid(previous["identity"]) != _uuid(pending["proposed"]["identity"]) or previous["revision"] == 2 ** 64 - 1 or pending["proposed"]["revision"] != previous["revision"] + 1: _fail()
        if deletion and (deletion["all"] or key in [material_key(x) for x in deletion["keys"]] or key in [material_key(x["key"]) for x in deletion["targets"]]): _fail()
    return value
