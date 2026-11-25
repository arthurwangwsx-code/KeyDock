"""冻结发行输入与可续查的公证请求；不恢复执行权限、不自动重投未知提交。"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import threading
import time
import uuid

from keydock_common import PipelineError, atomic_json, validate_version


def mkdir_durable(path, mode=0o700):
    path = Path(path).absolute()
    if ".." in path.parts: raise PipelineError("Delivery directory cannot contain dotdot")
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            try: following = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            except FileNotFoundError:
                os.mkdir(component, mode, dir_fd=descriptor)
                os.fsync(descriptor)
                following = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.fsync(following)
            os.close(descriptor); descriptor = following
    finally: os.close(descriptor)


def durable_rename(source, destination):
    source, destination = Path(source), Path(destination)
    if destination.exists() or destination.is_symlink(): raise PipelineError("Delivery destination already exists")
    mkdir_durable(destination.parent)
    os.rename(source, destination)
    for parent in {source.parent, destination.parent}:
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)


def durable_json(path, value):
    mkdir_durable(Path(path).parent)
    atomic_json(path, value)
    descriptor = os.open(Path(path).parent, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


@contextmanager
def exclusive(path):
    path = Path(path)
    mkdir_durable(path.parent)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        facts = os.fstat(descriptor)
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_nlink != 1:
            raise PipelineError("Delivery lock is not an owned regular file")
        try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise PipelineError("This delivery already has an active operator")
        yield
    finally: os.close(descriptor)


def regular(path):
    value = Path(path).lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or value.st_nlink != 1:
        raise PipelineError("Delivery input must be an owned regular file, never a link: " + str(path))
    return value


def file_record(path):
    path = Path(path)
    before = regular(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise PipelineError("Delivery input was rebound while opening")
        digest = hashlib.sha256()
        for block in iter(lambda: os.read(descriptor, 1024 * 1024), b""): digest.update(block)
        digest = digest.hexdigest()
    finally: os.close(descriptor)
    after = regular(path)
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, key) != getattr(after, key) for key in fields):
        raise PipelineError("Delivery input changed while hashing")
    return {"path": str(path.absolute()), "sha256": digest, "bytes": after.st_size,
            "device": after.st_dev, "inode": after.st_ino}


def copy_payload(source, destination):
    """普通复制到独占新inode，保留原件；复制期间任何变化都不进入后续阶段。"""
    source, destination = Path(source), Path(destination)
    before = file_record(source)
    mkdir_durable(destination.parent)
    reader = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(reader)
        if (opened.st_dev, opened.st_ino) != (before["device"], before["inode"]):
            raise PipelineError("Delivery source was rebound before copy")
        writer = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(os.dup(reader), "rb") as incoming, os.fdopen(os.dup(writer), "wb") as outgoing:
                for block in iter(lambda: incoming.read(1024 * 1024), b""): outgoing.write(block)
                outgoing.flush()
                os.fsync(outgoing.fileno())
        finally: os.close(writer)
    finally: os.close(reader)
    copied, after = file_record(destination), file_record(source)
    if (before != after or before["sha256"] != copied["sha256"] or
            (before["device"], before["inode"]) == (copied["device"], copied["inode"])):
        raise PipelineError("Frozen copy differs from its source; both files were retained")
    descriptor = os.open(destination.parent, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)
    return {"source": before, "copy": copied}


def read_receipt(path):
    path = Path(path)
    before = regular(path)
    limit = 1024 * 1024
    if before.st_size > limit: raise PipelineError("Delivery receipt exceeds its budget")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid() or opened.st_nlink != 1 or
                (opened.st_dev, opened.st_ino, opened.st_size) != (before.st_dev, before.st_ino, before.st_size)):
            raise PipelineError("Delivery receipt was rebound while opening")
        data = bytearray()
        while len(data) <= limit:
            block = os.read(descriptor, min(65536, limit + 1 - len(data)))
            if not block: break
            data.extend(block)
        after = os.fstat(descriptor)
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if len(data) > limit or any(getattr(opened, k) != getattr(after, k) for k in fields):
            raise PipelineError("Delivery receipt changed or exceeded its budget")
        value = json.loads(data)
    finally: os.close(descriptor)
    if not isinstance(value, dict): raise PipelineError("Invalid delivery receipt")
    return value


def require_candidate(work, parent):
    work, parent = Path(work).absolute(), Path(parent).absolute()
    if ".." in work.parts or ".." in parent.parts or not work.is_relative_to(parent) or work == parent:
        raise PipelineError("Candidate is outside the persistent pipeline directory")
    # 按绝对路径逐层检查，避免通过解析symlink重新解释登记路径。
    descriptor = os.open(work.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        current = Path(work.anchor)
        for component in work.parts[1:]:
            following = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor); descriptor = following
            current /= component
            value = os.fstat(descriptor)
            if current.is_relative_to(parent) and value.st_uid != os.getuid():
                raise PipelineError("Candidate directory is not owned")
        if stat.S_IMODE(os.fstat(descriptor).st_mode) & 0o077:
            raise PipelineError("Candidate directory must remain private")
    finally: os.close(descriptor)


@contextmanager
def cancellation_signals():
    if threading.current_thread() is not threading.main_thread():
        raise PipelineError("Notary delivery must run on the CLI main thread")
    saved = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    state = {"signal": None, "interruptible": False}
    def interrupted(value, frame):
        state["signal"] = value
        # Popen赋值前只记意图；拥有具体process后才能抛出并准确收口。
        if state["interruptible"]:
            # 不使用InterruptedError：系统等待实现可以把它视为EINTR而重试。
            raise OperatorCancelled("Notary operator interrupted by signal " + str(value))
    try:
        for value in saved: signal.signal(value, interrupted)
        yield state
    finally:
        for value, handler in saved.items(): signal.signal(value, handler)


class OperatorCancelled(Exception):
    pass


def invoke_notary(arguments, directory, label, timeout):
    with cancellation_signals() as cancellation:
        return _invoke_notary(arguments, directory, label, timeout, cancellation)


class NotaryCommandError(PipelineError):
    def __init__(self, message, response=None):
        super().__init__(message)
        self.response = response


def response_json(path):
    try:
        if regular(path).st_size <= 1024 * 1024:
            value = json.loads(path.read_bytes())
            if isinstance(value, dict): return value
    except (OSError, ValueError): pass
    return None


def _invoke_notary(arguments, directory, label, timeout, cancellation):
    """stdout只存JSON，stderr独立保留；墙钟超时只中断本次创建的进程。"""
    token = str(time.time_ns())
    output, errors = directory / (label + "-" + token + ".json"), directory / (label + "-" + token + ".stderr.log")
    with output.open("xb") as out, errors.open("xb") as err:
        process = subprocess.Popen(["xcrun", "notarytool", *map(str, arguments), "--output-format", "json"],
                                   stdout=out, stderr=err, start_new_session=True)
        def stop():
            cancellation["interruptible"] = False
            if process.poll() is not None: return
            process.send_signal(signal.SIGINT)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        try:
            cancellation["interruptible"] = True
            if cancellation["signal"] is not None: raise OperatorCancelled("Notary operator interrupted during child creation")
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop()
            raise NotaryCommandError("Notary wall-clock timeout; submission outcome may be unknown. Retain " + str(directory), response_json(output))
        except BaseException as error:
            stop()
            raise NotaryCommandError("Notary command was interrupted; retain " + str(directory), response_json(output)) from error
        finally: cancellation["interruptible"] = False
    result = response_json(output)
    if code: raise NotaryCommandError("Notary command failed; retain " + str(errors), result)
    if result is None: raise NotaryCommandError("Notary returned no complete JSON; retain " + str(output))
    return result


def submission_id(value):
    try:
        normalized = str(uuid.UUID(value))
        if normalized != value.lower(): raise ValueError()
        return normalized
    except (ValueError, TypeError, AttributeError): raise PipelineError("Notary returned no valid submission ID")


def validate_binding(binding):
    expected = {"source", "version", "role", "teamID", "qualificationSHA256", "coreCI"}
    if (not isinstance(binding, dict) or set(binding) != expected or
            binding.get("role") not in ("app", "dmg") or type(binding.get("coreCI")) is not int or binding["coreCI"] <= 0 or
            not isinstance(binding.get("source"), dict) or binding["source"].get("dirty") is not False):
        raise PipelineError("Notary request has no frozen release binding")
    validate_version(binding.get("version", ""))
    if not isinstance(binding.get("teamID"), str) or not re.fullmatch(r"[A-Z0-9]{10}", binding["teamID"]):
        raise PipelineError("Notary binding has no signing team")
    for value, length in ((binding["source"].get("commit"), 40), (binding.get("qualificationSHA256"), 64)):
        if not isinstance(value, str) or len(value) != length or any(c not in "0123456789abcdef" for c in value):
            raise PipelineError("Notary binding has an invalid source or qualification digest")


def require_schema(state):
    if type(state.get("schemaVersion")) is not int or state["schemaVersion"] != 1:
        raise PipelineError("Unsupported delivery receipt schema")


def validate_request(state, receipt=None):
    require_schema(state)
    validate_binding(state.get("binding"))
    if (state.get("state") not in
            ("submission-unknown", "submitted", "pending", "rejected", "accepted")):
        raise PipelineError("Invalid notary request state")
    payload = state.get("payload")
    if (not isinstance(payload, dict) or set(payload) != {"path", "sha256", "bytes", "device", "inode"} or
            not isinstance(payload.get("path"), str) or not Path(payload["path"]).is_absolute() or
            ".." in Path(payload["path"]).parts or
            not re.fullmatch(r"[0-9a-f]{64}", str(payload.get("sha256"))) or
            any(type(payload.get(k)) is not int or payload[k] < 0 for k in ("bytes", "device", "inode"))):
        raise PipelineError("Invalid frozen notary input")
    if receipt is not None and Path(payload["path"]).parent != Path(receipt).absolute().parent:
        raise PipelineError("Notary input is outside its request directory")
    if Path(payload["path"]).suffix != (".zip" if state["binding"]["role"] == "app" else ".dmg"):
        raise PipelineError("Notary input does not match its App/DMG role")
    if state.get("submissionID") is not None: submission_id(state["submissionID"])
    if state.get("state") == "accepted":
        proof = state.get("serviceProof", {})
        if (state.get("payloadVerified") is not True or proof.get("jobId") != state.get("submissionID") or
                proof.get("status") != "Accepted" or proof.get("sha256") != state["payload"]["sha256"]):
            raise PipelineError("Accepted request has no matching service proof")


def preflight_request(receipt, expected_binding=None):
    state = read_receipt(receipt)
    validate_request(state, receipt)
    if expected_binding is not None and state["binding"] != expected_binding:
        raise PipelineError("Notary receipt belongs to another release")
    if file_record(state["payload"]["path"]) != state["payload"]:
        raise PipelineError("Notary input changed; no service query was made")
    return state


def query_request(receipt, profile, *, expected_binding=None, attach_id=None, wait=False):
    """从不调用submit；未知ID只能显式附加，且服务端日志必须确认精确输入SHA。"""
    receipt = Path(receipt)
    with exclusive(receipt.with_suffix(".lock")):
        state = preflight_request(receipt, expected_binding)
        existing = state.get("submissionID")
        if existing and attach_id and submission_id(attach_id) != existing:
            raise PipelineError("A different submission ID is already recorded")
        identifier = submission_id(existing or attach_id)
        # --timeout限制服务器轮询；外层墙钟同时限制认证、预检和网络等待。
        action = ["wait", identifier, "--timeout", "20m"] if wait else ["info", identifier]
        info = invoke_notary([*action, "--keychain-profile", profile], receipt.parent, "status", 1260 if wait else 60)
        if submission_id(info.get("id")) != identifier: raise PipelineError("Notary response ID differs")
        status = info.get("status")
        if status != "Accepted":
            if existing:
                if status == "In Progress": state["state"] = "pending"
                elif status in ("Invalid", "Rejected"): state["state"] = "rejected"
                state["serviceStatus"] = status
                durable_json(receipt, state)
            raise PipelineError("Notary request is not Accepted: " + str(status))
        proof = invoke_notary(["log", identifier, "--keychain-profile", profile], receipt.parent, "proof", 60)
        if (proof.get("jobId") != identifier or proof.get("status") != "Accepted" or
                proof.get("sha256") != state["payload"]["sha256"]):
            raise PipelineError("Apple notary log does not match the frozen payload")
        if file_record(state["payload"]["path"]) != state["payload"]:
            raise PipelineError("Notary input changed during service query")
        state.update(submissionID=identifier, state="accepted", serviceStatus="Accepted", payloadVerified=True,
                     serviceProof={key: proof.get(key) for key in ("jobId", "status", "sha256", "archiveFilename")})
        durable_json(receipt, state)
        return identifier


def notarize(payload, profile, receipt, binding):
    receipt, payload = Path(receipt), Path(payload)
    validate_binding(binding)
    mkdir_durable(receipt.parent)
    # 提交前持久化未知状态。崩溃发生在远端上传与本地写ID之间，也不会自动重投。
    with exclusive(receipt.with_suffix(".lock")):
        frozen = file_record(payload)
        if receipt.exists():
            state = read_receipt(receipt)
            validate_request(state, receipt)
            if state.get("binding") != binding or state.get("payload") != frozen:
                raise PipelineError("Existing notary request has different source or payload")
            if not state.get("submissionID"):
                raise PipelineError("Prior submission has no ID; outcome unknown. Use notary-status with a verified service ID; never auto-resubmit")
            if state.get("state") == "accepted" and state.get("payloadVerified") is True:
                return submission_id(state["submissionID"])
        else:
            state = {"schemaVersion": 1, "binding": binding, "payload": frozen, "state": "submission-unknown", "submissionID": None}
            durable_json(receipt, state)
            try:
                result = invoke_notary(["submit", payload, "--no-wait", "--keychain-profile", profile], receipt.parent, "submit", 120)
            except NotaryCommandError as error:
                if error.response and error.response.get("id"):
                    state.update(submissionID=submission_id(error.response["id"]), state="submitted", lastCommandOutcome="failed-or-interrupted")
                    durable_json(receipt, state)
                raise
            state.update(submissionID=submission_id(result.get("id")), state="submitted")
            durable_json(receipt, state)
    return query_request(receipt, profile, expected_binding=binding, wait=True)


class FrozenFiles:
    """单候选里的文件步骤：有完成回执才可复用，未完成产物保持原状并停止。"""
    def __init__(self, work): self.work = Path(work)

    def file(self, key, path, producer, *, rebuild=False):
        path, receipt = Path(path), self.work / (key + "-file.json")
        if receipt.exists():
            expected = read_receipt(receipt)
            if expected != file_record(path): raise PipelineError("Frozen package input changed: " + key)
        else:
            if path.exists() or path.is_symlink():
                if not rebuild:
                    raise PipelineError("Uncheckpointed package input was retained: " + str(path))
                regular(path)
                retained = self.work / ("incomplete-" + key + "-" + str(uuid.uuid4()) + path.suffix)
                durable_rename(path, retained)
                durable_json(retained.with_suffix(retained.suffix + ".json"), file_record(retained))
            producer()
            path.chmod(0o400)
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
            # 冻结输入也约束后续协作步骤；不声称阻止同UID恶意进程重新chmod。
            durable_json(receipt, file_record(path))
        return path
