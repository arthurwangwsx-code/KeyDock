#!/usr/bin/env python3
"""校验可公开的规划文档、相对链接、参考登记和 iSpec 场景。"""
from pathlib import Path
from urllib.parse import unquote, urlparse
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []
paths = list(ROOT.glob("*.md"))
for folder in ("docs", "references", "ispec/changes"):
    paths.extend((ROOT / folder).rglob("*.md"))

for path in paths:
    content = path.read_text(encoding="utf-8")
    for target in re.findall(r"!?\[[^\]]*\]\(([^)\s]+)\)", content):
        if urlparse(target).scheme or target.startswith("#"):
            continue
        local = unquote(target.split("#", 1)[0])
        destination = (path.parent / local).resolve()
        if not destination.is_relative_to(ROOT) or not destination.exists():
            errors.append(f"{path.relative_to(ROOT)}: missing/outside link {target}")

catalog = json.loads((ROOT / "references/catalog.json").read_text())
seen = set()
for project in catalog["projects"]:
    repo = project["repo"]
    if repo in seen:
        errors.append(f"duplicate reference {repo}")
    seen.add(repo)
    sha = project["revision"]["sha"]
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        errors.append(f"{repo}: invalid SHA")
    if f"/blob/{sha}/" not in project["licenseEvidence"]:
        errors.append(f"{repo}: license evidence is not pinned to an actual file")
    for field in ("checkedAt", "licenseSummary", "researchScope", "intendedUse", "securityReview"):
        if not project.get(field):
            errors.append(f"{repo}: missing {field}")
    if project["dependencyStatus"] == "reference-only" and project["copiedFiles"]:
        errors.append(f"{repo}: copied files conflict with reference-only")

change = ROOT / "ispec/changes/keydock-foundation"
proposal = (change / "10-proposal.md").read_text()
capabilities = set(re.findall(r"^- `([a-z0-9-]+)`:", proposal, re.M))
specs = {p.parent.name: p for p in (change / "specs").glob("*/spec.md")}
if not capabilities or not specs:
    errors.append("proposal/specification capability set is empty")
if capabilities != set(specs):
    errors.append("proposal capabilities do not match specification directories")
scenarios = 0
requirements = 0
for name, path in specs.items():
    content = path.read_text()
    blocks = re.split(r"^### Requirement:", content, flags=re.M)[1:]
    if not blocks:
        errors.append(f"{name}: specification has no requirements")
    for block in blocks:
        requirements += 1
        cases = re.split(r"^#### Scenario:", block, flags=re.M)[1:]
        statement = re.split(r"^#### Scenario:", block, maxsplit=1, flags=re.M)[0]
        if not cases or not re.search(r"\b(MUST|SHALL)\b", statement):
            errors.append(f"{name}: missing normative requirement/scenario")
        for case in cases:
            scenarios += 1
            if "**WHEN**" not in case or "**THEN**" not in case:
                errors.append(f"{name}: incomplete WHEN/THEN scenario")
tasks = (change / "30-tasks.md").read_text()
task_ids = re.findall(r"^- \[[ x]\] (\d+\.\d+) ", tasks, re.M)
if not task_ids or len(task_ids) != len(set(task_ids)):
    errors.append("missing or duplicate implementation task IDs")
for name in ("README.md", "SECURITY.md", "AGENTS.md"):
    if "arthur.wang.wsx@gmail.com" not in (ROOT / name).read_text():
        errors.append(f"{name}: missing agreed support contact")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(paths)} Markdown documents, {len(seen)} pinned references, "
      f"{requirements} requirements, {scenarios} scenarios, {len(task_ids)} tasks")
