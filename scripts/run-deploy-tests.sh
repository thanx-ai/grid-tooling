#!/usr/bin/env bash
# Invoke every Windmill test script annotated with `// test:` / `# test:`
# against the target workspace and fail if any throw.
#
# Runs after the per-item `wmill <type> push` loop in deploy.yml — by then
# the test scripts are deployed alongside the runnables they cover, so
# calling them via run_wait_result exercises the live workspace state. A
# test that throws returns non-2xx and fails this script (and therefore
# the deploy workflow).
#
# Convention:
#   - Test files live next to the runnable they cover, named <name>_test.ts.
#   - First line is the annotation, e.g. `// test: script/f/shared/load_cs_metrics`.
#   - The test exports `main()` and `throw`s on assertion failure.
#
# Test scripts must be idempotent and side-effect-free — they execute
# against the production workspace.
#
# Retries (opt-in, deploy.yml input `test_retries`):
#   DEPLOY_TEST_RETRIES              extra attempts for FAILED tests (default 0)
#   DEPLOY_TEST_RETRY_DELAY_SECONDS  pause before each retry round (default 30)
# Every test runs once. Then, up to DEPLOY_TEST_RETRIES times, only the
# tests still failing are re-run after the delay. A test that passes only on
# a retry passes the job but gets a ::warning:: annotation, so the flake
# stays visible; a test that fails every attempt fails the job exactly as
# before. With DEPLOY_TEST_RETRIES=0 (the default) nothing is re-run and the
# behaviour is exactly the pre-retry one — including exiting immediately on
# a curl transport error, which with retries on is treated as a retryable
# failure instead.

set -euo pipefail

WORKSPACE="${WMILL_WORKSPACE:-thanx}"
# Use the direct origin (bypasses Cloudflare). grid.thanx.com is proxied through
# Cloudflare for browser traffic; API callers (CI, deploy scripts) need the
# origin hostname or they hit Cloudflare Access challenges.
BASE_URL="${WMILL_BASE_URL:-https://grid-origin.thanx.com}"
TOKEN="${WINDMILL_DEPLOY_TOKEN:?need WINDMILL_DEPLOY_TOKEN env}"
RETRIES="${DEPLOY_TEST_RETRIES:-0}"
RETRY_DELAY="${DEPLOY_TEST_RETRY_DELAY_SECONDS:-30}"

# Fail loud on a mistyped knob rather than silently running without retries.
if ! [[ "$RETRIES" =~ ^[0-9]+$ ]]; then
  echo "::error::DEPLOY_TEST_RETRIES (deploy.yml input test_retries) must be a non-negative integer, got '$RETRIES'" >&2
  exit 1
fi
# Base 10: a leading zero ("08") must not be read as octal.
RETRIES=$((10#$RETRIES))
# The delay only matters with retries on; deploy.yml documents it as ignored
# at 0, so don't fail a retries-off run over it.
if (( RETRIES > 0 )); then
  if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
    echo "::error::DEPLOY_TEST_RETRY_DELAY_SECONDS (deploy.yml input test_retry_delay_seconds) must be a non-negative integer, got '$RETRY_DELAY'" >&2
    exit 1
  fi
  RETRY_DELAY=$((10#$RETRY_DELAY))
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Test discovery: any TS/Py file under f/ whose first non-blank line is a
# `test:` annotation comment.
tests=()
while IFS= read -r file; do
  first_line=$(grep -m1 -E '^\s*\S' "$file" || true)
  if [[ "$first_line" =~ ^[[:space:]]*(//|#)[[:space:]]*test: ]]; then
    tests+=("$file")
  fi
done < <(find f -type f \( -name '*.ts' -o -name '*.py' \) | sort)

if (( ${#tests[@]} == 0 )); then
  echo "No test scripts found. (Annotate a script with '// test: script/<path>' to add one.)"
  exit 0
fi

echo "Found ${#tests[@]} test script(s). Running against $WORKSPACE..."
echo

# Single temp file reused across iterations + a single EXIT trap. The
# previous shape (mktemp + trap inside the loop) overwrote the trap on
# every iteration, so only the last temp file was cleaned and N-1 leaked
# into $TMPDIR.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# run_test <script_path>: run one test via run_wait_result, print the
# outcome, and set test_ok=1 (2xx) or test_ok=0. Called as a plain command
# (never in an `if`/`||` condition) so `set -e` still applies inside it.
test_ok=0
run_test() {
  local script_path="$1" http_code body curl_rc=0
  echo "▶ $script_path"

  # Truncate first: when curl fails before any response it leaves -o alone,
  # and the previous test's body would be printed as this one's.
  : >"$tmp"
  http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$BASE_URL/api/w/$WORKSPACE/jobs/run_wait_result/p/$script_path" \
    -d '{}') || curl_rc=$?
  if (( curl_rc != 0 )); then
    if (( RETRIES == 0 )); then
      # No retries: exit with curl's status, as this script always has.
      exit "$curl_rc"
    fi
    http_code="${http_code:-000} (curl exit $curl_rc)"
  fi

  if [[ "$http_code" =~ ^2 ]]; then
    echo "  ✅ ok"
    test_ok=1
  else
    body=$(cat "$tmp")
    echo "  ❌ HTTP $http_code"
    echo "  $body" | sed 's/^/  /'
    test_ok=0
  fi
}

failed=()
for file in "${tests[@]}"; do
  # Map file path → Windmill script path. f/shared/foo_test.ts → f/shared/foo_test
  script_path="${file%.ts}"
  script_path="${script_path%.py}"
  run_test "$script_path"
  (( test_ok )) || failed+=("$script_path")
done

# Retry rounds: only the tests still failing, after a pause.
flaky=()          # script paths that passed on a retry
flaky_attempt=()  # ...and on which retry
attempt=0
while (( ${#failed[@]} > 0 && attempt < RETRIES )); do
  attempt=$((attempt + 1))
  echo
  echo "↻ Retry $attempt/$RETRIES: re-running ${#failed[@]} failed test(s) after ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
  still_failing=()
  for script_path in "${failed[@]}"; do
    run_test "$script_path"
    if (( test_ok )); then
      flaky+=("$script_path")
      flaky_attempt+=("$attempt")
    else
      still_failing+=("$script_path")
    fi
  done
  # Guarded: "${empty[@]}" trips `set -u` on bash < 4.4 (macOS /bin/bash).
  failed=()
  if (( ${#still_failing[@]} > 0 )); then failed=("${still_failing[@]}"); fi
done

echo

if (( ${#flaky[@]} > 0 )); then
  for i in "${!flaky[@]}"; do
    echo "::warning::Flaky deploy test ${flaky[$i]}: failed, then passed on retry ${flaky_attempt[$i]}/$RETRIES. Fix the flake, or the retry will hide a real regression one day."
  done
fi

if (( ${#failed[@]} > 0 )); then
  echo "::error::Deploy tests failed:" >&2
  for f in "${failed[@]}"; do
    echo "  - $f" >&2
  done
  if (( RETRIES > 0 )); then
    echo "  (still failing after $RETRIES retry round(s))" >&2
  fi
  exit 1
fi

echo "✅ All deploy tests passed."
