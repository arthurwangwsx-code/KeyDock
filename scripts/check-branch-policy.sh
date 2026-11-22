#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
branch=$(git branch --show-current)
if [[ "$branch" == master && "${1:-}" == --allow-master ]]; then
  printf '%s\n' 'PASS: master (read-only validation/integration)'
elif [[ "$branch" =~ ^(feature|fix|chore|spike|integration)/[a-z0-9][a-z0-9._/-]*$ ]]; then
  printf 'PASS: %s\n' "$branch"
else
  printf 'FAIL: use a named development branch from master; current=%s\n' "${branch:-detached}" >&2
  exit 1
fi
count=$(git worktree list --porcelain | awk '/^worktree / {n++} END {print n+0}')
if [[ "$count" != 1 ]]; then
  printf 'FAIL: expected one canonical checkout, found %s; inspect without removing anything.\n' "$count" >&2
  exit 1
fi
git rev-parse --verify master >/dev/null
git merge-base --is-ancestor master HEAD || {
  printf '%s\n' 'FAIL: current HEAD does not contain master; inspect history before integration.' >&2
  exit 1
}
