"""只用于离线门禁测试的合成日志；不代表任何真实机器的资格。"""
import json
import release_quality as quality
from keydock_common import CONFIG

TIMING = r"^WorkbenchFeatureTests\.TerminalLifecycleTests/"
SOURCE = {"commit": "a" * 40, "dirty": False}
HOST = {"system": "Darwin", "architecture": "arm64", "osVersion": "27.2", "osBuild": "synthetic", "chip": "Synthetic CPU", "swift": "Synthetic Swift", "xcode": "Synthetic Xcode", "sdkVersion": "27.2", "sdkBuild": "synthetic"}


def fixture_logs():
    observation = {"configuration": quality.OCR_CONFIG.copy(), "rounds": [{"usedOCR": True, "hasKeyDock": True, "hasSynthetic": True} for _ in range(2)], "fixtureSHA256": "b" * 64}
    logs = {name: "PASS synthetic stage\n" for name in quality.STAGES}
    logs["lifecycle-helper"] = ""
    logs["pipeline-tests"] = "Ran 3 tests in 0.1s\nOK\n"
    logs["localizations"] = "PASS: 5 UI keys covered in English and Simplified Chinese\n"
    logs["swift-tests"] = "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n"
    logs["swift-terminal-lifecycle"] = logs["swift-tests"]
    logs[quality.OCR_STAGE] = quality.OCR_MARKER + json.dumps(observation) + "\n" + logs["swift-tests"]
    logs["swift-inventory"] = "\n".join(("CommandCoreTests.Synthetic/a()", "WorkbenchFeatureTests.TerminalLifecycleTests/b()", quality.OCR_ID))
    return logs


def fixture_summary(logs=None, source_hashes=None):
    return quality.assess(logs or fixture_logs(), SOURCE.copy(), CONFIG["version"], CONFIG["buildNumber"], HOST.copy(),
                          source_hashes or {path: "c" * 64 for path in quality.SOURCE_FILES}, TIMING, "2026-11-24T00:00:00+00:00")


def fixture_ci():
    return {"id": 1, "head_sha": SOURCE["commit"], "path": ".github/workflows/ci.yml", "event": "push", "status": "completed", "conclusion": "success", "html_url": "https://github.com/" + CONFIG["repository"] + "/actions/runs/1"}
