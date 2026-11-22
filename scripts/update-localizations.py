#!/usr/bin/env python3
"""维护两个原生 bundle 的 String Catalog；不调用翻译服务。"""
from pathlib import Path
import argparse
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
paths = list((root / 'Packages/WorkbenchFeature/Sources/WorkbenchFeature').glob('*.swift')) + list((root / 'Apps/KeyDock/Sources').glob('*.swift'))
keys = set()
for path in paths:
    text = path.read_text()
    keys.update(re.findall(r'L\("([^"\\]*(?:\\.[^"\\]*)*)"\)', text))
    keys.update(re.findall(r'String\(localized: "([^"\\]*(?:\\.[^"\\]*)*)"\)', text))
keys.discard('')
errors = []
for name in ['Packages/WorkbenchFeature/Sources/WorkbenchFeature/Resources/Localizable.xcstrings', 'Apps/KeyDock/Resources/Localizable.xcstrings']:
    path = root / name
    catalog = json.loads(path.read_text())
    for key in keys:
        if args.check and key not in catalog['strings']:
            errors.append(f'{name}: missing source key: {key}')
        item = catalog['strings'].setdefault(key, {'localizations': {}})
        item['localizations'].setdefault('en', {'stringUnit': {'state': 'translated', 'value': key}})
        if not item['localizations'].get('zh-Hans', {}).get('stringUnit', {}).get('value'):
            errors.append(f'{name}: missing zh-Hans: {key}')
    if not args.check:
        catalog['strings'] = dict(sorted(catalog['strings'].items()))
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'PASS: {len(keys)} UI keys covered in English and Simplified Chinese')
