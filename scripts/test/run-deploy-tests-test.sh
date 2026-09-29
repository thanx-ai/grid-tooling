#!/usr/bin/env bash
# Test scripts/run-deploy-tests.sh — deploy-test discovery, pass/fail, and
# the opt-in retry loop (DEPLOY_TEST_RETRIES / DEPLOY_TEST_RETRY_DELAY_SECONDS,
# deploy.yml inputs test_retries / test_retry_delay_seconds).
#
# Asserts:
#   - retries unset/0 is exactly the old behaviour: every test runs once,
#     a failure fails the job, nothing is re-run, byte-for-byte log, and a
#     curl transport error still exits immediately with curl's status;
#   - with retries, ONLY failed tests are re-run, after the delay, up to N
#     rounds; a test that passes on a retry passes the job with a ::warning::
#     naming it; one that fails every attempt fails the job as before;
#   - a transport error is retryable when retries are on;
#   - a malformed knob fails loud instead of silently not retrying.
#
# Runs offline: a throwaway git repo plus a fake `curl` (answers from a
# per-test plan) and a fake `sleep` (records, never waits) on PATH. The base
# URL is a .invalid host, so even a real curl could not reach anything.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../run-deploy-tests.sh"
# Interpreter for the script under test; override to check another bash
# (e.g. BASH_UNDER_TEST=/bin/bash for macOS's bash 3.2).
bash_under_test="${BASH_UNDER_TEST:-bash}"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find run-deploy-tests.sh at $script" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

# --- fixture repo -----------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo/f/eng"
cd "$repo"
git init -q
printf '// test: script/f/eng/broken\nexport async function main() {}\n' >f/eng/broken_test.ts
printf '// test: script/f/eng/flaky\nexport async function main() {}\n' >f/eng/flaky_test.ts
printf '\n  // test: script/f/eng/pass\nexport async function main() {}\n' >f/eng/pass_test.ts
printf '# test: script/f/eng/py\ndef main():\n    pass\n' >f/eng/py_test.py
printf 'export async function main() {}\n' >f/eng/not_a_test.ts

# --- fakes ------------------------------------------------------------------
fakebin="$tmp/bin"
state="$tmp/state"
mkdir -p "$fakebin"

cat >"$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: answer run_wait_result/p/<path> from $FAKE_STATE/<key>.plan, a
# line of outcomes for the 1st, 2nd, ... call (the last one repeats). An
# outcome is an HTTP code, or curlN for a transport error with exit N.
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-X|-H|-d) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url##*/jobs/run_wait_result/p/}"
key="${path//\//_}"
n=$(( $(cat "$FAKE_STATE/$key.calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_STATE/$key.calls"
echo "$url" >>"$FAKE_STATE/urls"
plan=(200)
if [ -f "$FAKE_STATE/$key.plan" ]; then read -r -a plan <"$FAKE_STATE/$key.plan"; fi
i=$(( n <= ${#plan[@]} ? n - 1 : ${#plan[@]} - 1 ))
outcome="${plan[$i]}"
case "$outcome" in
  curl*)
    echo "curl: (${outcome#curl}) Failed to connect (fake)" >&2
    printf '000'
    exit "${outcome#curl}"
    ;;
  2*) printf '{"ok":true,"path":"%s"}' "$path" >"$out" ;;
  *)  printf '{"error":{"message":"boom %s #%s"}}' "$path" "$n" >"$out" ;;
esac
printf '%s' "$outcome"
SH

cat >"$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
# Fake sleep: record the requested duration, return at once.
echo "$*" >>"$FAKE_STATE/sleeps"
SH
chmod +x "$fakebin/curl" "$fakebin/sleep"

reset_state() { rm -rf "$state"; mkdir -p "$state"; }
plan() { # plan <script-path> <outcome>...
  local key="${1//\//_}"; shift
  printf '%s\n' "$*" >"$state/$key.plan"
}
calls() { # calls <script-path> -> how many times it was run
  local key="${1//\//_}"
  cat "$state/$key.calls" 2>/dev/null || echo 0
}
sleeps() { # the recorded sleep durations, space-joined ("" = never slept)
  if [ -f "$state/sleeps" ]; then tr '\n' ' ' <"$state/sleeps"; fi
}
# run_tests [VAR=value ...]: run the script in the fixture; sets $rc, $log.
run_tests() {
  rc=0
  log="$(cd "$repo" && env -u DEPLOY_TEST_RETRIES -u DEPLOY_TEST_RETRY_DELAY_SECONDS \
    PATH="$fakebin:$PATH" FAKE_STATE="$state" \
    WMILL_BASE_URL=http://deploy-tests.invalid WMILL_WORKSPACE=offline-test \
    WINDMILL_DEPLOY_TOKEN=offline-test-placeholder "$@" \
    "$bash_under_test" "$script" 2>&1)" || rc=$?
}
has() { grep -qF -- "$1" <<<"$log"; }
lacks() { ! grep -qF -- "$1" <<<"$log"; }
is() { test "$1" = "$2"; } # is <actual> <expected>

# --- 1. retries off, all green ---------------------------------------------
reset_state
run_tests
check "default, all pass: exit 0"                is "$rc" 0
check "default, all pass: success line"          has "✅ All deploy tests passed."
check "default, all pass: each test run once" \
  is "$(calls f/eng/broken_test)$(calls f/eng/flaky_test)$(calls f/eng/pass_test)$(calls f/eng/py_test)" 1111
check "default, all pass: un-annotated script not run" is "$(calls f/eng/not_a_test)" 0
check "default: hits run_wait_result on the configured base URL + workspace" \
  grep -qxF 'http://deploy-tests.invalid/api/w/offline-test/jobs/run_wait_result/p/f/eng/pass_test' "$state/urls"
check "default, all pass: no retry, no sleep, no warning" \
  test -z "$(sleeps)$(grep -F -e '↻' -e '::warning::' <<<"$log" || true)"

# --- 2. retries off, one failure: exactly the pre-retry log -----------------
reset_state
plan f/eng/flaky_test 500 200
run_tests
expected_log="$(cat <<'LOG'
Found 4 test script(s). Running against offline-test...

▶ f/eng/broken_test
  ✅ ok
▶ f/eng/flaky_test
  ❌ HTTP 500
    {"error":{"message":"boom f/eng/flaky_test #1"}}
▶ f/eng/pass_test
  ✅ ok
▶ f/eng/py_test
  ✅ ok

::error::Deploy tests failed:
  - f/eng/flaky_test
LOG
)"
check "default, a failure: exit 1"                     is "$rc" 1
check "default, a failure: log is exactly the pre-retry format" is "$log" "$expected_log"
check "default, a failure: failed test NOT re-run"     is "$(calls f/eng/flaky_test)" 1
check "default, a failure: no sleep"                   is "$(sleeps)" ""

# --- 3. retries off, transport error: still exits at once with curl's code -
reset_state
plan f/eng/broken_test curl7 200
run_tests
check "default, curl error: exits with curl's status (7)" is "$rc" 7
check "default, curl error: later tests not run (fail-fast, as before)" is "$(calls f/eng/flaky_test)" 0

# --- 4. retries=2: flaky passes on retry 1, broken fails every attempt ------
reset_state
plan f/eng/flaky_test 500 200
plan f/eng/broken_test 500
run_tests DEPLOY_TEST_RETRIES=2
check "retries=2: exit 1 (broken fails all 3 attempts)"  is "$rc" 1
check "retries=2: broken run 1 + 2 retries"              is "$(calls f/eng/broken_test)" 3
check "retries=2: flaky run until it passed"             is "$(calls f/eng/flaky_test)" 2
check "retries=2: passing tests never re-run" \
  is "$(calls f/eng/pass_test)$(calls f/eng/py_test)" 11
check "retries=2: default 30s delay before each round"   is "$(sleeps)" "30 30 "
check "retries=2: warning for the test that passed on retry" \
  has "::warning::Flaky deploy test f/eng/flaky_test: failed, then passed on retry 1/2."
check "retries=2: no warning for the test that never passed" \
  lacks "::warning::Flaky deploy test f/eng/broken_test"
check "retries=2: ::error:: lists only the still-failing test" \
  is "$(grep -A5 -xF '::error::Deploy tests failed:' <<<"$log")" \
     "$(printf '::error::Deploy tests failed:\n  - f/eng/broken_test\n  (still failing after 2 retry round(s))')"
check "retries=2: round 2 re-runs only the 1 still-failing test" \
  has "↻ Retry 2/2: re-running 1 failed test(s) after 30s..."

# --- 5. retries=2, delay 0: passes on the last retry -> green + warning ----
reset_state
plan f/eng/flaky_test 504 500 200
run_tests DEPLOY_TEST_RETRIES=2 DEPLOY_TEST_RETRY_DELAY_SECONDS=0
check "passes on retry 2/2: exit 0"                   is "$rc" 0
check "passes on retry 2/2: success line"             has "✅ All deploy tests passed."
check "passes on retry 2/2: warning names the retry"  has "passed on retry 2/2"
check "passes on retry 2/2: exactly one warning"      is "$(grep -c '^::warning::' <<<"$log")" 1
check "passes on retry 2/2: configured delay used"    is "$(sleeps)" "0 0 "

# --- 6. retries on, nothing fails: no retry round at all -------------------
reset_state
run_tests DEPLOY_TEST_RETRIES=3
check "retries=3, all pass: exit 0"                   is "$rc" 0
check "retries=3, all pass: no sleep, no retry banner" \
  test -z "$(sleeps)$(grep -F '↻' <<<"$log" || true)"

# --- 7. retries on: a transport error is retryable --------------------------
reset_state
plan f/eng/pass_test 200
plan f/eng/flaky_test curl7 200
run_tests DEPLOY_TEST_RETRIES=1 DEPLOY_TEST_RETRY_DELAY_SECONDS=0
check "retries=1, curl error then ok: exit 0"         is "$rc" 0
check "retries=1, curl error: reported as HTTP 000 with curl's exit" \
  has "❌ HTTP 000 (curl exit 7)"
check "retries=1, curl error: no stale body from the previous test" \
  is "$(grep -A1 -F '❌ HTTP 000' <<<"$log" | sed -n 2p)" "    "
check "retries=1, curl error: flagged flaky"          has "::warning::Flaky deploy test f/eng/flaky_test"

# --- 8. malformed knobs fail loud -------------------------------------------
reset_state
run_tests DEPLOY_TEST_RETRIES=abc
check "retries=abc: exit 1"                           is "$rc" 1
check "retries=abc: says why"                         has "must be a non-negative integer, got 'abc'"
check "retries=abc: no test run"                      test ! -e "$state/urls"
reset_state
run_tests DEPLOY_TEST_RETRIES=1 DEPLOY_TEST_RETRY_DELAY_SECONDS=-5
check "delay=-5: exit 1"                              is "$rc" 1
check "delay=-5: says why"                            has "DEPLOY_TEST_RETRY_DELAY_SECONDS"

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "run-deploy-tests test FAILED (last log below)" >&2
  printf '%s\n' "$log" >&2
  exit 1
fi

echo
echo "all run-deploy-tests assertions passed"
