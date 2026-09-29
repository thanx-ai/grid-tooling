---
title: "Deploy pushes a bun script after the local files it imports — don't create import cycles"
tags: [deploy, wmill-push, relative-imports, lock, deploy-tests]
---

**Rule.** `deploy.yml` pushes every `.ts` script **after** the local files it imports (`./x.ts`, `../x.ts`, `/f/<folder>/x.ts`), so its lock build never runs against an import that isn't on the workspace yet. You get this for free — but it can't order an **import cycle** (`a.ts` imports `b.ts` imports `a.ts`), so keep shared code in a module that imports neither side.

## Why it bit us

The push loop used to go through each tier alphabetically. A script's server-side lock build resolves its relative imports **against the workspace**, not the repo checkout. So when a new `f/x/a_test.ts` imported a new `f/x/z_loader.ts`, `a_test` was pushed first, its lock build couldn't find `z_loader`, and the script was left with **no deployed version**. The deploy test then failed in one of two ways:

- `404 script not found` — the importer never got a deployed version at all.
- `No matching export` — the imported file *existed* but was the old version, without the export the importer now needs.

What the lock build needs is only for the imported file to **exist** on the workspace. So pushing importees first is enough.

## What the deploy does

`scripts/order-by-imports.sh` runs between the classifier and the push loop (`list-grid-items.sh` → `classify-grid-paths.sh | order-by-imports.sh`). Within the runnables tier it:

- scans each `.ts` script for **value** imports of another `.ts` script in the repo: `import … from`, `export … from`, side-effect `import "./x.ts"`, multi-line clauses, extensionless `./x` (which resolves to `x.ts`), and **dynamic imports with a literal specifier** (`await import("./x.ts")`, `() => import("./x.ts").then(…)`), because the lock build's bundler follows those too. A specifier held in a variable (`import(MOD)`) is invisible to both the bundler and this scan;
- **ignores** type-only imports (`import type` / `export type`, a brace list whose every specifier is `type X`, and `typeof import("./x.ts")` / `import("./x.ts").SomeType`), `//` comments, bare/npm/URL specifiers, and anything that isn't a `.ts` script record (a `.sql` asset, a `.js` helper);
- pushes in the **lexicographically-smallest topological order**: the next script is the alphabetically-first one whose imports have all been pushed. With no local imports that is exactly the old alphabetical order. Every non-`.ts` record, `.py`/`.js` scripts included, keeps its exact slot.

Type-only imports are skipped on purpose, because the transpiler erases them before bundling. The common "`b.ts` does `import type { A } from './a.ts'` while `a.ts` value-imports `b.ts`" shape would otherwise look like a cycle. (Windmill's own import parser *does* list type-only imports for its dependency tracking. If a deploy ever shows a type-only import racing, look there first.)

## Import cycles

A cycle has no valid order. The deploy pushes its members alphabetically, then **pushes them all a second time** right after the last `.ts` script, when every member exists. It also emits a `::warning::Import cycle between Grid scripts: …` annotation. The push log marks the repeats `(again: import-cycle second push …)`.

The second push is **best-effort**. `wmill script push` skips a script whose content and metadata match the remote ("is up to date"). In a repo that doesn't commit script metadata, the first push writes a local `.script.yaml`/`.script.lock`, and a later push in the same checkout compares against those instead of regenerating the lock. So within one deploy the re-push may be a no-op that doesn't rebuild the lock. (This is from reading the `windmill-cli@1.700.1` source; it hasn't been observed live.) The next deploy starts from a fresh checkout, regenerates the lock while both members exist, and should converge. The fix that always works is to **break the cycle**: move the code both sides need into a third module that imports neither.

## How to verify

- The deploy run's **Push all Grid items** log opens with `Will push N item(s):` in push order. Every importer should appear below what it imports. If the repo has local imports, there is also a one-line `order-by-imports:` summary, plus a `::warning::` per cycle. To preview the order without deploying, run `bash <grid-tooling checkout>/scripts/list-grid-items.sh` from the project repo's root. It only reads files.
- In `thanx-ai/grid-tooling`, the offline tests are `scripts/test/order-by-imports-test.sh` and `scripts/test/list-grid-items-test.sh`. The first covers import shapes (dynamic imports included), the type-only / comment exclusions, slot preservation, cycles, and an end-to-end run through `deploy-grid-items.sh` with a fake `wmill`.
- A deploy test that 404s or reports `No matching export` right after a first push points at this ordering, not at your test.
