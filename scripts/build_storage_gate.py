"""个人Mac共享准入的薄入口；锁、预算与收尾只由共享治理器执行。"""
from pathlib import Path
import os
import sys


def entry(arguments, root, *, tool=None, cwd=None):
    configured = os.environ.get("PERSONAL_BUILD_STORAGE_TOOL")
    path = Path(tool or configured or Path.home() / "project/_workspace/tools/build_storage.py")
    if not path.is_file():
        if tool is not None or configured or path.parent.parent.is_dir():
            raise RuntimeError("Shared build storage tool is unavailable; no pipeline was started")
        # 其他开源开发机及CI没有这套个人Mac治理器，保留工程自身的容量检查。
        return None
    budgets = {"release": 12, "build": 8, "debug": 8, "check": 4, "performance": 4,
               "package": 4, "prepare-mcp-interop": 2, "mcp-interop": 4, "desktop-review-build": 12, "desktop-review": 4}
    command = arguments[0] if arguments else "--help"
    expected = 0 if command in ("doctor", "--help", "-h") else budgets.get(command, 2)
    # 固定调用导入后的run_cli，避免重入本入口；嵌套租约仍由共享治理器核验，不能只凭环境变量跳过。
    payload = "import sys; sys.path.insert(0, " + repr(str(Path(root) / "scripts")) + "); from keydock import run_cli; raise SystemExit(run_cli())"
    return [sys.executable, str(path), "run", "--source-root", str(Path(root).resolve()),
            "--command-cwd", str(Path(cwd or Path.cwd()).resolve()), "--expected-gib", str(expected), "--",
            sys.executable, "-c", payload, *map(str, arguments)]
