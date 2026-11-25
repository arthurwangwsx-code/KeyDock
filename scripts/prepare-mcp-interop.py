#!/usr/bin/env python3
"""只在全新owned目录准备固定官方Time服务；解析、锁哈希、下载验证后离线安装。"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlparse
import zipfile
from mcp_interop_integrity import capture_installation

ROOT = Path(__file__).resolve().parents[1]
TIME_VERSION = "2026.11.18"
SDK_VERSION = "2.3.0"
TIME_WHEEL_SHA256 = "acb3ba2e0faf812ce49989fbe74d363501cf7720c8d7a103debef9815e838a34"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=shutil.which("python3.13"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    interpreter = Path(args.python or "")
    if not interpreter.is_absolute() or not interpreter.is_file():
        raise ValueError("Pass an installed absolute Python 3.10+ interpreter")
    python_version = json.loads(subprocess.check_output([str(interpreter), "-I", "-c", "import sys,json;print(json.dumps(list(sys.version_info[:3])))"], text=True))
    if tuple(python_version[:2]) < (3, 10): raise ValueError("Python 3.10+ is required")
    output = args.output.resolve()
    allowed = (ROOT / ".local/interop").resolve()
    if not allowed.is_relative_to(ROOT) or not output.resolve().is_relative_to(allowed) or output.exists():
        raise ValueError("Use a new directory under .local/interop; existing runs are retained")
    output.mkdir(parents=True, mode=0o700)
    work = output / "work"; work.mkdir(mode=0o700)
    environment = {key:os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
    def run(name, command):
        with (output / (name+".log")).open("w") as log:
            subprocess.run([str(value) for value in command], cwd=output, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    run("venv", [interpreter, "-I", "-m", "venv", output / "venv"])
    python = output / "venv/bin/python3"
    pip = [python, "-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "--cache-dir", output / "pip-cache"]
    resolution = output / "resolution.json"
    run("resolve", pip+["install", "--index-url", "https://pypi.org/simple", "--dry-run", "--ignore-installed", "--only-binary=:all:", "--report", resolution,
                       "mcp-server-time=="+TIME_VERSION, "mcp=="+SDK_VERSION])
    rows = json.loads(resolution.read_text())["install"]
    if not 2 <= len(rows) <= 64: raise ValueError("Unexpected dependency count")
    records = []
    for row in rows:
        metadata, download = row["metadata"], row["download_info"]
        name, version = metadata["name"], metadata["version"]
        url = urlparse(download["url"])
        digest = download["archive_info"]["hashes"]["sha256"]
        if url.scheme != "https" or url.hostname != "files.pythonhosted.org" or not url.path.endswith(".whl"):
            raise ValueError("Only official PyPI wheels are accepted")
        if not all(char in "0123456789abcdef" for char in digest) or len(digest) != 64: raise ValueError("Missing wheel hash")
        records.append({"name":name,"version":version,"sha256":digest,"file":Path(url.path).name,"sourceURL":download["url"]})
    names = {row["name"].lower().replace("_", "-"):row for row in records}
    if len(names) != len(records) or names["mcp-server-time"]["version"] != TIME_VERSION or names["mcp"]["version"] != SDK_VERSION:
        raise ValueError("Resolution changed the pinned service or SDK")
    if names["mcp-server-time"]["sha256"] != TIME_WHEEL_SHA256: raise ValueError("Official service wheel hash changed")
    lock = output / "requirements.lock"
    lock.write_text("".join(row["name"]+"=="+row["version"]+" --hash=sha256:"+row["sha256"]+"\n" for row in sorted(records,key=lambda value:value["name"])))
    wheels = output / "wheelhouse"; wheels.mkdir()
    run("download", pip+["download", "--index-url", "https://pypi.org/simple", "--only-binary=:all:", "--require-hashes", "--no-deps", "-r", lock, "--dest", wheels])
    notices = output / "notices"; notices.mkdir()
    for row in records:
        wheel = wheels / row["file"]
        if hashlib.sha256(wheel.read_bytes()).hexdigest() != row["sha256"]: raise ValueError("Downloaded wheel differs from lock")
        with zipfile.ZipFile(wheel) as archive:
            for index, info in enumerate(archive.infolist()):
                # 不解包代码，只保留发行包原notices；文件名由宿主生成。
                if ".dist-info/" in info.filename and any(word in info.filename.upper() for word in ("LICENSE", "NOTICE", "COPYING")):
                    if info.file_size > 1_048_576: raise ValueError("Notice exceeds budget")
                    (notices / (row["name"]+"-"+str(index)+".txt")).write_bytes(archive.read(info))
    run("install", pip+["install", "--no-index", "--find-links", wheels, "--only-binary=:all:", "--require-hashes", "--no-deps", "-r", lock])
    run("check", pip+["check"])
    installation = output / "installation.json"
    installation.write_text(json.dumps(capture_installation(output),sort_keys=True,indent=2)+"\n")
    result = {"schemaVersion":2,"status":"PREPARED_NOT_QUALIFIED","python":str(python),"pythonVersion":python_version,"workingDirectory":str(work),"installationSHA256":hashlib.sha256(installation.read_bytes()).hexdigest(),
              "serviceVersion":TIME_VERSION,"sdkVersion":SDK_VERSION,"serviceRevision":"c799c8552b0f27b7a33a7b9233773da144dddcf5",
              "lockSHA256":hashlib.sha256(lock.read_bytes()).hexdigest(),"dependencies":records}
    (output / "environment.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"status":result["status"],"environment":str(output / "environment.json"),"dependencies":len(records),"lockSHA256":result["lockSHA256"]}))

if __name__ == "__main__":
    try: main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print("FAIL: "+str(error),file=sys.stderr); sys.exit(1)
