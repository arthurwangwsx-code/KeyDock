"""性能数据的纯校验和统计，不访问进程、文件、凭据或网络。"""
from __future__ import annotations
import math
import uuid


class MetricsError(ValueError):
    pass


def uint(value, maximum=2**64 - 1):
    if type(value) is not int or not 0 <= value <= maximum:
        raise MetricsError("invalid-integer")
    return value


def distribution(values):
    if not values or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in values):
        raise MetricsError("invalid-samples")
    ordered = sorted(values)
    return {"count": len(values), "minimum": ordered[0], "p50": ordered[math.ceil(len(values) * .5) - 1],
            "p95": ordered[math.ceil(len(values) * .95) - 1], "maximum": ordered[-1]}


SAMPLE_KEYS = {"schemaVersion", "kind", "identity", "executableUUID", "processStartAbsoluteTicks", "userTimeMachTicks",
               "systemTimeMachTicks", "residentBytes", "physicalFootprintBytes", "absoluteTimeTicks", "continuousTimeTicks",
               "timebaseNumerator", "timebaseDenominator", "lowPowerMode", "thermalState"}
IDENTITY_KEYS = {"pid", "uid", "realUID", "startUnixSeconds", "startUnixMicroseconds", "executablePath"}
THERMAL_STATES = {"nominal", "fair", "serious", "critical", "unknown"}
PHASES = {"declared-idle-hidden", "synthetic-interaction", "recovery-idle"}


def validate_sample(sample, expected=None, path=None, image_uuid=None, owner_uid=None):
    if type(sample) is not dict or set(sample) != SAMPLE_KEYS or sample.get("schemaVersion") != 1 or sample.get("kind") != "keydock-process-resources":
        raise MetricsError("invalid-probe-sample")
    identity = sample["identity"]
    if type(identity) is not dict or set(identity) != IDENTITY_KEYS:
        raise MetricsError("invalid-identity")
    for key in IDENTITY_KEYS - {"executablePath"}:
        uint(identity[key])
    if identity["pid"] <= 1 or identity["pid"] > 2**31 - 1 or identity["startUnixMicroseconds"] >= 1_000_000:
        raise MetricsError("invalid-identity")
    if type(identity["executablePath"]) is not str or not 0 < len(identity["executablePath"].encode()) <= 4096:
        raise MetricsError("invalid-executable-path")
    for key in SAMPLE_KEYS - {"schemaVersion", "kind", "identity", "executableUUID", "lowPowerMode", "thermalState"}:
        uint(sample[key])
    if not sample["processStartAbsoluteTicks"] or not sample["timebaseNumerator"] or not sample["timebaseDenominator"]:
        raise MetricsError("invalid-timebase")
    uint(sample["timebaseNumerator"], 2**32 - 1); uint(sample["timebaseDenominator"], 2**32 - 1)
    try:
        if str(uuid.UUID(sample["executableUUID"])).upper() != sample["executableUUID"] or uuid.UUID(sample["executableUUID"]).int == 0:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise MetricsError("invalid-image-uuid")
    if type(sample["lowPowerMode"]) is not bool or type(sample["thermalState"]) is not str or sample["thermalState"] not in THERMAL_STATES:
        raise MetricsError("invalid-host-state")
    if owner_uid is not None and (identity["uid"] != owner_uid or identity["realUID"] != owner_uid):
        raise MetricsError("wrong-owner")
    if path is not None and identity["executablePath"] != str(path):
        raise MetricsError("executable-changed")
    if image_uuid is not None and sample["executableUUID"] != image_uuid:
        raise MetricsError("running-image-mismatch")
    if expected is not None and any(sample[k] != expected[k] for k in ("identity", "executableUUID", "processStartAbsoluteTicks", "timebaseNumerator", "timebaseDenominator")):
        raise MetricsError("process-generation-changed")
    return sample


def resource_delta(before, after):
    validate_sample(before); validate_sample(after, expected=before)
    keys = ("userTimeMachTicks", "systemTimeMachTicks", "absoluteTimeTicks", "continuousTimeTicks")
    deltas = {key: after[key] - before[key] for key in keys}
    if any(value < 0 for value in deltas.values()) or not deltas["absoluteTimeTicks"] or not deltas["continuousTimeTicks"]:
        raise MetricsError("counter-regressed")
    scale = before["timebaseNumerator"] / before["timebaseDenominator"] / 1e9
    awake, wall = deltas["absoluteTimeTicks"] * scale, deltas["continuousTimeTicks"] * scale
    if wall + .01 < awake:
        raise MetricsError("clock-inconsistent")
    cpu_ticks = deltas["userTimeMachTicks"] + deltas["systemTimeMachTicks"]
    cpu_seconds = cpu_ticks * scale
    return {"cpuSeconds": cpu_seconds, "cpuPercentOneCore": 100 * cpu_ticks / deltas["continuousTimeTicks"],
            "elapsedSeconds": wall, "awakeSeconds": awake, "clockGapSeconds": max(0, wall - awake),
            "sleepOrClockGap": wall - awake > .5}


def validate_self_check(value):
    if type(value) is not dict or set(value) != {"kind", "before", "after", "posixCPUSeconds", "checksum"} or value["kind"] != "keydock-owned-cpu-self-check":
        raise MetricsError("invalid-self-check")
    measured = resource_delta(value["before"], value["after"])
    posix = value["posixCPUSeconds"]
    if type(posix) not in (int, float) or not math.isfinite(posix) or posix <= 0 or not .5 <= measured["cpuSeconds"] / posix <= 2:
        raise MetricsError("cpu-unit-cross-check-failed")
    uint(value["checksum"])
    return {"status": "PASS", "scope": "owned busy-loop CPU unit cross-check only", "machCPUSeconds": measured["cpuSeconds"],
            "posixCPUSeconds": posix, "ratio": measured["cpuSeconds"] / posix,
            "timebaseNumerator": value["before"]["timebaseNumerator"], "timebaseDenominator": value["before"]["timebaseDenominator"]}


def validate_query(report):
    expected = {"schemaVersion", "fixture", "itemCount", "warmups", "configuration", "ranking", "queryPipeline", "matchesExpectedResults", "system", "lowPowerMode", "thermalState", "panelFirstFrameQualification", "catalogPreparation"}
    if type(report) is not dict or set(report) != expected or report["schemaVersion"] != 3 or report["fixture"] != "keydock-synthetic-catalog-v1" or report["configuration"] != "Release":
        raise MetricsError("invalid-query-report")
    if type(report["itemCount"]) is not int or type(report["warmups"]) is not int or report["itemCount"] != 2000 or report["warmups"] != 10 or report["matchesExpectedResults"] is not True or report["panelFirstFrameQualification"] != "NOT_QUALIFIED":
        raise MetricsError("invalid-query-contract")
    if type(report["lowPowerMode"]) is not bool or type(report["system"]) is not str or len(report["system"]) > 512:
        raise MetricsError("invalid-query-environment")
    uint(report["thermalState"], 3)
    preparation = report["catalogPreparation"]
    if (type(preparation) is not dict or set(preparation) != {"scope", "milliseconds", "normalizedUTF8Bytes"} or
            preparation["scope"] != "synthetic fixture construction and Unicode search preparation; excludes indexing and UI"):
        raise MetricsError("invalid-catalog-preparation")
    distribution([preparation["milliseconds"]]); uint(preparation["normalizedUTF8Bytes"])
    summaries = {}
    for kind in ("ranking", "queryPipeline"):
        part = report[kind]
        if type(part) is not dict or set(part) != {"scope", "samples", "p50Milliseconds", "p95Milliseconds", "maxMilliseconds", "targetMilliseconds", "pass"} or type(part["samples"]) is not list or len(part["samples"]) != 100:
            raise MetricsError("invalid-query-samples")
        identities = set()
        for ordinal, sample in enumerate(part["samples"]):
            fields = {"ordinal", "variant", "milliseconds", "resultCount"} | ({"queryID", "generation"} if kind == "queryPipeline" else set())
            if type(sample) is not dict or set(sample) != fields or type(sample["ordinal"]) is not int or sample["ordinal"] != ordinal or sample["variant"] != ("application-prefix" if ordinal % 2 == 0 else "localized-keywords"):
                raise MetricsError("invalid-query-order")
            if uint(sample["resultCount"]) == 0:
                raise MetricsError("empty-query-results")
            if kind == "queryPipeline":
                try: identifier = uuid.UUID(sample["queryID"])
                except (ValueError, TypeError, AttributeError): raise MetricsError("invalid-query-identity")
                if identifier in identities or type(sample["generation"]) is not int or sample["generation"] != ordinal + 11:
                    raise MetricsError("stale-query-identity")
                identities.add(identifier)
                if sample["resultCount"] != report["ranking"]["samples"][ordinal]["resultCount"]:
                    raise MetricsError("query-results-differ")
        stats = distribution([sample["milliseconds"] for sample in part["samples"]])
        if any(type(part[key]) not in (int, float) or not math.isfinite(part[key]) or abs(part[key] - stats[value]) > 1e-9 for key, value in (("p50Milliseconds", "p50"), ("p95Milliseconds", "p95"), ("maxMilliseconds", "maximum"))):
            raise MetricsError("query-statistics-differ")
        passed = stats["p95"] <= 50
        if part["targetMilliseconds"] != 50 or part["pass"] is not passed:
            raise MetricsError("query-budget-mismatch")
        summaries[kind] = {**stats, "targetMilliseconds": 50, "pass": passed}
    return {"status": "PASS" if all(value["pass"] for value in summaries.values()) else "FAIL", "distributions": summaries, "catalogPreparation": preparation,
            "panelFirstFrameQualification": "NOT_QUALIFIED"}
