#!/usr/bin/env bash
# Reorder the bun (`.ts`) `script` records of a classified Grid record
# stream (read from stdin) so every script is pushed AFTER the local files
# it imports. Every other record passes through untouched, in its slot.
#
# Usage (list-grid-items.sh does exactly this, from the repo root):
#   git ls-files -- 'f/**' | scripts/classify-grid-paths.sh | scripts/order-by-imports.sh
# The script paths in the records are opened relative to the current
# directory, so run it from the repo root.
#
# Why: classify-grid-paths.sh sorts tier 1 (runnables/data) lexically, so
# `f/x/a_test.ts` was pushed before the `f/x/z_loader.ts` it imports. The
# importer's lock build resolves relative imports against the WORKSPACE, and
# on a first push (or when the importer needs a new export) the imported
# file isn't there yet: the lock build fails, the script never gets a
# deployed version, and its deploy test 404s ("script not found") or fails
# to build ("No matching export"). The lock build only needs the imported
# file to exist, so pushing importees first is enough. See
# claude/rules/deploy-script-import-order.md.
#
# What counts as a local import (line-based scan of each `.ts` script):
#   import ... from "./x.ts"   export { ... } from "../x.ts"   export * from "./x.ts"
#   import "./x.ts"            import ... from "/f/<folder>/x.ts"  (workspace-absolute)
#   ... including multi-line `import {\n a,\n} from "./x.ts"` clauses, and
#   a dynamic import with a literal specifier anywhere on a line:
#   `await import("./x.ts")`, `() => import("./x.ts").then(...)`. The
#   bundler behind the lock build follows those like static imports (a
#   specifier held in a variable, `import(MOD)`, it can't see, and neither
#   can this scan).
# An extensionless "./x" resolves to x.ts. Only imports that resolve to
# another `.ts` script record in the stream create an ordering edge.
# Ignored, because they are erased before bundling (counting them would
# turn the usual type-only back-reference into a false cycle):
# `import type` / `export type`, a brace list whose every specifier is
# `type X` (`import { type A, type B } from`), and type positions
# `typeof import("./x.ts")` / `import("./x.ts").SomeType`. Also ignored:
# bare / npm: / URL specifiers, `//` comments, and anything that doesn't
# resolve to a `.ts` script record (e.g. a `.sql` asset). The scan assumes
# one import statement per line start (what every formatter emits); an
# import inside a /* block comment */ or a template string still counts —
# that only adds an ordering constraint, never drops one.
#
# Order: the lexicographically-smallest topological order — the next `.ts`
# script pushed is the alphabetically-first one whose local imports have all
# been pushed. With no local imports that is exactly the input order, so a
# repo without relative imports deploys in the same order as before.
# Non-`.ts` script records (and every non-script record) keep their exact
# slots; only `.ts` script records are permuted among the `.ts` slots.
#
# Cycles (a.ts imports b.ts imports a.ts): no order can satisfy them, so the
# cycle's members go out in alphabetical order, and all of them are emitted
# a SECOND time right after the last `.ts` script — by then every member
# exists on the workspace, which is all a re-run lock build needs. A
# `::warning::` names the cycle. The re-push is best-effort: if
# `wmill script push` finds the script unchanged it reports "up to date" and
# skips the write, so the durable fix is to break the cycle.
#
# Output: the input records, with the `.ts` script records reordered (plus
# any cycle re-push records). Summary / warnings go to stderr — stdout is
# the record stream push-grid-items.sh consumes.

set -euo pipefail

# LC_ALL=C: byte semantics for substr/regex (the BOM check below compares
# bytes) and identical behaviour across macOS awk, mawk and gawk.
bom=$'\xef\xbb\xbf'

# `read -d ''` rather than "$(cat <<'AWK' ...)": macOS /bin/bash 3.2 can't
# parse a quoted heredoc holding unbalanced quotes inside $(...), and the
# preview (`bash scripts/list-grid-items.sh`) should run there too. read
# returns 1 at the end of the heredoc, hence `|| true`.
IFS= read -r -d '' awk_prog <<'AWK' || true
BEGIN {
  FS = "\t"
  nrec = 0; nnode = 0; last_slot = 0
  # Cap on continuation lines for one import statement; a statement that
  # never closes (malformed file) must not swallow the rest of the file.
  MAXLINES = 1000
}

{
  rec[++nrec] = $0
  if ($1 == "script" && $2 ~ /\.ts$/ && !($2 in node_of)) {
    node_path[++nnode] = $2
    node_of[$2] = nnode
    node_rec[nnode] = nrec
    slot[nrec] = 1
    last_slot = nrec
  }
}

# `import type ...` / `export type ...` — but not `import type from "./x"`
# (a default import that happens to be NAMED `type`) or `import type, {..}`.
function is_type_only(s) {
  if (s !~ /^[ \t]*(import|export)[ \t]+type([ \t{*]|$)/) return 0
  if (s ~ /^[ \t]*import[ \t]+type[ \t]+from[ \t]*["']/) return 0
  return 1
}

# `import { type A, type B } from` / `export { type A } from`: a brace list
# with no default or namespace binding whose every specifier is `type X`
# (joined multi-line clauses included). Erased like `import type`. The one
# exception is `{ type as X }`, a VALUE binding named `type`.
function all_inline_type(s,    body, n, items, i, it, seen) {
  if (s !~ /^[ \t]*(import|export)[ \t]*\{[^}]*\}[ \t]*from[ \t]*["']/) return 0
  body = s
  sub(/^[ \t]*(import|export)[ \t]*\{/, "", body)
  sub(/\}.*$/, "", body)
  n = split(body, items, ",")
  seen = 0
  for (i = 1; i <= n; i++) {
    it = items[i]
    sub(/^[ \t]+/, "", it); sub(/[ \t]+$/, "", it)
    if (it == "") continue
    if (it !~ /^type[ \t]+[A-Za-z0-9_$]/) return 0
    if (it ~ /^type[ \t]+as[ \t]+[A-Za-z0-9_$]+$/) return 0
    seen++
  }
  return seen > 0
}

# A line that can begin a value import/re-export we care about.
function is_candidate(s) {
  if (s ~ /^[ \t]*import([ \t{*"']|$)/) return !is_type_only(s)
  if (s ~ /^[ \t]*export[ \t]*[{*]/) return 1
  return 0
}

# The import clause (between the keyword and `from`) holds no quotes or
# semicolons, so the statement is complete once a string literal closes or
# a `;` appears.
function stmt_complete(s) {
  return (s ~ /["'][^"']*["']/ || index(s, ";") > 0)
}

# Drop a `//` comment. Only when it starts the line or follows whitespace,
# so the `//` inside a "https://..." specifier survives.
function strip_line_comment(s) {
  if (s ~ /^[ \t]*\/\//) return ""
  sub(/[ \t]\/\/.*$/, "", s)
  return s
}

# Resolve a specifier against the importing file. Returns a repo-relative
# path, or "" if the specifier isn't local.
function resolve(importer, spec,    p, n, i, parts, out, m, seg) {
  if (spec ~ /^\.\.?\//) {
    p = importer
    sub(/\/[^\/]*$/, "", p)       # dirname
    p = p "/" spec
  } else if (spec ~ /^\/f\//) {
    p = substr(spec, 2)           # /f/... is workspace-absolute == repo-root f/...
  } else {
    return ""
  }
  n = split(p, parts, "/")
  m = 0
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") { if (m == 0) return ""; m--; continue }
    out[++m] = seg
  }
  if (m == 0) return ""
  p = out[1]
  for (i = 2; i <= m; i++) p = p "/" out[i]
  return p
}

function add_import(k, s,    spec) {
  if (all_inline_type(s)) return
  if (match(s, /from[ \t]*["'][^"']*["']/)) {
    spec = substr(s, RSTART, RLENGTH)
    sub(/^from[ \t]*["']/, "", spec)
  } else if (match(s, /^[ \t]*import[ \t]*["'][^"']*["']/)) {
    spec = substr(s, RSTART, RLENGTH)
    sub(/^[ \t]*import[ \t]*["']/, "", spec)
  } else {
    return
  }
  sub(/["']$/, "", spec)
  add_spec(k, spec)
}

# Literal dynamic imports anywhere on a (comment-stripped) line. Skipped:
# `foo.import(` / `reimport(` (not the keyword), and the erased type
# positions `typeof import("./x")` and `import("./x").SomeType` (a member
# access other than then/catch/finally).
function scan_dynamic(k, s,    rest, m, before, after, spec) {
  rest = s
  while (match(rest, /import[ \t]*\([ \t]*["'][^"']*["'][ \t]*\)/)) {
    m = substr(rest, RSTART, RLENGTH)
    before = substr(rest, 1, RSTART - 1)
    after = substr(rest, RSTART + RLENGTH)
    rest = after
    if (before ~ /[A-Za-z0-9_$.]$/) continue
    if (before ~ /typeof[ \t]*$/) continue
    if (after ~ /^[ \t]*\.[ \t]*[A-Za-z_$]/ && after !~ /^[ \t]*\.[ \t]*(then|catch|finally)([^A-Za-z0-9_$]|$)/) continue
    spec = m
    sub(/^import[ \t]*\([ \t]*["']/, "", spec)
    sub(/["'][ \t]*\)$/, "", spec)
    add_spec(k, spec)
  }
}

function add_spec(k, spec,    p, d) {
  p = resolve(node_path[k], spec)
  if (p == "") return
  if (!(p in node_of) && ((p ".ts") in node_of)) p = p ".ts"
  if (!(p in node_of)) return
  d = node_of[p]
  if (d == k || ((k, d) in has_dep)) return
  has_dep[k, d] = 1
  dep[k, ++ndep[k]] = d
  nedges++
}

function scan_file(k,    file, line, rc, stmt, collecting, nlines, first) {
  file = node_path[k]
  collecting = 0; nlines = 0; first = 1; stmt = ""
  while ((rc = (getline line < file)) > 0) {
    if (first) { first = 0; if (substr(line, 1, 3) == BOM) line = substr(line, 4) }
    sub(/\r$/, "", line)
    if (index(line, "import")) scan_dynamic(k, strip_line_comment(line))
    if (line ~ /^[ \t]*(import|export)([^A-Za-z0-9_$]|$)/) {
      # A new statement: salvage an unterminated previous one, then decide
      # whether this one is worth collecting.
      if (collecting) add_import(k, stmt)
      collecting = 0
      if (!is_candidate(line)) continue
      stmt = strip_line_comment(line); nlines = 1
      if (stmt_complete(stmt)) add_import(k, stmt)
      else collecting = 1
      continue
    }
    if (!collecting) continue
    stmt = stmt " " strip_line_comment(line)
    if (stmt_complete(stmt) || ++nlines >= MAXLINES) { add_import(k, stmt); collecting = 0 }
  }
  if (rc < 0) {
    # Not fatal: the push of this file will fail loudly on its own. Here it
    # just keeps its alphabetical position.
    printf "order-by-imports: warning: cannot read %s; leaving it in alphabetical position\n", file > "/dev/stderr"
    return
  }
  close(file)
  if (collecting) add_import(k, stmt)
}

END {
  nedges = 0
  for (k = 1; k <= nnode; k++) scan_file(k)

  # reach[k, x]: x is (transitively) imported by k.
  for (k = 1; k <= nnode; k++) {
    qh = 1; qt = 0
    for (j = 1; j <= ndep[k] + 0; j++) {
      d = dep[k, j]
      if (!((k, d) in reach)) { reach[k, d] = 1; q[++qt] = d }
    }
    while (qh <= qt) {
      x = q[qh++]
      for (j = 1; j <= ndep[x] + 0; j++) {
        d = dep[x, j]
        if (!((k, d) in reach)) { reach[k, d] = 1; q[++qt] = d }
      }
    }
  }

  # Strongly connected components, each named by its smallest (i.e.
  # alphabetically first) member. A component of size > 1 is an import cycle.
  for (k = 1; k <= nnode; k++) {
    comp[k] = k
    for (j = 1; j < k; j++) {
      if (((k, j) in reach) && ((j, k) in reach)) { comp[k] = j; break }
    }
    csize[comp[k]]++
  }
  for (k = 1; k <= nnode; k++) {
    for (j = 1; j <= ndep[k] + 0; j++) {
      c = comp[k]; e = comp[dep[k, j]]
      if (c != e && !((c, e) in cdep_seen)) { cdep_seen[c, e] = 1; cdep[c, ++ncdep[c]] = e }
    }
  }

  # Kahn over the component DAG: always emit the ready component whose
  # first member sorts first; members of a component go out in input order.
  remaining = 0
  for (c = 1; c <= nnode; c++) if (comp[c] == c) remaining++
  nout = 0
  while (remaining > 0) {
    pick = 0
    for (c = 1; c <= nnode && !pick; c++) {
      if (comp[c] != c || (c in emitted)) continue
      ready = 1
      for (j = 1; j <= ncdep[c] + 0; j++) if (!(cdep[c, j] in emitted)) { ready = 0; break }
      if (ready) pick = c
    }
    if (!pick) {
      print "order-by-imports: internal error: no ready component (not a DAG?)" > "/dev/stderr"
      exit 1
    }
    emitted[pick] = 1; remaining--
    for (k = pick; k <= nnode; k++) if (comp[k] == pick) order[++nout] = k
  }

  # Cycle members, in push order, get a second push after the last .ts slot.
  nrep = 0; ncycles = 0
  for (i = 1; i <= nout; i++) {
    k = order[i]
    if (csize[comp[k]] > 1) repush[++nrep] = k
  }
  for (c = 1; c <= nnode; c++) {
    if (comp[c] != c || csize[c] < 2) continue
    ncycles++
    members = ""
    for (k = c; k <= nnode; k++) if (comp[k] == c) members = members (members == "" ? "" : ", ") node_path[k]
    printf "::warning::Import cycle between Grid scripts: %s. Pushed alphabetically, then pushed again once all exist; wmill skips an unchanged re-push as up to date, so break the cycle (move the shared code into its own module). See claude/rules/deploy-script-import-order.md\n", members > "/dev/stderr"
  }
  if (nedges > 0) {
    printf "order-by-imports: %d local import edge(s) across %d bun script(s)%s; importers pushed after the files they import.\n", nedges, nnode, (ncycles > 0 ? sprintf(", %d cycle(s)", ncycles) : "") > "/dev/stderr"
  }

  s = 0
  for (r = 1; r <= nrec; r++) {
    if (!(r in slot)) { print rec[r]; continue }
    print rec[node_rec[order[++s]]]
    if (r == last_slot) for (i = 1; i <= nrep; i++) print rec[node_rec[repush[i]]]
  }
}
AWK

LC_ALL=C awk -v BOM="$bom" "$awk_prog"
