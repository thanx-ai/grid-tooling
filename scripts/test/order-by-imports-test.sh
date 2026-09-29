#!/usr/bin/env bash
# Test scripts/order-by-imports.sh — pushes each bun (.ts) script after the
# local files it imports, so a first push never builds a lock against an
# import that isn't on the workspace yet.
#
# Asserts:
#   - a repo with no local imports comes out byte-identical (today's order);
#   - value imports order the importee first: relative, `../`, extensionless,
#     multi-line, side-effect, `export ... from`, workspace-absolute `/f/`,
#     BOM + CRLF files, and transitive chains;
#   - type-only imports, dynamic import(), `//` comments, `.js` / `.sql` /
#     missing / out-of-tree targets create NO edge;
#   - every non-`.ts` record (other types AND .py/.js scripts) keeps its slot;
#   - a cycle stays alphabetical, its members are re-emitted right after the
#     last .ts script (before tier 2), and a ::warning:: names it;
#   - end to end, deploy-grid-items.sh (with a fake `wmill`) pushes in that
#     order and marks the cycle's second push.
#
# Runs offline: throwaway directories + a fake `wmill` on PATH. Never
# touches a workspace.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
order="$scripts/order-by-imports.sh"
classify="$scripts/classify-grid-paths.sh"

for f in "$order" "$classify" "$scripts/deploy-grid-items.sh"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: cannot find $f" >&2
    exit 1
  fi
done

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

# ---------------------------------------------------------------------------
# 1. No local imports -> exactly the classifier's order, nothing on stderr.
# ---------------------------------------------------------------------------
plain="$tmp/plain"
mkdir -p "$plain/f/eng/widget.raw_app"
cd "$plain"
echo 'summary: eng' >f/eng/folder.meta.yaml
echo '{}' >f/eng/widget.raw_app/app.yaml
printf 'import * as wmill from "windmill-client";\nimport dayjs from "npm:dayjs";\nexport async function main() {}\n' >f/eng/alpha.ts
printf 'export async function main() {}\n' >f/eng/beta.ts
printf 'def main():\n    pass\n' >f/eng/gamma.py
printf 'script_path: f/eng/alpha\n' >f/eng/daily.schedule.yaml

plain_in="$(find f -type f | bash "$classify")"
plain_out="$(bash "$order" <<<"$plain_in" 2>"$tmp/plain.err")"
check "no local imports: output identical to the classifier's order" \
  test "$plain_out" = "$plain_in"
check "no local imports: nothing on stderr" test ! -s "$tmp/plain.err"

# ---------------------------------------------------------------------------
# 2. The main fixture.
# ---------------------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo/f/eng/lib" "$repo/f/eng/widget.raw_app" "$repo/f/eng/pipe.flow"
cd "$repo"

# put <file-under-f/eng> <content with \n / \r / \xHH escapes>
put() { printf '%b' "$2" >"f/eng/$1"; }
main_fn='export async function main() { return 1 }\n'

echo 'summary: eng' >f/eng/folder.meta.yaml
echo '{}' >f/eng/widget.raw_app/app.yaml
echo 'summary: a flow' >f/eng/pipe.flow/flow.yaml
printf 'value:\n  host: example.invalid\n' >f/eng/conn.resource.yaml
printf 'value: placeholder\n' >f/eng/token.variable.yaml
printf 'script_path: f/eng/a_test\n' >f/eng/a_daily.schedule.yaml

# Transitive chain: a_test -> z_loader -> lib/fmt (extensionless, subdir).
put a_test.ts   'import { main as load } from "./z_loader.ts";\nexport async function main() { return load() }\n'
put z_loader.ts 'import { fmt } from "./lib/fmt";\nexport async function main() { return fmt(1) }\n'
put lib/fmt.ts  'import * as wmill from "windmill-client";\nexport const fmt = (n: number) => String(n);\n'"$main_fn"

# Type-only imports in every shape — none may create an edge. y_rows has a
# VALUE import back to b_types: counting the type imports would make a
# false cycle.
put b_types.ts  'import type { Row } from "./y_rows.ts";\nexport type { Row } from "./y_rows.ts";\nimport type {\n  Other,\n} from "./y_rows.ts";\nimport type * as NS from "./y_rows.ts";\nexport type Local = Row;\n'"$main_fn"
put y_rows.ts   'import { helper } from "./b_types.ts";\nexport type Row = { id: number };\nexport type Other = Row;\n'"$main_fn"

# Dynamic import: no edge (c_dyn stays before x_dyn).
put c_dyn.ts    'export async function main() { const m = await import("./x_dyn.ts"); return m }\n'
put x_dyn.ts    "$main_fn"

# Multi-line value import through `../eng/`, with a comment holding `;` and
# a quote inside the clause.
put d_multi.ts  'import {\n  one,\n  two, // it'"'"'s here; really\n} from "../eng/w_multi.ts";\n'"$main_fn"
put w_multi.ts  "$main_fn"

# Side-effect import; `export * from`; `export { x } from`.
put e_side.ts    'import "./v_side.ts";\n'"$main_fn"
put v_side.ts    "$main_fn"
put f_reexport.ts 'export * from "./u_star.ts";\nexport { t } from "./t_named.ts";\n'"$main_fn"
put u_star.ts    "$main_fn"
put t_named.ts   "$main_fn"

# Workspace-absolute specifier.
put g_abs.ts    'import { s } from "/f/eng/s_abs.ts";\n'"$main_fn"
put s_abs.ts    "$main_fn"

# A commented-out import is not an import.
put h_comment.ts '// import { r } from "./r_commented.ts";\n'"$main_fn"
put r_commented.ts "$main_fn"

# Imports of a .js script, a .sql asset, a missing file and an out-of-tree
# path: no edges, no errors. The .js and .py scripts keep their slots.
put i_js.ts     'import { q } from "./q_helper.js";\nimport sql from "./query.sql" with { type: "text" };\nimport { nope } from "./does_not_exist.ts";\nimport { out } from "../../../../outside.ts";\n'"$main_fn"
put q_helper.js 'export function main() { return 1 }\n'
put query.sql   'select 1\n'
put p_script.py 'def main():\n    return 1\n'

# UTF-8 BOM + CRLF line endings.
put j_bom.ts    '\xef\xbb\xbfimport { l } from "./l_crlf.ts";\r\nexport async function main() { return l }\r\n'
put l_crlf.ts   'export const l = 1;\r\n'"$main_fn"

# A cycle (m <-> n) and a script downstream of it that sorts before both.
put m_cyc.ts    'import { n } from "./n_cyc.ts";\nexport const m = 1;\n'"$main_fn"
put n_cyc.ts    'import { m } from "./m_cyc.ts";\nexport const n = 1;\n'"$main_fn"
put k_downstream.ts 'import { m } from "./m_cyc.ts";\n'"$main_fn"

in="$(find f -type f | bash "$classify")"
out="$(bash "$order" <<<"$in" 2>"$tmp/order.err")"
err="$(cat "$tmp/order.err")"

echo "--- order-by-imports.sh output ---"
printf '%s\n' "$out"
echo "--- stderr ---"
printf '%s\n' "$err"
echo "----------------------------------"

rec() { printf 'script\t%s' "$1"; }
# 1-based line of the first occurrence of an exact record in $out (0 = none).
pos() {
  local n
  n="$(grep -nxF -m1 -- "$1" <<<"$out" | cut -d: -f1 || true)"
  printf '%s\n' "${n:-0}"
}
count() { grep -cxF -- "$1" <<<"$out" || true; }
before() { # before <pathA> <pathB>: script A is pushed (first) before script B
  local a b
  a="$(pos "$(rec "$1")")"
  b="$(pos "$(rec "$2")")"
  [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]
}

# Nothing lost, nothing invented: output = input + one extra copy of each
# cycle member.
expected_multiset="$( { printf '%s\n' "$in"; printf 'script\tf/eng/m_cyc.ts\nscript\tf/eng/n_cyc.ts\n'; } | LC_ALL=C sort)"
actual_multiset="$(printf '%s\n' "$out" | LC_ALL=C sort)"
check "output = input records + one re-push per cycle member" \
  test "$actual_multiset" = "$expected_multiset"

# Every record that is not a .ts script keeps its exact slot. Records after
# the last .ts slot shift down by the two cycle re-push records inserted
# there, and by nothing else.
last_ts_slot="$(awk -F'\t' '$1 == "script" && $2 ~ /\.ts$/ { n = NR } END { print n }' <<<"$in")"
slots_ok=true
n=0
while IFS= read -r line; do
  n=$((n + 1))
  case "$line" in script$'\t'*.ts) continue ;; esac
  want_line=$n
  [ "$n" -gt "$last_ts_slot" ] && want_line=$((n + 2))
  got="$(sed -n "${want_line}p" <<<"$out")"
  if [ "$got" != "$line" ]; then
    echo "  slot $n moved: want '$line' at line $want_line, got '$got'" >&2
    slots_ok=false
  fi
done <<<"$in"
check "non-.ts records (incl. .py/.js scripts, app, flow, schedule) keep their slots" "$slots_ok"

# Value imports: importee first.
check "relative import: z_loader before a_test"            before f/eng/z_loader.ts f/eng/a_test.ts
check "extensionless ./lib/fmt: lib/fmt.ts before z_loader" before f/eng/lib/fmt.ts f/eng/z_loader.ts
check "transitive: lib/fmt.ts before a_test"               before f/eng/lib/fmt.ts f/eng/a_test.ts
check "multi-line ../eng/ import: w_multi before d_multi"  before f/eng/w_multi.ts f/eng/d_multi.ts
check "side-effect import: v_side before e_side"           before f/eng/v_side.ts f/eng/e_side.ts
check "export * from: u_star before f_reexport"            before f/eng/u_star.ts f/eng/f_reexport.ts
check "export { } from: t_named before f_reexport"         before f/eng/t_named.ts f/eng/f_reexport.ts
check "workspace-absolute /f/ import: s_abs before g_abs"  before f/eng/s_abs.ts f/eng/g_abs.ts
check "BOM + CRLF file: l_crlf before j_bom"               before f/eng/l_crlf.ts f/eng/j_bom.ts
check "downstream of a cycle: m_cyc before k_downstream"   before f/eng/m_cyc.ts f/eng/k_downstream.ts
check "downstream of a cycle: n_cyc before k_downstream"   before f/eng/n_cyc.ts f/eng/k_downstream.ts

# Not imports: alphabetical order survives.
check "type-only imports ignored: b_types stays before y_rows" before f/eng/b_types.ts f/eng/y_rows.ts
check "type-only back-reference is not a cycle (b_types pushed once)" \
  test "$(count "$(rec f/eng/b_types.ts)")" -eq 1
not_contains() { ! grep -qF -- "$1" <<<"$2"; }
check "type-only back-reference: no warning about it" not_contains b_types "$err"
check "dynamic import() ignored: c_dyn stays before x_dyn"     before f/eng/c_dyn.ts f/eng/x_dyn.ts
check "commented-out import ignored: h_comment before r_commented" before f/eng/h_comment.ts f/eng/r_commented.ts

# Unconstrained scripts keep alphabetical order among themselves.
free_order="$(grep -E $'^script\tf/eng/(c_dyn|h_comment|i_js|r_commented|x_dyn)\\.ts$' <<<"$out" | cut -f2 | tr '\n' ' ')"
check "unconstrained scripts stay alphabetical" \
  test "$free_order" = "f/eng/c_dyn.ts f/eng/h_comment.ts f/eng/i_js.ts f/eng/r_commented.ts f/eng/x_dyn.ts "

# The cycle: alphabetical, pushed twice, re-push right after the last .ts
# slot (so before any schedule/trigger), warned about.
check "cycle members stay alphabetical"   before f/eng/m_cyc.ts f/eng/n_cyc.ts
check "cycle member m_cyc pushed twice"   test "$(count "$(rec f/eng/m_cyc.ts)")" -eq 2
check "cycle member n_cyc pushed twice"   test "$(count "$(rec f/eng/n_cyc.ts)")" -eq 2
check "downstream k_downstream pushed once" test "$(count "$(rec f/eng/k_downstream.ts)")" -eq 1
check "cycle re-push follows the last .ts slot" \
  test "$(sed -n "$((last_ts_slot + 1)),$((last_ts_slot + 2))p" <<<"$out" | cut -f2 | tr '\n' ' ')" = "f/eng/m_cyc.ts f/eng/n_cyc.ts "
check "cycle re-push comes before the schedule" \
  test "$(pos "$(printf 'schedule\tf/eng/a_daily.schedule.yaml\tf/eng/a_daily')")" -gt "$((last_ts_slot + 2))"
check "cycle ::warning:: names both members" \
  grep -qF '::warning::Import cycle between Grid scripts: f/eng/m_cyc.ts, f/eng/n_cyc.ts.' <<<"$err"
check "exactly one cycle warning" test "$(grep -c '^::warning::' <<<"$err")" -eq 1

# ---------------------------------------------------------------------------
# 3. End to end: deploy-grid-items.sh (list -> order -> push) with a fake
#    wmill that records its calls instead of talking to a workspace.
# ---------------------------------------------------------------------------
git init -q
git config user.email test@example.com
git config user.name test
git add -A
git commit -q -m fixture

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/wmill" <<'SH'
#!/usr/bin/env bash
# Fake wmill: log "<type> <verb> <args...>" without the connection flags.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace|--base-url|--token) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
printf '%s\n' "${args[*]}" >>"$WMILL_CALLS"
SH
chmod +x "$fakebin/wmill"

calls="$tmp/wmill.calls"
: >"$calls"
deploy_rc=0
deploy_log="$(PATH="$fakebin:$PATH" WMILL_CALLS="$calls" \
  WMILL_BASE_URL=http://wmill.invalid WMILL_WORKSPACE=offline-test \
  WINDMILL_DEPLOY_TOKEN=offline-test-placeholder \
  bash "$scripts/deploy-grid-items.sh" 2>&1)" || deploy_rc=$?
check "deploy: deploy-grid-items.sh exits 0" test "$deploy_rc" -eq 0

call_pos() { # 1-based index of the first wmill call equal to "$1" (0 = none)
  local n
  n="$(grep -nxF -m1 -- "$1" "$calls" | cut -d: -f1 || true)"
  printf '%s\n' "${n:-0}"
}
pushed_before() {
  local a b
  a="$(call_pos "script push $1")"
  b="$(call_pos "script push $2")"
  [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]
}
check "deploy: pushes lib/fmt.ts before z_loader.ts" pushed_before f/eng/lib/fmt.ts f/eng/z_loader.ts
check "deploy: pushes z_loader.ts before a_test.ts"  pushed_before f/eng/z_loader.ts f/eng/a_test.ts
check "deploy: pushes the folder first" \
  test "$(head -n1 "$calls")" = "folder push eng"
check "deploy: cycle member pushed twice" \
  test "$(grep -cxF 'script push f/eng/m_cyc.ts' "$calls")" -eq 2
check "deploy: log marks the second push" \
  grep -qF 'again: import-cycle second push' <<<"$deploy_log"

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "order-by-imports test FAILED" >&2
  exit 1
fi

echo
echo "all order-by-imports assertions passed"
