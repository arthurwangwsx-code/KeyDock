"""同源系统能力资格；云端core检查不能替代生产OCR实际识别。"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess

from keydock_common import CONFIG, ROOT, PipelineError, atomic_json, run, sha256

OCR_ID = "MacAdaptersTests.ContextAndLeaseTests/visionRecognizesOnlyAnOwnedSyntheticImage()"
# SwiftPM执行选择器不含列表中的()后缀，清单校验另外保证只匹配这一例。
OCR_FILTER = "^" + re.escape(OCR_ID[:-2])
SOURCE_FILES = (
    "Packages/MacAdapters/Sources/MacAdapters/DocumentContextService.swift",
    "Packages/MacAdapters/Tests/MacAdaptersTests/ContextAndLeaseTests.swift",
    "scripts/release_quality.py",
    "scripts/keydock.py",
    "scripts/keydock_common.py",
    "release/config.json",
)
STAGES = ("documents", "localizations", "pipeline-tests", "swift-tests", "swift-terminal-lifecycle", "swift-inventory", "lifecycle-helper")
OCR_STAGE = "swift-ocr-qualification"
OCR_MARKER = "KEYDOCK_OCR_QUALIFICATION "
OCR_CONFIG = {"level": "accurate", "automaticLanguage": True, "languageCorrection": True, "revision": 3, "supportedCPUsAssigned": True}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def test_count(text):
    counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", text)
    if "✘" in text or not counts or sum(map(int, counts)) < 1:
        raise PipelineError("Test evidence is missing, empty or failed")
    return sum(map(int, counts))


def assess(logs, source, version, build_number, host, source_hashes, timing_filter, created_at):
    inventory = sorted(set(line.strip() for line in logs["swift-inventory"].splitlines()
                           if re.match(r"^[A-Za-z0-9_]+Tests\.[^\s]+/", line)))
    if not inventory or inventory.count(OCR_ID) != 1:
        raise PipelineError("The discovered test inventory must contain the production OCR case")
    if [item for item in inventory if re.search(OCR_FILTER, item)] != [OCR_ID]:
        raise PipelineError("The OCR execution selector must match exactly the declared qualification case")
    if "visionRecognizesOnlyAnOwnedSyntheticImage" in logs["swift-tests"] or OCR_MARKER in logs["swift-terminal-lifecycle"]:
        raise PipelineError("Production OCR must run in its independent qualification stage")
    timing = [item for item in inventory if re.search(timing_filter, item)]
    core = [item for item in inventory if item != OCR_ID and item not in timing]
    if not core or not timing or OCR_ID in timing:
        raise PipelineError("Core, Terminal and system OCR partitions must be nonempty and disjoint")
    core_count, timing_count = test_count(logs["swift-tests"]), test_count(logs["swift-terminal-lifecycle"])
    if core_count < len(core) or timing_count < len(timing):
        raise PipelineError("Test execution does not cover the discovered partitions")
    python_count = re.search(r"Ran (\d+) tests?\b", logs["pipeline-tests"])
    localization_count = re.search(r"PASS: (\d+) UI keys", logs["localizations"])
    if not python_count or int(python_count[1]) < 1 or not localization_count or int(localization_count[1]) < 1:
        raise PipelineError("Pipeline test or localization evidence is empty")
    summary = {"scope": "cloud-core" if OCR_STAGE not in logs else "native-system",
               "source": source, "version": version, "buildNumber": build_number, "createdAt": created_at,
               "host": host, "sourceFiles": source_hashes,
               "tests": {"inventoryCount": len(inventory), "inventorySHA256": digest(inventory),
                         "coreDeclared": len(core), "terminalDeclared": len(timing), "ocrDeclared": 1,
                         "executedCount": core_count + timing_count, "pipelineTestCount": int(python_count[1]), "localizedKeyCount": int(localization_count[1])},
               "ocr": {"status": "NOT_QUALIFIED", "caseID": OCR_ID},
               "evidence": {name: {"sha256": hashlib.sha256(value.encode()).hexdigest(), "bytes": len(value.encode())} for name, value in logs.items()}}
    if OCR_STAGE in logs:
        count = test_count(logs[OCR_STAGE])
        records = [json.loads(line.split(OCR_MARKER, 1)[1]) for line in logs[OCR_STAGE].splitlines() if line.startswith(OCR_MARKER)]
        if count != 1 or len(records) != 1:
            raise PipelineError("System OCR must produce exactly one actual qualification record")
        observation = records[0]
        rounds = observation.get("rounds", [])
        if (observation.get("configuration") != OCR_CONFIG or len(rounds) != 2 or
            any(item != {"usedOCR": True, "hasKeyDock": True, "hasSynthetic": True} for item in rounds) or
            not re.fullmatch(r"[0-9a-f]{64}", observation.get("fixtureSHA256", ""))):
            raise PipelineError("Production accurate OCR did not recognize both cold-process and repeated inputs")
        summary["tests"]["executedCount"] += count
        summary["ocr"] = {"status": "PASS", "caseID": OCR_ID, **observation}
    return summary


def host_facts():
    return {"system": platform.system(), "architecture": platform.machine(), "osVersion": platform.mac_ver()[0],
            "osBuild": run(["/usr/bin/sw_vers", "-buildVersion"], capture=True).strip(),
            "chip": run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture=True).strip(),
            "swift": run(["xcrun", "swift", "--version"], capture=True).splitlines()[0],
            "xcode": run(["xcrun", "xcodebuild", "-version"], capture=True).strip(),
            "sdkVersion": run(["xcrun", "--show-sdk-version"], capture=True).strip(),
            "sdkBuild": run(["xcrun", "--show-sdk-build-version"], capture=True).strip()}


def record_check(directory, source, ci, timing_filter, expected_host):
    names = STAGES if ci else STAGES + (OCR_STAGE,)
    logs = {}
    for name in names:
        if json.loads((directory / (name + ".json")).read_text())["exitCode"] != 0:
            raise PipelineError("Qualification cannot consume a failed stage")
        logs[name] = (directory / (name + ".log")).read_bytes().decode("utf-8")
    if host_facts() != expected_host:
        raise PipelineError("OS or toolchain changed while checking; no qualification was issued")
    summary = assess(logs, source, CONFIG["version"], CONFIG["buildNumber"], expected_host,
                     {path: sha256(ROOT / path) for path in SOURCE_FILES}, timing_filter,
                     datetime.now(timezone.utc).isoformat())
    atomic_json(directory / "check-summary.json", summary)
    if not ci and not source["dirty"]:
        validate_public(summary, source, CONFIG["version"], CONFIG["buildNumber"])
        receipt = {"summary": summary, "timingFilter": timing_filter,
                   "logs": {name: str((directory / (name + ".log")).relative_to(ROOT)) for name in names}}
        atomic_json(directory / "qualification.json", receipt)
        # 同一发行源重跑检查时保留已装入App的资格摘要，避免覆盖不可变包的证据。
        if receipt_path(source["commit"]).exists(): require_local(source, require_latest=False)
        else: atomic_json(receipt_path(source["commit"]), receipt)
    print("Check scope: " + summary["scope"] + "; system OCR: " + summary["ocr"]["status"], flush=True)


def receipt_path(commit):
    return ROOT / ".local/qualifications" / (CONFIG["version"] + "-" + commit + ".json")


def validate_public(summary, source, version, build_number):
    try:
        if (summary["scope"] != "native-system" or summary["source"] != source or source["dirty"] or
            summary["version"] != version or summary["buildNumber"] != build_number or
            summary["host"]["system"] != "Darwin" or summary["host"]["architecture"] != "arm64" or
            not all(summary["host"].get(key) for key in ("osVersion", "osBuild", "chip", "swift", "xcode", "sdkVersion", "sdkBuild"))):
            raise ValueError()
        tests, ocr = summary["tests"], summary["ocr"]
        if (tests["inventoryCount"] != tests["coreDeclared"] + tests["terminalDeclared"] + tests["ocrDeclared"] or
            min(tests["coreDeclared"], tests["terminalDeclared"]) < 1 or tests["ocrDeclared"] != 1 or
            tests["executedCount"] < tests["inventoryCount"] or min(tests["pipelineTestCount"],tests["localizedKeyCount"]) < 1 or not re.fullmatch(r"[0-9a-f]{64}", tests["inventorySHA256"]) or
            ocr["status"] != "PASS" or ocr["caseID"] != OCR_ID or ocr["configuration"] != OCR_CONFIG or
            len(ocr["rounds"]) != 2 or any(item != {"usedOCR": True, "hasKeyDock": True, "hasSynthetic": True} for item in ocr["rounds"]) or
            not re.fullmatch(r"[0-9a-f]{64}", ocr["fixtureSHA256"])):
            raise ValueError()
        if set(summary["sourceFiles"]) != set(SOURCE_FILES) or set(summary["evidence"]) != set(STAGES + (OCR_STAGE,)):
            raise ValueError()
        if not all(re.fullmatch(r"[0-9a-f]{64}", value) for value in summary["sourceFiles"].values()): raise ValueError()
        if not all(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) and item["bytes"] >= 0 for item in summary["evidence"].values()): raise ValueError()
        if any(item["bytes"] == 0 for name,item in summary["evidence"].items() if name != "lifecycle-helper"): raise ValueError()
        if datetime.fromisoformat(summary["createdAt"]).tzinfo is None: raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise PipelineError("Release requires a complete same-source native OCR qualification")


def require_local(source, current_host=False, require_latest=True):
    try:
        receipt = json.loads(receipt_path(source["commit"]).read_text())
        summary = receipt["summary"]
        validate_public(summary, source, CONFIG["version"], CONFIG["buildNumber"])
        if current_host and summary["host"] != host_facts():
            raise PipelineError("The qualified OS, Swift, Xcode or SDK differs from this build host; create a new version and qualify it")
        if require_latest:
            latest = json.loads(latest_path(source["commit"]).read_text())
            if latest.get("status") != "passed" or latest.get("source") != source: raise ValueError()
        logs = {}
        if set(receipt["logs"]) != set(STAGES + (OCR_STAGE,)): raise ValueError()
        for name, relative in receipt["logs"].items():
            path = ROOT / relative
            parts = Path(relative).parts
            if (len(parts) != 4 or parts[:2] != (".local","pipeline") or parts[3] != name + ".log" or
                not re.fullmatch(r"\d{8}T\d{12}Z",parts[2]) or path.is_symlink() or
                not path.resolve().is_relative_to((ROOT / ".local/pipeline").resolve())): raise ValueError()
            logs[name] = path.read_bytes().decode("utf-8")
        actual = assess(logs, source, CONFIG["version"], CONFIG["buildNumber"], summary["host"],
                        {path: sha256(ROOT / path) for path in SOURCE_FILES}, receipt["timingFilter"], summary["createdAt"])
        if digest(actual) != digest(summary): raise ValueError()
        return summary
    except (OSError, ValueError, KeyError, TypeError):
        raise PipelineError("Run the complete clean-source local check before building, packaging or publishing")


def core_ci(source, selected=None):
    repo = CONFIG["repository"]
    if selected:
        result = json.loads(run(["gh", "api", "repos/" + repo + "/actions/runs/" + str(selected)], capture=True))
    else:
        payload = json.loads(run(["gh", "api", "repos/" + repo + "/actions/runs?head_sha=" + source["commit"] + "&event=push&per_page=20"], capture=True))
        matches = [item for item in payload["workflow_runs"] if item.get("path") == ".github/workflows/ci.yml" and item.get("status") == "completed"]
        if not matches: raise PipelineError("Wait for a successful same-source core CI before packaging")
        result = max(matches, key=lambda item: item["id"])
    facts = {key: result.get(key) for key in ("id", "head_sha", "path", "event", "status", "conclusion", "html_url")}
    validate_ci(facts, source)
    return facts


def validate_ci(facts, source):
    if (type(facts.get("id")) is not int or facts["id"] <= 0 or facts.get("head_sha") != source["commit"] or
        facts.get("path") != ".github/workflows/ci.yml" or facts.get("event") != "push" or
        facts.get("status") != "completed" or facts.get("conclusion") != "success" or
        facts.get("html_url") != "https://github.com/" + CONFIG["repository"] + "/actions/runs/" + str(facts["id"])):
        raise PipelineError("The designated same-source core CI has not succeeded")


def latest_path(commit):
    return ROOT / ".local/qualifications" / (CONFIG["version"] + "-" + commit + ".latest-check.json")


def begin_check(directory, source, ci):
    if ci or source["dirty"]: return None
    attempt = {"source": source, "run": directory.name, "status": "running"}
    atomic_json(latest_path(source["commit"]), attempt)
    return attempt


def finish_check(attempt, succeeded):
    if attempt is None: return
    path = latest_path(attempt["source"]["commit"])
    latest = json.loads(path.read_text())
    if latest.get("run") != attempt["run"]: raise PipelineError("A different full-check attempt owns the qualification state")
    atomic_json(path, {**attempt, "status": "passed" if succeeded else "failed"})


def verify_source(summary):
    for path, expected in summary["sourceFiles"].items():
        result = subprocess.run(["git", "show", summary["source"]["commit"] + ":" + path], cwd=ROOT, capture_output=True, check=True)
        if hashlib.sha256(result.stdout).hexdigest() != expected: raise PipelineError("Qualification source digest differs from its Git commit")
