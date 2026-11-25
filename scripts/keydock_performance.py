#!/usr/bin/env python3
"""只读性能采样；查询使用合成数据，驻留只附着明确的KeyDock进程。"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

from keydock_common import ROOT, CONFIG, PipelineError, atomic_json, inspect_app, sha256, source_identity
from performance_metrics import MetricsError, PHASES, distribution, resource_delta, validate_query, validate_sample, validate_self_check
import release_quality

MAX_RAW_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 16_384


def utc():
    return datetime.now(timezone.utc).isoformat()


def run_json(command):
    result = subprocess.run([str(value) for value in command], capture_output=True, timeout=15)
    if len(result.stdout) > 1_048_576:
        raise MetricsError("native-probe-failed")
    try: value = json.loads(result.stdout)
    except (ValueError, UnicodeError): raise MetricsError("invalid-native-json")
    if result.returncode:
        reasons = {"invalidArguments", "unavailable", "wrongOwner", "wrongExecutable", "notRunning", "identityChanged", "clockUnavailable"}
        reason = value.get("reason") if type(value) is dict else None
        raise MetricsError("native-" + reason if type(reason) is str and reason in reasons else "native-probe-failed")
    return value


def file_identity(path):
    info = Path(path).stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def image_uuid(executable):
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(executable)], capture_output=True, text=True, timeout=15)
    matches = re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) \(arm64\) ", result.stdout, re.M)
    if result.returncode or len(matches) != 1:
        raise MetricsError("disk-image-uuid-unavailable")
    return matches[0].upper()


def observer_identity(probe):
    files = [ROOT / "scripts" / name for name in ("keydock.py", "keydock_performance.py", "performance_metrics.py", "keydock_common.py", "release_quality.py")]
    return {"source": source_identity(False), "probeSHA256": sha256(probe),
            "scripts": {str(path.relative_to(ROOT)): sha256(path) for path in files},
            "python": sys.version.split()[0], "host": release_quality.host_facts(), "hostLoadAverage": list(os.getloadavg())}


def observer_unchanged(before, probe):
    return (source_identity(False) == before["source"] and sha256(probe) == before["probeSHA256"] and
            all(sha256(ROOT / name) == digest for name, digest in before["scripts"].items()))


def allowed_app(app):
    app = Path(app).expanduser().absolute()
    allowed = {Path("/Applications/KeyDock.app"), Path.home() / "Applications/KeyDock Preview.app"}
    if app not in allowed or any(path.is_symlink() for path in (app, *app.parents)):
        raise MetricsError("app-is-not-canonical")
    return app


def app_facts(app):
    facts = inspect_app(app)
    signature = facts["code_signature"]
    if facts["profile"] == "release":
        if signature["kind"] != "developer-id" or signature["team_id"] != CONFIG["teamID"] or not signature["hardened_runtime"]:
            raise MetricsError("app-signature-not-trusted")
    elif not facts["safe_smoke"] or signature["kind"] not in {"adhoc", "developer-id"}:
        raise MetricsError("preview-profile-invalid")
    metadata = json.loads((app / "Contents/Resources/BuildInfo.json").read_text())
    configuration = metadata.get("configuration", "not-retained")
    if configuration not in {"not-retained", "Release", "Debug", "ReleasePreview", "DebugPreview"}:
        raise MetricsError("unknown-app-configuration")
    return {**facts, "configuration": configuration}


class Target:
    def __init__(self, app, pid, probe):
        self.app = allowed_app(app)
        self.pid = pid
        self.probe = Path(probe)
        self.facts = app_facts(self.app)
        self.executable = Path(self.facts["executable"])
        self.disk_identity = file_identity(self.executable)
        self.image_uuid = image_uuid(self.executable)
        self.anchor = None
        self.previous = None
        self.initial = self.poll()

    def poll(self):
        if file_identity(self.executable) != self.disk_identity:
            raise MetricsError("app-executable-changed")
        value = run_json([self.probe, "--pid", self.pid, "--executable", self.executable])
        validate_sample(value, expected=self.anchor, path=self.executable, image_uuid=self.image_uuid, owner_uid=os.getuid())
        if value["identity"]["pid"] != self.pid:
            raise MetricsError("pid-changed")
        if self.anchor is None: self.anchor = value
        if self.previous is not None: resource_delta(self.previous, value)
        self.previous = value
        return value

    def finish(self):
        self.poll()
        current = app_facts(self.app)
        if current != self.facts:
            raise MetricsError("app-integrity-changed")
        return current


def write_record(stream, record):
    line = (json.dumps(record, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if len(line) > MAX_LINE_BYTES or stream.tell() + len(line) > MAX_RAW_BYTES:
        raise MetricsError("record-budget-exceeded")
    stream.write(line); stream.flush(); os.fsync(stream.fileno())


def verify_log(path, expected_digest):
    path = Path(path)
    if path.stat().st_size > MAX_RAW_BYTES or sha256(path) != expected_digest:
        raise MetricsError("raw-file-changed")
    records = []
    with path.open("rb") as stream:
        while True:
            line = stream.readline(MAX_LINE_BYTES + 1)
            if not line: break
            if len(line) > MAX_LINE_BYTES or not line.endswith(b"\n"):
                raise MetricsError("incomplete-raw-line")
            try: record = json.loads(line)
            except ValueError: raise MetricsError("invalid-raw-json")
            if type(record) is not dict: raise MetricsError("invalid-raw-record")
            records.append(record)
    if len(records) < 3 or records[0].get("event") != "header" or records[-1].get("event") != "terminal":
        raise MetricsError("incomplete-resource-log")
    samples, intervals, last = [], [], None
    phase = records[0].get("phase")
    if type(phase) is not str or phase not in PHASES: raise MetricsError("invalid-phase")
    phases = {phase}; epoch = 0; last_epoch = 0
    for record in records[1:-1]:
        if record.get("event") == "phase":
            selected = record.get("phase")
            if type(selected) is not str or selected not in PHASES or set(record) - {"event", "phase", "observedAt"}:
                raise MetricsError("invalid-phase")
            if selected != phase: epoch += 1
            phase = selected; phases.add(phase)
            continue
        if (record.get("event") != "sample" or type(record.get("ordinal")) is not int or record.get("ordinal") != len(samples) or
                record.get("phase") != phase or set(record) - {"event", "ordinal", "phase", "observedAt", "resources", "hostLoadAverage"}):
            raise MetricsError("invalid-sample-order")
        sample = record.get("resources")
        validate_sample(sample, expected=samples[0]["resources"] if samples else None)
        if last:
            delta = resource_delta(last["resources"], sample)
            intervals.append({**delta, "phase": phase, "phaseTransition": last_epoch != epoch})
        samples.append(record); last = record; last_epoch = epoch
    if (not samples or type(records[-1].get("sampleCount")) is not int or records[-1].get("sampleCount") != len(samples) or
            records[-1].get("status") not in {"completed", "failed", "interrupted"}):
        raise MetricsError("sample-count-differs")
    return samples, intervals, {**records[-1], "observedPhases": sorted(phases)}


class PhaseInput:
    def __init__(self):
        self.selector = selectors.DefaultSelector(); self.buffer = b""; self.enabled = False
        try:
            self.selector.register(sys.stdin.fileno(), selectors.EVENT_READ); self.enabled = True
        except (OSError, ValueError): pass

    def wait(self, timeout):
        if not self.enabled:
            time.sleep(timeout); return []
        ready = self.selector.select(timeout)
        if not ready: return []
        chunk = os.read(sys.stdin.fileno(), 257)
        if not chunk:
            self.selector.close(); self.enabled = False; return []
        self.buffer += chunk
        if len(self.buffer) > 256: raise MetricsError("phase-control-too-long")
        result = []
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            try: value = json.loads(line)
            except ValueError: raise MetricsError("invalid-phase-control")
            if type(value) is not dict or set(value) != {"phase"} or type(value["phase"]) is not str or value["phase"] not in PHASES:
                raise MetricsError("invalid-phase-control")
            result.append(value["phase"])
        return result

    def close(self):
        self.selector.close()


def query(probe, output):
    observer = observer_identity(probe)
    started = utc()
    timed_out = interrupted = False
    # 直接落盘，取消／超时仍保留探针已经产生的准确字节。
    with (output / "query.stdout").open("xb") as stdout_file, (output / "query.stderr").open("xb") as stderr_file:
        process = subprocess.Popen([str(probe)], stdout=stdout_file, stderr=stderr_file)
        try: exit_code = process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            stop_owned_child(process); exit_code = 124; timed_out = True
        except KeyboardInterrupt:
            stop_owned_child(process); exit_code = 130; interrupted = True
    stdout = (output / "query.stdout").read_bytes()
    summary = {"schemaVersion": 1, "kind": "keydock-query-performance", "observer": observer,
               "startedAt": started, "scope": "synthetic cached query only", "status": "FAIL"}
    try:
        if interrupted: raise MetricsError("operator-interrupted")
        if timed_out: raise MetricsError("query-tool-timeout")
        if len(stdout) > 1_048_576: raise MetricsError("query-output-too-large")
        report = json.loads(stdout)
        atomic_json(output / "query.json", report)
        summary.update(validate_query(report))
        if not observer_unchanged(observer, probe):
            summary["status"] = "FAIL"; summary["reason"] = "observer-changed"
        elif summary["status"] == "FAIL": summary["reason"] = "query-budget-exceeded"
        elif exit_code: summary["status"] = "FAIL"; summary["reason"] = "query-tool-exit"
    except MetricsError as error:
        summary["reason"] = str(error)
        if interrupted: summary.update(status="interrupted", qualification="NOT_QUALIFIED")
    except ValueError: summary["reason"] = "invalid-query-evidence"
    summary.update(finishedAt=utc(), stdoutSHA256=sha256(output / "query.stdout"), stderrSHA256=sha256(output / "query.stderr"),
                   exitCode=exit_code, timedOut=timed_out, interrupted=interrupted, hostLoadAverageAfter=list(os.getloadavg()))
    atomic_json(output / "summary.json", summary)
    print(json.dumps(summary, sort_keys=True), flush=True)
    return 0 if summary["status"] == "PASS" else 1


def stop_owned_child(process):
    # 仅回收本函数刚创建的探针；从不对采样目标或其他进程发送信号。
    if process.poll() is None:
        process.terminate()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(timeout=5)


def probe_check(probe, output):
    observer = observer_identity(probe)
    cpu = run_json([probe, "--self-check"])
    atomic_json(output / "cpu-self-check.json", cpu)
    cpu_summary = validate_self_check(cpu)
    process = subprocess.Popen([str(probe), "--self-hold"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        ready = b""; deadline = time.monotonic() + 5
        while b"\n" not in ready:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining): raise MetricsError("owned-probe-not-ready")
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk or len(ready) + len(chunk) > MAX_LINE_BYTES: raise MetricsError("owned-probe-not-ready")
            ready += chunk
        anchor = json.loads(ready)
        validate_sample(anchor, path=Path(probe).resolve(), owner_uid=os.getuid())
        if anchor["identity"]["pid"] != process.pid: raise MetricsError("owned-probe-pid-differs")
        live = run_json([probe, "--pid", process.pid, "--executable", Path(probe).resolve()])
        validate_sample(live, expected=anchor)
        outcomes = {}
        for label, expected_path in [("wrongPath", str(Path(probe).resolve()) + ".keydock-mismatch"), ("afterExit", str(Path(probe).resolve()))]:
            if label == "afterExit":
                process.stdin.close()
                if process.wait(timeout=5) != 0: raise MetricsError("owned-probe-exit-failed")
            result = subprocess.run([str(probe), "--pid", str(process.pid), "--executable", expected_path], capture_output=True, timeout=5)
            value = json.loads(result.stdout)
            reasons = {"wrongExecutable"} if label == "wrongPath" else {"unavailable", "notRunning"}
            if (result.returncode != 1 or type(value) is not dict or set(value) != {"schemaVersion", "kind", "state", "reason"} or
                    value["schemaVersion"] != 1 or value["kind"] != "keydock-process-resources" or value["state"] != "unavailable" or value["reason"] not in reasons):
                raise MetricsError("owned-probe-negative-check-failed")
            outcomes[label] = value
        if not observer_unchanged(observer, probe): raise MetricsError("observer-changed")
        summary = {"schemaVersion": 1, "kind": "keydock-owned-probe-check", "status": "PASS", "observer": observer,
                   "cpuUnitCrossCheck": cpu_summary, "ownedAnchor": anchor, "ownedLive": live, "outcomes": outcomes,
                   "finishedAt": utc(), "qualification": "owned-probe-contracts-only"}
        atomic_json(output / "summary.json", summary)
        print(json.dumps(summary, sort_keys=True), flush=True)
        return 0
    finally:
        selector.close()
        stop_owned_child(process)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream and not stream.closed: stream.close()


def resident(app, pid, probe, output, duration, interval, phase):
    if type(pid) is not int or pid <= 1 or not math.isfinite(duration) or not math.isfinite(interval) or not 1 <= duration <= 28_800 or not 1 <= interval <= 60 or phase not in PHASES:
        raise MetricsError("invalid-sampling-parameters")
    observer = observer_identity(probe)
    check = run_json([probe, "--self-check"])
    atomic_json(output / "cpu-self-check.json", check)
    cross_check = validate_self_check(check)
    target = Target(app, pid, probe)
    control = PhaseInput()
    path = output / "resident.ndjson"
    summary = {"schemaVersion": 1, "kind": "keydock-resident-performance", "observer": observer, "application": target.facts,
               "cpuUnitCrossCheck": cross_check, "startedAt": utc(), "requestedDurationSeconds": duration,
               "intervalSeconds": interval, "conditions": "operator-declared; UI and collection flags not verified by sampler",
               "status": "incomplete", "qualification": "engineering-data-only", "panelFirstFrameQualification": "NOT_QUALIFIED"}
    start = time.monotonic(); next_due = start + interval; deadline = start + duration
    count = 0; state = "failed"; reason = None
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        write_record(stream, {"event": "header", "schemaVersion": 1, "phase": phase, "observer": observer, "application": target.facts,
                              "durationSeconds": duration, "intervalSeconds": interval, "phaseControlAvailable": control.enabled})
        try:
            value = target.initial
            while True:
                write_record(stream, {"event": "sample", "ordinal": count, "phase": phase, "observedAt": utc(),
                                      "resources": value, "hostLoadAverage": list(os.getloadavg())})
                count += 1
                print(json.dumps({"event": "sample", "count": count, "phase": phase}), flush=True)
                if time.monotonic() >= deadline: break
                while True:
                    due = min(next_due, deadline)
                    for selected in control.wait(max(0, min(1, due - time.monotonic()))):
                        phase = selected
                        write_record(stream, {"event": "phase", "phase": phase, "observedAt": utc()})
                        print(json.dumps({"event": "phase", "phase": phase, "sampleCount": count}), flush=True)
                    if time.monotonic() >= due: break
                value = target.poll()
                while next_due <= time.monotonic(): next_due += interval
            target.finish()
            if not observer_unchanged(observer, probe): raise MetricsError("observer-changed")
            state = "completed"
        except KeyboardInterrupt: state = "interrupted"; reason = "operator-interrupted"
        except (MetricsError, PipelineError, OSError, subprocess.SubprocessError) as error:
            reason = str(error) if isinstance(error, MetricsError) else "resource-read-or-integrity-failed"
        finally:
            control.close()
            write_record(stream, {"event": "terminal", "status": state, "reason": reason, "sampleCount": count, "finishedAt": utc()})
    digest = sha256(path)
    samples, intervals, terminal = verify_log(path, digest)
    ordinary = [entry["cpuPercentOneCore"] for entry in intervals if not entry["sleepOrClockGap"] and not entry["phaseTransition"]]
    elapsed = resource_delta(samples[0]["resources"], samples[-1]["resources"])["elapsedSeconds"] if len(samples) > 1 else 0
    summary.update(status=state, reason=reason, finishedAt=utc(), rawSHA256=digest, sampleCount=count, elapsedWallSeconds=elapsed,
                   shortBaselineDurationMet=elapsed >= 1800, phases=terminal["observedPhases"],
                   phaseSampleCounts={phase: sum(entry["phase"] == phase for entry in samples) for phase in terminal["observedPhases"]},
                   sleepOrClockGapIntervals=sum(entry["sleepOrClockGap"] for entry in intervals),
                   cpuPercentOneCore=distribution(ordinary) if ordinary else None,
                   residentBytes=distribution([entry["resources"]["residentBytes"] for entry in samples]),
                   physicalFootprintBytes=distribution([entry["resources"]["physicalFootprintBytes"] for entry in samples]))
    summary["byPhase"] = {}
    for selected in terminal["observedPhases"]:
        points = [entry["resources"] for entry in samples if entry["phase"] == selected]
        cpu = [entry["cpuPercentOneCore"] for entry in intervals if entry["phase"] == selected and not entry["sleepOrClockGap"] and not entry["phaseTransition"]]
        summary["byPhase"][selected] = {"sampleCount": len(points), "cpuPercentOneCore": distribution(cpu) if cpu else None,
            "residentBytes": distribution([entry["residentBytes"] for entry in points]) if points else None,
            "physicalFootprintBytes": distribution([entry["physicalFootprintBytes"] for entry in points]) if points else None}
    atomic_json(output / "summary.json", summary)
    print(json.dumps(summary, sort_keys=True), flush=True)
    return 0 if state == "completed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=["query", "resident", "probe-check"])
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--duration-seconds", type=float, default=1800)
    parser.add_argument("--interval-seconds", type=float, default=5)
    parser.add_argument("--condition", choices=sorted(PHASES), default="declared-idle-hidden")
    args = parser.parse_args()
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    try:
        if args.mode == "query": return query(args.probe, args.output)
        if args.mode == "probe-check": return probe_check(args.probe, args.output)
        if args.app is None: raise MetricsError("app-required")
        return resident(args.app, args.pid, args.probe, args.output, args.duration_seconds, args.interval_seconds, args.condition)
    except KeyboardInterrupt:
        atomic_json(args.output / "summary.json", {"status": "interrupted", "reason": "operator-interrupted", "finishedAt": utc(),
                                                 "qualification": "NOT_QUALIFIED"})
        return 130
    except (ValueError, MetricsError, PipelineError, OSError, subprocess.SubprocessError):
        if not (args.output / "summary.json").exists():
            atomic_json(args.output / "summary.json", {"status": "FAIL", "reason": "performance-sampling-failed", "finishedAt": utc(),
                                                     "qualification": "NOT_QUALIFIED"})
        print("FAIL: performance-sampling-failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
