"""把实际加载的独立服务文件与已锁定wheel逐字节核对；不把仅运行前后相同当成官方原件。"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

def site_snapshot(site):
    files = {}
    for path in sorted(site.rglob('*')):
        if path.is_symlink() or not path.resolve().is_relative_to(site.resolve()): raise ValueError('Unexpected installed symlink')
        if path.is_file(): files[str(path.relative_to(site))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files

def capture_installation(root):
    root = Path(root)
    sites = list((root/'venv/lib').glob('python*/site-packages'))
    if len(sites)!=1 or not sites[0].resolve().is_relative_to(root.resolve()): raise ValueError('Ambiguous installed environment')
    python = root/'venv/bin/python3'; cfg = root/'venv/pyvenv.cfg'
    values = dict(line.split('=',1) for line in cfg.read_text().splitlines() if '=' in line)
    if next((value.strip().lower() for key,value in values.items() if key.strip()=='include-system-site-packages'),None) != 'false': raise ValueError('System site-packages must stay disabled')
    return {'pythonExecutable':str(python.resolve(strict=True)),'pythonSHA256':hashlib.sha256(python.read_bytes()).hexdigest(),
            'pyvenvSHA256':hashlib.sha256(cfg.read_bytes()).hexdigest(),'siteFiles':site_snapshot(sites[0])}

def verify_environment(root, environment):
    root = Path(root)
    version=environment.get('pythonVersion')
    if not isinstance(version,list) or len(version)!=3 or any(type(value) is not int or value<0 for value in version) or tuple(version[:2])<(3,10): raise ValueError('Invalid interpreter version evidence')
    if Path(environment['python']) != root/'venv/bin/python3' or Path(environment['workingDirectory']) != root/'work': raise ValueError('Execution escaped the verified environment')
    for directory in (root/'work', root/'venv', root/'venv/bin', root/'venv/lib'):
        if directory.is_symlink() or not directory.is_dir() or not directory.resolve().is_relative_to(root.resolve()): raise ValueError('Execution directory escaped its owned environment')
    installation = root/'installation.json'
    if installation.is_symlink() or hashlib.sha256(installation.read_bytes()).hexdigest() != environment['installationSHA256']: raise ValueError('Installation manifest changed')
    if json.loads(installation.read_text()) != capture_installation(root): raise ValueError('Interpreter, startup configuration or complete installation tree changed')
    lock = root / "requirements.lock"
    if lock.is_symlink() or hashlib.sha256(lock.read_bytes()).hexdigest() != environment["lockSHA256"]: raise ValueError("Dependency lock changed")
    sites = list((root / "venv/lib").glob("python*/site-packages"))
    if len(sites) != 1: raise ValueError("Ambiguous owned site-packages")
    site = sites[0]
    if not site.resolve().is_relative_to(root.resolve()): raise ValueError("Installed environment escaped its owned directory")
    rows = environment["dependencies"]
    if not 2 <= len(rows) <= 64: raise ValueError("Unexpected dependency count")
    files = {}
    for row in rows:
        name = row["file"]
        if Path(name).name != name or not name.endswith(".whl"): raise ValueError("Invalid wheel name")
        wheel = root / "wheelhouse" / name
        if wheel.is_symlink() or hashlib.sha256(wheel.read_bytes()).hexdigest() != row["sha256"]: raise ValueError("Wheel changed")
        with zipfile.ZipFile(wheel) as archive:
            for info in archive.infolist():
                if info.is_dir(): continue
                relative = PurePosixPath(info.filename)
                if relative.is_absolute() or ".." in relative.parts or any(part.endswith(".data") for part in relative.parts): raise ValueError("Unsupported relocated wheel member")
                if info.filename.endswith(".dist-info/RECORD"): continue # pip重新生成安装清单。
                path = site / info.filename
                if path.is_symlink() or not path.resolve().is_relative_to(site.resolve()) or not path.is_file() or info.file_size > 32*1024*1024: raise ValueError("Installed wheel member is missing or changed")
                expected = hashlib.sha256(archive.read(info)).hexdigest()
                if hashlib.sha256(path.read_bytes()).hexdigest() != expected: raise ValueError("Installed dependency differs from pinned wheel: "+row["name"])
                if info.filename in files and files[info.filename] != expected: raise ValueError("Dependency files overlap")
                files[info.filename] = expected
                if len(files)>20_000: raise ValueError("Dependency file count exceeds budget")
    return {"files":len(files),"SHA256":hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest()}
