#!/usr/bin/env python3
"""安装/回退已构建的KeyDock；不修改用户配置、Keychain、TCC或quarantine。"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import uuid

from keydock_common import CONFIG, PipelineError, inspect_app, run, atomic_json, validate_data_compatibility, task_material_readers
from invocation_compatibility import runtime_data_root, probe_versions, runtime_data_lease
from task_material_compatibility import probe_task_materials

ALLOWED_IDS = {"com.arthurwangwsx.KeyDock", "com.arthurwangwsx.KeyDock.preview"}
IDENTITY_KEYS = ("bundle_id", "version", "release_version", "build_number", "profile", "commit",
                 "safe_smoke", "source_dirty", "bundle_sha256", "code_signature", "notarized")
RENAME_SWAP, RENAME_EXCL = 0x00000002, 0x00000004


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def plain_path(value):
    path = Path(os.path.abspath(os.path.expanduser(str(value))))
    # 不先resolve，否则会把用户指定的symlink和父路径symlink隐藏掉。
    for component in (path,) + tuple(path.parents):
        if component.is_symlink():
            raise PipelineError("Symlink paths are not allowed: " + str(component))
    return path


def inside(path, directory):
    return os.path.commonpath((str(path), str(directory))) == str(directory)


def app_path(value, create_parents=False):
    path = plain_path(value)
    if path.suffix.lower() != ".app" or (not path.parent.is_dir() and not (create_parents and not path.parent.exists())):
        raise PipelineError("An .app path with an existing parent directory is required")
    return path


def identity(path):
    path = plain_path(path)
    if not path.is_dir():
        raise PipelineError("App directory is missing: " + str(path))
    info = inspect_app(path)
    if info.get("bundle_id") not in ALLOWED_IDS:
        raise PipelineError("Only the canonical or preview KeyDock bundle ID is allowed")
    if not isinstance(info.get("bundle_sha256"), str) or len(info["bundle_sha256"]) != 64:
        raise PipelineError("App resource-tree digest is unavailable")
    return {key: info.get(key) for key in IDENTITY_KEYS}


def verify_copy(path, expected):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])
    if identity(path) != expected:
        raise PipelineError("App identity or resource-tree digest changed: " + str(path))


def require_data_compatible(app, expected, resolver, guard=None):
    facts = inspect_app(app)
    if {key: facts.get(key) for key in IDENTITY_KEYS} != expected:
        raise PipelineError("Candidate App identity changed during its data check")
    capability = validate_data_compatibility(facts.get("data_compatibility"))
    root = plain_path(resolver(facts))
    if guard is not None and root != guard.root:
        raise PipelineError("Candidate runtime data domain changed")
    versions = probe_versions(root, guard)
    readers = capability["invocationEnvelope"]["readVersions"]
    if any(version is not None and version not in readers for version in versions.values()):
        raise PipelineError("This App cannot read the current invocation data. Apps and records were preserved; use a compatible version")
    materials = probe_task_materials(root, guard)
    material_readers = task_material_readers(capability)
    if not set(materials["requiredVersions"]).issubset(material_readers):
        raise PipelineError("This App cannot read the current task material data. Apps and records were preserved; clear materials in a compatible version before rollback")
    return {"schemaVersion": 2, "profile": facts["profile"], "runtimeDataRoot": str(root),
            "readerVersions": readers, "envelopes": versions, "provisional": guard is None,
            "taskMaterialReaders": material_readers, "taskMaterials": materials,
            "scope": "default runtime domain; custom Preview TMPDIR domains are not discovered"}


def distribution_policy(info, allow_preview):
    signature = info.get("code_signature") or {}
    if info.get("profile") == "release" and (signature.get("kind") != "developer-id" or signature.get("team_id") != CONFIG["teamID"]):
        raise PipelineError("The canonical App must use this project's Developer ID team")
    if info.get("profile") != "preview" and info.get("source_dirty") is True:
        raise PipelineError("A release-profile App must come from clean committed source")
    if signature.get("kind") not in ("developer-id", "adhoc"):
        raise PipelineError("App has no supported code signature")
    trusted = (info.get("notarized") is True and signature.get("kind") == "developer-id"
               and signature.get("hardened_runtime") is True and bool(signature.get("team_id")))
    preview = info.get("profile") == "preview" and info.get("bundle_id") == CONFIG["previewBundleIdentifier"]
    if not trusted and not (allow_preview and preview):
        raise PipelineError("A notarized Developer ID App is required; only an explicit isolated Preview may opt out")
    if info["bundle_id"] == "com.arthurwangwsx.KeyDock" and info.get("safe_smoke") is True:
        raise PipelineError("A SafeSmoke App cannot replace the canonical KeyDock installation")


def helper_path(value):
    path = plain_path(value)
    if not path.is_file() or not os.access(str(path), os.X_OK):
        raise PipelineError("An executable native lifecycle helper is required")
    return path


def running_at_destination(helper, bundle_id, destination):
    raw = run([str(helper), "status", "--bundle-id", bundle_id], capture=True)
    if not isinstance(raw, str) or len(raw) > 131_072:
        raise PipelineError("Invalid lifecycle status")
    try:
        report = json.loads(raw)
        processes = report["processes"]
        if report["bundle_id"] != bundle_id or not isinstance(processes, list):
            raise ValueError()
        running = []
        for process in processes:
            if process["bundle_id"] != bundle_id or type(process["running"]) is not bool:
                raise ValueError()
            if not process["running"]:
                continue
            pid, path = process["pid"], process["path"]
            if type(pid) is not int or pid <= 0 or not isinstance(path, str) or not os.path.isabs(path):
                raise ValueError()
            if os.path.normpath(path) != str(destination):
                raise PipelineError("Another process with this bundle ID is running outside the destination; nothing was quit")
            running.append(pid)
        return running
    except (ValueError, KeyError, TypeError):
        raise PipelineError("Invalid lifecycle status")


def quiesce(helper, bundle_id, destination, quit_running):
    running = running_at_destination(helper, bundle_id, destination)
    if running:
        if not quit_running:
            raise PipelineError("The destination App is running; quit it or pass --quit-running")
        run([str(helper), "quit", "--bundle-id", bundle_id, "--allowed-path", str(destination), "--timeout", "20"], capture=True)
    if running_at_destination(helper, bundle_id, destination):
        raise PipelineError("The destination App is still running; replacement was not attempted")


@contextlib.contextmanager
def installation_lock(destination):
    lock_path = plain_path(destination.parent / ("." + destination.name + ".keydock-install.lock"))
    descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise PipelineError("The installation lock is not an owned regular file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PipelineError("Another installation or rollback is in progress")
        yield
    finally:
        os.close(descriptor)
    # 不unlink锁文件，避免等待旧inode的调用与新锁文件产生两把锁。


def atomic_rename(source, destination, flags):
    if sys.platform != "darwin":
        raise PipelineError("Atomic App installation requires macOS")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(str(source)), os.fsencode(str(destination)), flags) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(destination))
    descriptor = os.open(str(destination.parent), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def expected_current(destination, expected):
    plain_path(destination)
    if expected is None:
        if destination.exists():
            raise PipelineError("The destination appeared after preflight")
    elif identity(destination) != expected:
        raise PipelineError("The destination changed after preflight; nothing was overwritten")


def save_receipt(path, record, state):
    record["state"] = state
    record["updated_at"] = now()
    atomic_json(path, record)
    descriptor = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def compensate_install(destination, exchange, previous, installed, helper, resolver, data_guard):
    # 只对身份仍完全匹配的本次交换补偿，绝不覆盖之后出现的其他App。
    expected_current(destination, installed)
    if running_at_destination(helper, installed["bundle_id"], destination):
        raise PipelineError("Compensation cannot replace a running App")
    if previous is None:
        if exchange.exists():
            raise PipelineError("The staging path was unexpectedly reused")
        atomic_rename(destination, exchange, RENAME_EXCL)
    else:
        verify_copy(exchange, previous)
        require_data_compatible(exchange, previous, resolver, data_guard)
        atomic_rename(destination, exchange, RENAME_SWAP)
        verify_copy(destination, previous)


def install(args, *, data_root_resolver=None):
    resolver = data_root_resolver or runtime_data_root
    create_parents = getattr(args, "create_parents", False)
    source, destination, receipt = plain_path(args.app), app_path(args.destination, create_parents), plain_path(args.receipt)
    helper = helper_path(args.helper)
    if inside(source, destination) or inside(destination, source):
        raise PipelineError("Source and destination Apps must not overlap")
    if inside(receipt, source) or inside(receipt, destination) or (not receipt.parent.is_dir() and not (create_parents and not receipt.parent.exists())):
        raise PipelineError("Receipt must be outside both Apps in an existing directory")
    if receipt.exists():
        raise PipelineError("Receipt already exists; choose a new receipt path")
    installed = identity(source)
    distribution_policy(installed, args.allow_unnotarized_preview)
    data_check = require_data_compatible(source, installed, resolver)
    previous = identity(destination) if destination.exists() else None
    if previous is not None and previous["bundle_id"] != installed["bundle_id"]:
        raise PipelineError("Destination has a different bundle ID")
    if previous is not None and previous.get("profile") == "release" and previous.get("code_signature", {}).get("team_id") != CONFIG["teamID"]:
        raise PipelineError("The existing App belongs to another signing team; it was preserved")
    if destination.exists() and destination.stat().st_dev != destination.parent.stat().st_dev:
        raise PipelineError("Destination must be on its parent volume")
    running = running_at_destination(helper, installed["bundle_id"], destination)
    if running and not args.quit_running:
        raise PipelineError("The destination App is running; quit it or pass --quit-running")
    transaction = str(uuid.uuid4())
    exchange = destination.parent / ("." + destination.name + ".keydock-backup-" + transaction + ".app")
    record = {"schema_version": 1, "transaction_id": transaction, "created_at": now(),
              "source": str(source), "destination": str(destination), "helper": str(helper),
              "exchange_path": str(exchange), "backup_path": str(exchange) if previous else None,
              "installed": installed, "previous": previous, "rollback_available": previous is not None,
              "rollback_note": "App backup exists; current data compatibility is checked again before rollback", "data_check": data_check}
    if args.dry_run:
        return dict(record, state="dry-run", would_quit=running)
    if create_parents:
        destination.parent.mkdir(parents=True, exist_ok=True)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        plain_path(destination); plain_path(receipt)
    with installation_lock(destination), contextlib.ExitStack() as stack:
        expected_current(destination, previous)
        descriptor = os.open(str(receipt), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        attempted = False
        data_guard = None
        try:
            if exchange.exists() or exchange.is_symlink():
                raise PipelineError("The staging path already exists")
            exchange.mkdir(mode=0o700)
            run(["/usr/bin/ditto", str(source), str(exchange)])
            # ditto向已存在目录合并时保留其根权限；验证前恢复源App的根权限。
            os.chmod(exchange, stat.S_IMODE(source.stat().st_mode))
            verify_copy(exchange, installed)
            if exchange.stat().st_dev != destination.parent.stat().st_dev:
                raise PipelineError("Staging must be on the destination volume")
            save_receipt(receipt, record, "prepared")
            quiesce(helper, installed["bundle_id"], destination, args.quit_running)
            expected_current(destination, previous)
            data_guard = stack.enter_context(runtime_data_lease(plain_path(resolver(inspect_app(exchange)))))
            record["data_check"] = require_data_compatible(exchange, installed, resolver, data_guard)
            # 先标记attempted；即使rename后发生信号/异常，也不能把旧备份当候选删除。
            attempted = True
            atomic_rename(exchange, destination, RENAME_SWAP if previous else RENAME_EXCL)
            verify_copy(destination, installed)
            if previous is not None:
                verify_copy(exchange, previous)
            save_receipt(receipt, record, "installed")
            return record
        except BaseException as error:
            state = "failed-before-exchange"
            if attempted:
                try:
                    # 若原子调用未生效，原目标和候选仍匹配；无需再交换。
                    expected_current(destination, previous)
                    verify_copy(exchange, installed)
                    state = "failed-before-exchange"
                except Exception:
                    try:
                        compensate_install(destination, exchange, previous, installed, helper, resolver, data_guard)
                        state = "compensated"
                    except Exception:
                        state = "needs-recovery"
            try:
                save_receipt(receipt, record, state)
            except Exception:
                pass
            raise PipelineError("Installation failed (" + state + "); App paths were preserved: " + str(error)) from error


def rollback(args, *, data_root_resolver=None):
    resolver = data_root_resolver or runtime_data_root
    receipt = plain_path(args.rollback)
    if not receipt.is_file() or receipt.stat().st_size > 131_072:
        raise PipelineError("A bounded installation receipt file is required")
    record = json.loads(receipt.read_text(encoding="utf-8"))
    if record.get("schema_version") != 1 or record.get("state") not in ("prepared", "installed", "rollback-prepared", "rolled-back"):
        raise PipelineError("This receipt does not describe a rollback-capable installation")
    transaction = str(uuid.UUID(record["transaction_id"]))
    destination = app_path(record["destination"])
    exchange = plain_path(record["exchange_path"])
    expected_exchange = destination.parent / ("." + destination.name + ".keydock-backup-" + transaction + ".app")
    previous, installed = record.get("previous"), record["installed"]
    if exchange != expected_exchange or record.get("backup_path") != str(exchange) or previous is None:
        raise PipelineError("No original App backup is available for this receipt")
    if inside(receipt, destination) or inside(receipt, exchange):
        raise PipelineError("Receipt must be outside the installed and backup Apps")
    if installed.get("bundle_id") not in ALLOWED_IDS or previous.get("bundle_id") != installed["bundle_id"]:
        raise PipelineError("Receipt bundle identities are invalid")
    # 回执中的helper仅供审计，不作为执行任意程序的授权。
    default_helper = Path(__file__).resolve().parents[1] / "build/pipeline/tools/KeyDockLifecycle"
    helper = helper_path(args.helper or default_helper)
    if record["state"] in ("rollback-prepared", "rolled-back"):
        if identity(destination) == previous and identity(exchange) == installed:
            check = require_data_compatible(destination, previous, resolver)
            return dict(record, state="rolled-back", already_rolled_back=True, data_check=check)
        if record["state"] == "rolled-back":
            raise PipelineError("Apps changed after rollback; nothing was overwritten")
    verify_copy(destination, installed)
    verify_copy(exchange, previous)
    distribution_policy(identity(destination), True)
    distribution_policy(identity(exchange), True)
    check = require_data_compatible(exchange, previous, resolver)
    running = running_at_destination(helper, installed["bundle_id"], destination)
    if running and not args.quit_running:
        raise PipelineError("The destination App is running; quit it or pass --quit-running")
    if args.dry_run:
        return dict(record, state="rollback-dry-run", would_quit=running, data_check=check)
    with installation_lock(destination), contextlib.ExitStack() as stack:
        verify_copy(destination, installed)
        verify_copy(exchange, previous)
        quiesce(helper, installed["bundle_id"], destination, args.quit_running)
        verify_copy(destination, installed)
        verify_copy(exchange, previous)
        data_guard = stack.enter_context(runtime_data_lease(plain_path(resolver(inspect_app(exchange)))))
        record["data_check"] = require_data_compatible(exchange, previous, resolver, data_guard)
        save_receipt(receipt, record, "rollback-prepared")
        attempted = False
        try:
            attempted = True
            atomic_rename(destination, exchange, RENAME_SWAP)
            verify_copy(destination, previous)
            verify_copy(exchange, installed)
            save_receipt(receipt, record, "rolled-back")
            return record
        except BaseException as error:
            state = "rollback-prepared"
            if attempted:
                try:
                    # 原子调用未生效则保留installed状态，允许以后安全重试。
                    verify_copy(destination, installed)
                    verify_copy(exchange, previous)
                    state = "installed"
                except Exception:
                    try:
                        verify_copy(destination, previous)
                        verify_copy(exchange, installed)
                        if running_at_destination(helper, installed["bundle_id"], destination):
                            raise PipelineError("Compensation cannot replace a running App")
                        require_data_compatible(exchange, installed, resolver, data_guard)
                        atomic_rename(destination, exchange, RENAME_SWAP)
                        verify_copy(destination, installed)
                        state = "installed"
                    except Exception:
                        state = "needs-recovery"
            try:
                save_receipt(receipt, record, state)
            except Exception:
                pass
            raise PipelineError("Rollback failed (" + state + "); both App paths were preserved: " + str(error)) from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app")
    parser.add_argument("--destination")
    parser.add_argument("--receipt")
    parser.add_argument("--rollback", metavar="RECEIPT")
    parser.add_argument("--helper", help="Trusted native lifecycle helper; rollback defaults to build/pipeline/tools/KeyDockLifecycle")
    parser.add_argument("--quit-running", action="store_true", help="Request graceful quit only at the exact destination path")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--create-parents", action="store_true", help="Create missing parents only after full installation preflight")
    parser.add_argument("--allow-unnotarized-preview", action="store_true")
    args = parser.parse_args(argv)
    if args.rollback:
        if any((args.app, args.destination, args.receipt, args.allow_unnotarized_preview)):
            parser.error("--rollback cannot be combined with installation arguments")
    elif not all((args.app, args.destination, args.receipt, args.helper)):
        parser.error("installation requires --app, --destination, --receipt and --helper")
    try:
        result = rollback(args) if args.rollback else install(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (PipelineError, OSError, ValueError, KeyError, TypeError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
