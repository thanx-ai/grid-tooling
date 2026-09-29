# The deploy pushes the full `f/**` inventory every master deploy

**Rule.** `deploy.yml` pushes **every** deployable `f/**` item on every master deploy — not just the items changed in the commit range — one at a time with `wmill <type> push`. `wmill push` content-hashes each item and no-ops the ones that haven't changed, so a full push is cheap. Still upsert-only / never-delete (see [`per-item-push-not-sync.md`](./per-item-push-not-sync.md)); it never runs `wmill sync push`.

## Why full inventory and not a commit-range diff

A commit-range diff (`git diff before..after`, push only what changed) has a silent drift hole: if an item ever **misses its deploy window**, nothing ever pushes it. The pipeline stays green while the workspace is out of sync, and there's no self-healing. It bit us:

> `thanx/ergane`'s `f/ergane/ergane_admin.raw_app/` landed while the Grid workflow was broken (it pointed at the pre-rename `thanx-ai/grid` repo, so every run died at resolution with zero jobs). The app missed its only deploy window and had to be recovered days later by committing a trivial change to force it back into a deploy range.

Pushing the full inventory removes the failure mode entirely: there's no "window" to miss. The next deploy of *anything* re-pushes everything, so a straggler converges with no special-casing — no commit-range edge cases (zero-SHA initial push, force-pushed `before`, root commit) to get wrong, and no separate reconcile/existence-check pass to maintain. The simplicity is the point.

## The accepted tradeoff: the repo is authoritative on every deploy

Because every deploy re-pushes every item, **the repo wins over the workspace on every deploy** — and `wmill <type> push` is an upsert ("overrides any remote versions"). For `app` and `script`, `wmill push` skips the write when the content hash matches, so an untouched item is left alone. But the simpler types (`folder`, `resource`, `variable`, `schedule`) are re-`PUT` each deploy.

The consequence to know: **a workspace-side (UI) edit to a variable value or a schedule's cron gets reverted on the next deploy of anything** — even a deploy that changed something unrelated. This is deliberate (GitOps: the repo is the source of truth), but it surprises people who tweak a value in the Grid UI and watch it disappear.

- Keep values you care about **in the repo** (`.variable.yaml` / `.schedule.yaml`), not only in the UI.
- For a secret whose real value must live only in the workspace, don't ship a `.variable.yaml` that overwrites it — manage that variable out-of-band (created once in the UI / via a scoped token), and keep the repo's `getVariable("f/...")` reference pointing at it without re-pushing its value. (The CI reference check in `check-variable-references.sh` verifies the path resolves; it does not push the value.)

## Don't "optimize" it back to a commit-range diff

It's tempting to make the deploy faster by pushing only changed items again. Don't — not without re-solving the drift-recovery problem that motivated this. If full-inventory push ever becomes too slow (many large apps re-bundling), the right fix is a content-hash short-circuit for the simpler types or parallelizing the push loop, **not** reintroducing the silent missed-window hole.

## How to verify

- `scripts/list-grid-items.sh` enumerates the full tracked `f/**` set (via `git ls-files`) through the shared classifier (`scripts/classify-grid-paths.sh`), in `wmill push` dependency order. It then runs `scripts/order-by-imports.sh`, which pushes each bun script after the local files it imports (see [`deploy-script-import-order.md`](./deploy-script-import-order.md)). `scripts/deploy-grid-items.sh` pipes the result into `scripts/push-grid-items.sh`.
- Covered offline by `scripts/test/list-grid-items-test.sh` (enumeration + untracked-file exclusion + dependency order), which runs in `self-test.yml` with no live workspace.
- After a deploy, the run log lists every item pushed; unchanged `app`/`script` items log as up-to-date rather than a new version.
