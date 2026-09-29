#!/usr/bin/env bash
# Enumerate EVERY deployable Grid item tracked in the repo (the full f/**
# inventory), classified into `wmill <type> push` records in dependency
# order (folder first; then runnables/data; then schedule/trigger), with
# bun scripts pushed after the local files they import.
#
# Usage:
#   scripts/list-grid-items.sh
#
# This is the deploy set: deploy-grid-items.sh pipes it into
# push-grid-items.sh on every master deploy. We push the full inventory
# (not a commit-range diff) and let `wmill <type> push` no-op the unchanged
# items via its content-hash check — see claude/rules/deploy-full-inventory.md.
#
# Why git ls-files (not find): we want exactly the tracked f/** set.
# Untracked scratch files and ignored build output never deploy, so they
# must never show up in the inventory.
#
# Output: see scripts/classify-grid-paths.sh — one TAB-separated record
# per line, deduped, in `wmill push` dependency order — then
# scripts/order-by-imports.sh moves each `.ts` script after the local files
# it imports (and re-emits the members of an import cycle once more; see
# that script). Empty (exit 0) when the repo has no f/** content.

set -euo pipefail

# Resolve script dir so we can invoke the shared classifier regardless of cwd.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run from the repo root so the f/** pathspec and the emitted paths are
# repo-relative (matching what `wmill <type> push` expects relative to
# wmill.yaml, which lives at the repo root).
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# `git ls-files -- 'f/**'` lists tracked files under the Grid namespace.
# Pipe into the shared classifier (dependency order + dedup), then order the
# bun scripts by their local imports. order-by-imports.sh opens the script
# files relative to the cwd, which is the repo root (cd above).
git ls-files -- 'f/**' \
  | bash "$here/classify-grid-paths.sh" \
  | bash "$here/order-by-imports.sh"
