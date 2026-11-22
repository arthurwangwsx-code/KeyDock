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
            keys.update(re.findall(r'\b(?:L|AppL)\("([^"\\]*(?:\\.[^"\\]*)*)"\)', text))
            keys.update(re.findall(r'String\(localized: "([^"\\]*(?:\\.[^"\\]*)*)"\)', text))
            keys.update(re.findall(r'(?:builtinKey|titleKey): "([^"\\]+)"', text))
    keys.discard('')
    total += len(keys)
    path = root / name
    catalog = json.loads(path.read_text())
    for key in keys:
        if args.check and key not in catalog['strings']:
            errors.append(f'{name}: missing source key: {key}')
        item = catalog['strings'].setdefault(key, {'localizations': {}})
        item['localizations'].setdefault('en', {'stringUnit': {'state': 'translated', 'value': key}})
        if not item['localizations'].get('zh-Hans', {}).get('stringUnit', {}).get('value'):
            errors.append(f'{name}: missing zh-Hans: {key}')
            missing.add(key)
    if not args.check:
        catalog['strings'] = {key: catalog['strings'][key] for key in sorted(keys)}
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    if not args.check:
        (root / '.local').mkdir(exist_ok=True)
        (root / '.local/missing-localizations.json').write_text(json.dumps(sorted(missing), ensure_ascii=False, indent=2) + '\n')
    sys.exit(1)
print(f'PASS: {total} UI keys covered in English and Simplified Chinese across {len(targets)} bundles')
