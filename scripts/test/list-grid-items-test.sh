#!/usr/bin/env bash
# Test scripts/list-grid-items.sh — the full f/** inventory enumerator the
# deploy pushes every master deploy.
#
# Asserts:
#   - it enumerates one record for every deployable item TRACKED in the
#     repo (the whole point of full-inventory deploy: an item that missed an
#     earlier deploy window must still show up and get pushed);
#   - records come out in `wmill push` dependency order (folder first,
#     runnables before schedule/trigger, a bun script after the local file
#     it imports — see order-by-imports-test.sh for the import cases);
#   - untracked / ignored files are NOT enumerated (they never deploy, so
#     the deploy must not try to push them).
#
# Runs offline: builds a throwaway git repo, never touches a workspace.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../list-grid-items.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find list-grid-items.sh at $script" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q
git config user.email test@example.com
git config user.name test

mkdir -p f/eng/widget.raw_app f/eng/pipeline.flow
cat >f/eng/folder.meta.yaml <<'YAML'
summary: eng folder
YAML
echo 'export function main() {}' >f/eng/summary_email.ts
echo 'export function main() {}' >f/eng/summary_email_test.ts
# Sorts BEFORE the script it imports; the inventory must still push the
# imported file first (its lock build needs the import to exist).
printf 'import { main as send } from "./summary_email.ts";\nexport function main() { return send() }\n' >f/eng/aaa_report.ts
echo '{}' >f/eng/widget.raw_app/app.yaml
echo 'summary: a flow' >f/eng/pipeline.flow/flow.yaml
cat >f/eng/conn.resource.yaml <<'YAML'
value:
  host: example.invalid
YAML
cat >f/eng/token.variable.yaml <<'YAML'
value: placeholder
YAML
cat >f/eng/summary_email_daily.schedule.yaml <<'YAML'
script_path: f/eng/summary_email
schedule: "0 0 * * *"
YAML
cat >f/eng/on_event.trigger.yaml <<'YAML'
script_path: f/eng/summary_email
YAML
git add -A
git commit -q -m "seed full inventory"

# An UNTRACKED item — present on disk but never committed. The deploy
# inventory must ignore it (untracked files never deploy).
echo 'export function main() {}' >f/eng/scratch_untracked.ts

# A file OUTSIDE f/** — must be ignored.
mkdir -p other
echo 'export function main() {}' >other/thing.ts

out="$(bash "$script")"

echo "--- list-grid-items.sh output ---"
printf '%s\n' "$out"
echo "---------------------------------"

fail=0
check() { # check <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc" >&2
    fail=1
  fi
}

# Helper: does the output contain an exact record line?
has_record() { grep -qxF "$1" <<<"$out"; }
# Helper: 1-based line number of first record whose type field matches.
type_pos() {
  local want="$1" n=0
  while IFS=$'\t' read -r type _; do
    n=$((n + 1))
    [ "$type" = "$want" ] && { printf '%s\n' "$n"; return 0; }
  done <<<"$out"
  printf '%s\n' "-1"
}

# Every tracked deployable item is enumerated (tab-separated literals).
check "enumerates the folder"   has_record "$(printf 'folder\teng')"
check "enumerates the app"      has_record "$(printf 'app\tf/eng/widget.raw_app')"
check "enumerates the flow"     has_record "$(printf 'flow\tf/eng/pipeline.flow\tf/eng/pipeline')"
check "enumerates the script"   has_record "$(printf 'script\tf/eng/summary_email.ts')"
check "enumerates the test"     has_record "$(printf 'script\tf/eng/summary_email_test.ts')"
check "enumerates the importer" has_record "$(printf 'script\tf/eng/aaa_report.ts')"
check "enumerates the resource" has_record "$(printf 'resource\tf/eng/conn.resource.yaml\tf/eng/conn')"
check "enumerates the variable" has_record "$(printf 'variable\tf/eng/token.variable.yaml\tf/eng/token')"
check "enumerates the schedule" has_record "$(printf 'schedule\tf/eng/summary_email_daily.schedule.yaml\tf/eng/summary_email_daily')"
check "enumerates the trigger"  has_record "$(printf 'trigger\tf/eng/on_event.trigger.yaml\tf/eng/on_event')"

# Untracked / out-of-namespace files are NOT enumerated.
check "ignores the untracked script" bash -c '! grep -qF "scratch_untracked" <<<"'"$out"'"'
check "ignores files outside f/**"   bash -c '! grep -qF "other/thing" <<<"'"$out"'"'

# Dependency order: folder first, every tier-1 runnable/data item before
# every tier-2 reference-holder (schedule/trigger). Covering every tier-1
# type means a typo in classify-grid-paths.sh's rank table (e.g. bumping
# `resource` out of the middle tier) is caught here, not in a live deploy.
folder_pos="$(type_pos folder)"
app_pos="$(type_pos app)"
schedule_pos="$(type_pos schedule)"
trigger_pos="$(type_pos trigger)"
check "folder is first"               test "$folder_pos" -eq 1
check "folder before the app inside it" test "$folder_pos" -lt "$app_pos"
for runnable in script app flow resource variable; do
  rp="$(type_pos "$runnable")"
  check "$runnable before schedule"   test "$rp" -lt "$schedule_pos"
  check "$runnable before trigger"    test "$rp" -lt "$trigger_pos"
done

# Import order: the imported script is pushed before its importer, even
# though the importer sorts first.
record_pos() { grep -nxF -m1 -- "$1" <<<"$out" | cut -d: -f1; }
imported_pos="$(record_pos "$(printf 'script\tf/eng/summary_email.ts')")"
importer_pos="$(record_pos "$(printf 'script\tf/eng/aaa_report.ts')")"
check "imported script before its importer" test "$imported_pos" -lt "$importer_pos"

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "list-grid-items test FAILED" >&2
  exit 1
fi

echo
echo "all list-grid-items assertions passed"
