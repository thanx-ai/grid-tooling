# CLAUDE.md

Guidance for Claude Code working in this repo.

## This is a public repo

`thanx-ai/grid-tooling` is published as a public GitHub repo. **Never write anything sensitive into this tree** — no tokens, deploy keys, API secrets, internal-only URLs (besides the already-public `grid.thanx.com` / `grid-origin.thanx.com`), customer data, employee PII, or `.env` files. If you're about to commit anything that looks like a credential, stop and route it to the consuming repo's GitHub Actions secrets instead. The `.gitignore` covers obvious files (`.env`, `.env.*`, `.wmill/`) but it can't catch a token hardcoded into a workflow YAML — review every diff with that lens before pushing.

## Read first

At the start of every session, read every file under `claude/rules/`. Those capture specific gotchas that bit us in past sessions; the bar for adding one is "this surprised us once and would surprise us again." If a rule there contradicts something below, the rule wins (and fix this file in the same PR).

## What this repo is

`thanx-ai/grid-tooling` is a **meta-repo**, not a content repo. It ships two things:

1. **Reusable GitHub Actions workflows** (`.github/workflows/ci.yml`, `deploy.yml`) that project repos call via `uses: thanx-ai/grid-tooling/.github/workflows/deploy.yml@master`. The deploy workflow does **per-item** `wmill <type> push` against the Grid (`https://grid.thanx.com`) — never `wmill sync push`, because that would let one project repo's deploy delete items owned by another. See [`claude/rules/per-item-push-not-sync.md`](./claude/rules/per-item-push-not-sync.md).
2. **`grid` — a Claude Code plugin** (under `.claude-plugin/` and `skills/`) that bootstraps individual project repos: scaffolds `wmill.yaml`, the repo's thin `.github/workflows/grid.yml`, and copies the conventions in `claude/rules/` into the project repo so future Claude sessions there pick them up.

**There is no `f/` content in this repo.** Grid code lives in each person's own project repo (e.g. `thanx-ai/grid-shared`, which is the canonical reference). If you're tempted to add an `f/<scope>/...` file here, you're solving the wrong problem — it belongs in a project repo.

## Architecture

### The scope model

Grid code is owned per-person, not per-team. Each person has their own GitHub project repo; inside it, **each item picks its own scope folder**:

| Folder       | Use when                                                                    |
| ------------ | --------------------------------------------------------------------------- |
| `f/company/` | The item is genuinely cross-functional and everyone at Thanx should use it. |
| `f/<dept>/`  | The item is owned by one department (`f/eng/`, `f/cs/`, `f/sales/`, …).     |

Both are workspace-readable; the distinction is ownership and write access (dept-group write via SCIM for `f/<dept>/`, broader for `f/company/`). The `u/<you>/` namespace exists in Windmill but the plugin's scaffolders don't target it — prototypes live as drafts in the same project repo, not as a separate maturity tier.

The plugin's `/grid:create` (and sibling scaffolders) asks scope per item. A single project repo routinely ships to both `f/company/` and `f/<dept>/`.

### Reusable workflows

Both reusable workflows follow the same pattern: checkout the caller, checkout `thanx-ai/grid-tooling@master` into `.grid-meta/`, invoke shared scripts under `.grid-meta/scripts/`. See [`claude/rules/reusable-workflow-meta-checkout.md`](./claude/rules/reusable-workflow-meta-checkout.md) for why `master` and not the SHA the reusable workflow YAML was loaded at. **Every caller is on `@master` anyway, so the small within-run drift window is consistent with the across-run policy.**

The workflows expect callers to follow the Grid conventions (folder-permissioned `f/` paths, raw_app layout, deploy-test annotation pattern). Those conventions are documented in `claude/rules/` and ride along into project repos via the plugin's `setup` skill (Step 4).

### Versioning

We ship on `master`. Callers pin `uses: thanx-ai/grid-tooling/.github/workflows/<name>.yml@master` and pick up every merge automatically — there are no version tags. The meta-checkout inside the reusable workflows also pins to `master` (see [`claude/rules/reusable-workflow-meta-checkout.md`](./claude/rules/reusable-workflow-meta-checkout.md) for why we can't use the workflow's resolved SHA against an external caller); both sides converge on whatever's on `master` at job-start time — by design.

Because every merge is a live release, treat every PR like one: don't merge anything to `master` that you wouldn't want every project repo running on its next deploy. Breaking changes to workflow inputs, secret names, or scaffolded files need to be announced in `#ai-help-desk` before they land.

## Layout

```
.claude-plugin/         # plugin manifest + marketplace.json
.github/workflows/      # reusable workflows + self-test
  ci.yml                # reusable: lint raw apps + check variable refs
  deploy.yml            # reusable: per-item `wmill <type> push` + deploy tests
  self-test.yml         # this repo's own CI (actionlint + shellcheck)
claude/rules/           # conventions Claude reads at session start
                        # (canonical source; plugin copies to project repos)
scripts/                # bash scripts invoked by reusable workflows
  lint-raw-apps.sh
  check-variable-references.sh
  classify-grid-paths.sh  # shared path->wmill-push-record classifier (stdin->stdout)
  list-grid-items.sh      # full f/** inventory -> classify-grid-paths.sh -> order-by-imports.sh
  order-by-imports.sh     # push each bun script after the local files it imports (stdin->stdout)
  push-grid-items.sh      # shared per-item `wmill <type> push` loop (stdin records)
  deploy-grid-items.sh    # deploy: list-grid-items.sh | push-grid-items.sh (full inventory)
  run-deploy-tests.sh     # `// test:` deploy tests; opt-in retry of failures (test_retries)
  test/*-test.sh          # offline behavioral tests (run by self-test.yml)
skills/                 # plugin skills (/grid:setup, /grid:create, /grid:import)
  setup/                # one-time repo bootstrap (wmill.yaml, workflow caller, token, rules)
  create/               # scaffold a NEW raw_app, picking scope per app
  import/               # adopt an EXISTING project / HTML file as a raw_app
```

## Common commands

```bash
# Verify a reusable-workflow change locally
shellcheck scripts/*.sh scripts/test/*.sh
bash -n scripts/*.sh

# Offline behavioral tests (what self-test.yml's script-tests job runs; bash 4+)
for t in scripts/test/*-test.sh; do bash "$t" || echo "FAILED: $t"; done

# After editing a workflow YAML, run actionlint:
bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
./actionlint -color

# Test a workflow change end-to-end against grid-shared
# 1. Push the change to a branch on this repo
# 2. In grid-shared, temporarily change @master → @<your-branch>
# 3. Trigger CI in grid-shared and watch it run against your branch
```

## What goes where

When making changes, route by purpose:

| Change                                    | File(s) to touch                                            |
| ----------------------------------------- | ----------------------------------------------------------- |
| Bug in lint/check/test bash script        | `scripts/<name>.sh`                                         |
| New optional workflow input               | `.github/workflows/<name>.yml`                              |
| Breaking workflow change                  | `.github/workflows/<name>.yml` — announce in `#ai-help-desk` before merge |
| New plugin skill                          | `skills/<name>/SKILL.md` + update `.claude-plugin/`         |
| Convention every project repo should know | `claude/rules/<topic>.md` — picked up by `setup`            |
| Internal rule (meta-repo authoring only)  | `claude/rules/<topic>.md` + skip-list in `setup`            |

## Self-test CI

`self-test.yml` runs on every PR. It does **not** touch a live Windmill workspace — only actionlint + shellcheck. To catch semantic regressions in the reusable workflows, push a branch and run `grid-shared`'s workflow against it (see Common commands above).

## Conventions

- Plugin skills live at `skills/<name>/SKILL.md`. The filename is fixed; the directory name is the skill name.
- Scripts use `bash`, are `set -euo pipefail`, and pass shellcheck. No silent fallbacks — fail loud.
- Workflow YAML files use 2-space indent. Inputs and secrets are explicitly typed and described.
- "the Grid" in prose; `thanx-ai/grid-tooling` (repo slug) and `grid` (plugin name) are exact strings preserved as-is. The plugin used to be called `thanx-grid` — don't reintroduce that name.
- Help / access questions: `#ai-help-desk` Slack channel. The GitHub team reviewer is `@eng-platform` (it exists as a GitHub team; the Slack channel of that name does not).

## Capture friction as rules

If you hit a non-obvious gotcha while working here — a misleading doc, a CLI flag whose behaviour surprises you, an API shape you got wrong, a CI check that silently passed when it shouldn't — capture the corrected guidance **in the same PR that fixes the problem**:

- Short, self-contained rule → new file under `claude/rules/<topic>.md` (one sentence lede, then _why_ it bit us and _how to verify_).
- Contradicts something here or in `README.md` → fix that text inline too.
- **A raw-app authoring rule also constrains the scaffolds.** When you add or change a `raw-app-*.md` rule, grep `skills/create/SKILL.md` and `skills/import/SKILL.md` for example code that the rule now contradicts and fix it in the same PR — the scaffolds emit the canonical shape, so stale example code there ships the exact bug the rule warns against. (This bit us: the `create` skill's `wmill.ts` stub kept emitting top-level functions and a `wmill.<id>(...)` call shape long after `raw-app-wmill-virtual.md` documented the `export const backend = {}` / `wmill.backend.<id>(args)` form.)

Rules that apply to project repos (e.g. raw-app authoring gotchas) ride along into every project repo via the `setup` skill. Rules that are meta-repo-internal (e.g. `reusable-workflow-meta-checkout.md`) stay here only — the skill's skip-list excludes them.

## Before requesting review

Wait for CI to come back **fully green**:

- `actionlint` — workflow YAML well-formed
- `shellcheck` — bash scripts clean
- `bash -n` — bash scripts parse

Yellow or red CI has shipped real production bugs in the predecessor of this repo — don't ask reviewers to look past warnings. Fix them, then request review.
