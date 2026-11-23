#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 兼容旧入口；开发构建统一使用独立、隔离的Preview身份。
if [[ -n "${1:-}" && "${1:-}" != --safe-smoke ]]; then
  printf '%s\n' 'Use make release for a signed distribution, or make debug for development.' >&2
  exit 1
fi
exec python3 scripts/keydock.py build --profile preview --allow-dirty
