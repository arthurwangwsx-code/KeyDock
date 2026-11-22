#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
branch_name=${1:-}
if [[ ! "$branch_name" =~ ^(feature|fix|chore|spike|integration)/[a-z0-9][a-z0-9._/-]*$ ]]; then
  printf '%s\n' 'Usage: scripts/new-feature-branch.sh feature/name [--dry-run]' >&2
  exit 1
fi
git check-ref-format --branch "$branch_name" >/dev/null
if [[ "$(git branch --show-current)" != master ]]; then
  printf '%s\n' 'FAIL: start from master; no automatic switch or stash.' >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  printf '%s\n' 'FAIL: preserve outstanding changes before creating a branch.' >&2
  exit 1
fi
./scripts/check-branch-policy.sh --allow-master
if git show-ref --verify --quiet "refs/heads/$branch_name"; then
  printf '%s\n' 'FAIL: target branch already exists; inspect it explicitly.' >&2
  exit 1
fi
if [[ "${2:-}" == --dry-run ]]; then
  printf 'Would create %s from master at %s\n' "$branch_name" "$(git rev-parse --short master)"
else
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' 'FAIL: unknown option.' >&2
    exit 1
  fi
  git switch -c "$branch_name" master
fi
