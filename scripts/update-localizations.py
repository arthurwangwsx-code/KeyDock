#!/usr/bin/env python3
"""按 Swift target 递归维护 String Catalog；不调用翻译服务。"""
from pathlib import Path
import argparse
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
targets = {
    'Packages/WorkbenchFeature/Sources/WorkbenchFeature/Resources/Localizable.xcstrings': ['Packages/WorkbenchFeature/Sources/WorkbenchFeature'],
    'Apps/KeyDock/Resources/Localizable.xcstrings': ['Apps/KeyDock/Sources'],
}
errors = []
missing = set()
total = 0
for name, folders in targets.items():
    keys = set()
    for folder in folders:
        for path in (root / folder).rglob('*.swift'):
            text = path.read_text()
            keys.update(re.findall(r'\b(?:L|AppL|noticeKey)\("([^"\\]*(?:\\.[^"\\]*)*)"', text))
            keys.update(re.findall(r'String\(localized: "([^"\\]*(?:\\.[^"\\]*)*)"\)', text))
            keys.update(re.findall(r'(?:builtinKey|titleKey): "([^"\\]+)"', text))
    if 'WorkbenchFeature/' in name:
        geometry = (root / 'Packages/CommandCore/Sources/CommandCore/WindowGeometry.swift').read_text()
        keys.update(re.findall(r'case \.[A-Za-z]+: "([^"\\]+)"', geometry))
        receipts = (root / 'Packages/WorkbenchFeature/Sources/WorkbenchFeature/AITaskReceipts.swift').read_text()
        keys.update(re.findall(r'case [A-Za-z]+ = "([^"\\]+)"', receipts))
    keys.discard('')
    total += len(keys)
    path = root / name
    catalog = json.loads(path.read_text())
    for key in keys:
        if args.check and key not in catalog['strings']:
            errors.append(f'{name}: missing source key: {key}')
        item = catalog['strings'].get(key, {'localizations': {}})
        if not args.check:
            catalog['strings'][key] = item
            item['localizations'].setdefault('en', {'stringUnit': {'state': 'translated', 'value': key}})
        for language in ('en', 'zh-Hans'):
            unit = item.get('localizations', {}).get(language, {}).get('stringUnit', {})
            if not unit.get('value') or unit.get('state') != 'translated':
                errors.append(f'{name}: missing translated {language}: {key}')
                missing.add(key)
    if not args.check:
        catalog['strings'] = {key: catalog['strings'][key] for key in sorted(keys)}
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
for language in ('en', 'zh-Hans'):
    path = root / 'Apps/KeyDock/Resources' / f'{language}.lproj/InfoPlist.strings'
    if not path.exists() or not re.search(r'"NSAppleEventsUsageDescription"\s*=\s*"[^"\n]+";', path.read_text()):
        errors.append(f'{path.relative_to(root)}: missing permission explanation')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    if not args.check:
        (root / '.local').mkdir(exist_ok=True)
        (root / '.local/missing-localizations.json').write_text(json.dumps(sorted(missing), ensure_ascii=False, indent=2) + '\n')
    sys.exit(1)
print(f'PASS: {total} UI keys covered in English and Simplified Chinese across {len(targets)} bundles')
