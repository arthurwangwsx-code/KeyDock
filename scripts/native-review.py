#!/usr/bin/env python3
"""建立owned合成Preview域并等待正常退出；不使用或迁移默认Preview／正式用户数据。"""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid

from keydock_common import ROOT, PipelineError, atomic_json, inspect_app


def validate_fixture(root, evidence_parent):
    if not root.is_absolute() or root.is_symlink() or root.resolve(strict=True) != root or not root.is_relative_to(evidence_parent.resolve(strict=True)):
        raise PipelineError("Review fixture must remain in this project's owned desktop evidence folder")
    try:
        if not root.name.startswith("KeyDock-Review-"):
            raise ValueError()
        uuid.UUID(root.name.removeprefix("KeyDock-Review-"))
    except ValueError:
        raise PipelineError("Review fixture requires its own UUID directory") from None
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise PipelineError("Review fixture directory is not private and owned")
        marker = os.open("synthetic-review.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
        try:
            info = os.fstat(marker)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 4096:
                raise PipelineError("Review fixture marker is not private and owned")
            if json.loads(os.read(marker, 4097)) != {"fixture": "keydock-native-review-v1"}:
                raise PipelineError("Review fixture marker is invalid")
        finally:
            os.close(marker)
    finally:
        os.close(descriptor)


def open_private_log(root):
    descriptor = os.open(root / "process.log", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        os.close(descriptor)
        raise PipelineError("Review process log is not a private owned regular file")
    return os.fdopen(descriptor, "ab")


def new_observation(root):
    observation = root / ("run-" + str(uuid.uuid4()))
    observation.mkdir(mode=0o700, exist_ok=False)
    return observation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, help="Reuse an existing owned synthetic review root for restart checks")
    parser.add_argument("--task-views", nargs=2, type=uuid.UUID, metavar=("FIRST", "SECOND"),
                        help="Render these two tasks inside the owned Preview workspace")
    args = parser.parse_args()
    app = args.app.expanduser().resolve(strict=True)
    facts = inspect_app(app)
    if facts["profile"] != "preview" or not facts["safe_smoke"]:
        raise PipelineError("Native review requires an isolated Preview App")
    if args.fixture is None:
        parent = ROOT / ".local/desktop"
        parent.mkdir(parents=True, exist_ok=True)
        if parent.is_symlink() or parent.resolve(strict=True) != parent:
            raise PipelineError("Review evidence parent must not contain symbolic links")
        root = parent / ("KeyDock-Review-" + str(uuid.uuid4()))
        root.mkdir(mode=0o700)
        atomic_json(root / "synthetic-review.json", {"fixture": "keydock-native-review-v1"})
    else:
        root = args.fixture.expanduser().absolute()
    validate_fixture(root, ROOT / ".local/desktop")
    # App独立核对private owner、marker和Preview编译／签名metadata；这里没有改安装器resolver。
    executable = app / "Contents/MacOS/KeyDockPreview"
    record = {"schemaVersion": 1, "state": "running", "app": str(app), "bundleSHA256": facts["bundle_sha256"],
              "commit": facts["commit"], "sourceDirty": facts["source_dirty"], "fixture": str(root),
              "dataDirectory": str(root / "KeyDock-Smoke"), "syntheticOnly": True, "pid": None}
    observation = new_observation(root)
    receipt = observation / "review-process.json"
    record.update(observation=str(observation), state="launching")
    atomic_json(observation / "launch.json", record)
    with open_private_log(observation) as output:
        command = [str(executable), "--review-fixture-root", str(root)]
        if args.task_views:
            command += ["--review-task-views", *(str(task) for task in args.task_views)]
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        record.update(pid=child.pid, state="running")
        atomic_json(observation / "started.json", record)
        atomic_json(receipt, record)
        atomic_json(root / "review-process.json", record)
        print(str(receipt), flush=True)
        code = child.wait()
    record.update(state="exited", exitCode=code); atomic_json(receipt, record)
    atomic_json(root / "review-process.json", record)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
