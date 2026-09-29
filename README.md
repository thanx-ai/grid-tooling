# The Grid

Reusable GitHub Actions workflows + a Claude Code plugin (`grid`) for shipping to **Grid** — Thanx's self-hosted [Windmill](https://windmill.dev) workspace at `https://grid.thanx.com`.

> **Public repository.** `thanx-ai/grid-tooling` ships as a public repo so individual project repos (which may themselves be private) can pull it in via `uses: thanx-ai/grid-tooling/...@<ref>` without needing GitHub App tokens for cross-repo workflow access. **Never** commit anything sensitive here: no tokens, no internal hostnames beyond `grid.thanx.com` / `grid-origin.thanx.com`, no real customer data, no `.env` files. The `.gitignore` and CI guards catch the obvious foot-guns; the rest is on us.

This repo is **not** where Grid code lives. It's the shared infrastructure that individual project repos pull in to deploy to the Grid. Apps, scripts, and flows live in each person's own GitHub repo (see [`thanx-ai/grid-shared`](https://github.com/thanx-ai/grid-shared) for the canonical reference).

## What's here

### 1. Reusable GitHub Actions workflows

Two workflows under `.github/workflows/` that project repos call via `uses:` from their own `.github/workflows/grid.yml`:

- **`ci.yml`** — lints every `.raw_app/`, validates that every literal `wmill.getVariable("f/...")` reference resolves in the prod workspace.
- **`deploy.yml`** — pushes the **full `f/**` inventory** every master deploy, one item at a time with `wmill <type> push` (`app`, `script`, `flow`, `resource`, `variable`, `schedule`, `trigger`, `folder`). `wmill push` content-hashes each item and no-ops the unchanged ones, so a full push is cheap — and because every deploy pushes everything, an item that ever missed its deploy window self-heals on the next run with no commit-range bookkeeping. Each push is an upsert: it creates or updates the remote item but **never deletes**. Items go out in dependency order: folders, then runnables/data, then schedules/triggers. Each bun script is pushed **after the local files it imports**, so its first lock build doesn't run against a missing import (import cycles excepted; see [`claude/rules/deploy-script-import-order.md`](./claude/rules/deploy-script-import-order.md)). Then executes deploy tests. See [`claude/rules/per-item-push-not-sync.md`](./claude/rules/per-item-push-not-sync.md) for why this isn't `wmill sync push`, and [`claude/rules/deploy-full-inventory.md`](./claude/rules/deploy-full-inventory.md) for why we push everything (and the workspace-edits-get-reverted tradeoff).

#### Optional `deploy.yml` inputs

| Input                      | Default                           | What it does                                                                                                                                                                                                                                                                            |
| -------------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_retries`             | `0`                               | Re-run **only the failed** deploy tests up to N more rounds before failing the job. A test that passes only on a retry still passes, but gets a `::warning::` annotation so the flake stays visible. A test that fails every attempt fails the job exactly as before. `0` = no retries. |
| `test_retry_delay_seconds` | `30`                              | Pause before each retry round.                                                                                                                                                                                                                                                          |
| `skip_tests`               | `false`                           | Skip deploy tests entirely. Use sparingly.                                                                                                                                                                                                                                              |
| `base_url` / `workspace`   | `grid-origin.thanx.com` / `thanx` | Target Windmill instance and workspace.                                                                                                                                                                                                                                                 |
| `wmill_version`            | `1.700.1`                         | `windmill-cli` version installed for the push.                                                                                                                                                                                                                                          |

```yaml
  deploy:
    uses: thanx-ai/grid-tooling/.github/workflows/deploy.yml@master
    with:
      test_retries: 2   # for tests that hit a flaky upstream; flakes still get annotated
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

Retries are for transient failures, not a fix for a deterministic 504. A test that deadlocks on a nested job fails every attempt (see [`claude/rules/deploy-test-no-nested-job.md`](./claude/rules/deploy-test-no-nested-job.md)).

### 2. The `grid` Claude Code plugin

Under `.claude-plugin/` and `skills/`. Three slash commands, distinct jobs:

| Command            | When to use                                                                                                                                            | What it does                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`/grid:setup`**  | Once per project repo, right after `git init` (or when adopting Grid in an existing repo).                                                             | Scaffolds `wmill.yaml`, the `.github/workflows/grid.yml` workflow caller, walks you through minting the deploy token, and copies the Grid conventions into `claude/rules/`. If the repo already has app code that doesn't directly fit Grid (Next.js, Flask, Streamlit, …), also writes `GRID_MIGRATION.md` with a per-signal "what to change" checklist. Setup continues either way. **Repo-level** bootstrap. |
| **`/grid:create`** | Each time you want to start a **new** raw_app from scratch.                                                                                            | Asks which scope folder (`f/company/` or `f/<dept>/`) the app should live in, then scaffolds the canonical raw_app layout with placeholder content you fill in. **App-level**, no existing source.                                                                                                                                                                                                              |
| **`/grid:import`** | When you have **existing** code (GitHub URL, local project, single `.html` dashboard, or a single `.js`/`.ts` script) you want to bring onto the Grid. | Same per-app scope question as `/grid:create`. Runs a compatibility assessment first — if the source uses Next.js / Tailwind / websockets / submodules / etc., produces a migration plan naming the Grid-supported replacement tech and the surgery required. Then either scaffolds (if you've done the surgery) or writes `GRID_MIGRATION.md` and bails. **App-level**, existing source.                       |

### Migration philosophy

A repo or source that doesn't fit Grid as-is is **not refused** — it gets a migration plan. The skills detect every signal that requires rework (Next.js → plain React + client router, Tailwind → vanilla CSS, Flask → decomposed Windmill scripts, Supabase → Windmill resources, websockets → drop or relocate, etc.), name the Grid-supported replacement tech, and list the per-signal surgery. The only hard stops are credential leaks (per security policy), 5 MB+ binary blobs in HTML sources, and source-mode misclassification (wrong tool for the source shape).

### Installing the plugin

Claude Code uses a two-step marketplace + plugin model. Register this repo as a marketplace, then install the `grid` plugin from it:

```text
# In any Claude Code session:
/plugin marketplace add thanx-ai/grid-tooling
/plugin install grid@thanx-ai-grid-tooling
/reload-plugins
```

The marketplace name is auto-derived from the repo slug (`thanx-ai/grid-tooling` → `thanx-ai-grid-tooling`). After install + reload, subsequent sessions see `/grid:setup`, `/grid:create`, and `/grid:import` in the slash-command palette automatically.

**To pin a specific ref** at marketplace-add time, append `#<ref>` to the slug. We ship on `master`, so the unpinned form is the normal path; `#<branch>` is for testing a feature branch:

```text
/plugin marketplace add thanx-ai/grid-tooling#<branch>     # feature branch you're testing
/plugin install grid@thanx-ai-grid-tooling
```

**To refresh** the marketplace listing after the repo is updated upstream: `/plugin marketplace update thanx-ai-grid-tooling`.

**To uninstall:** `/plugin uninstall grid@thanx-ai-grid-tooling`. To also remove the marketplace catalog entry: `/plugin marketplace remove thanx-ai-grid-tooling`.

If the `/plugin` commands aren't recognised, your Claude Code is older than the plugin system release — upgrade Claude Code (`claude --version` should be ≥ the version called out in `#ai-help-desk` pinned messages), then retry.

## Quickstart

Each person owns their own project repo. Create one, install the plugin, run `/grid:setup`:

```bash
gh repo create thanx-ai/<your-username>-grid --private
cd <your-username>-grid
claude
# in the Claude Code session:
/plugin marketplace add thanx-ai/grid-tooling
/plugin install grid@thanx-ai-grid-tooling
/reload-plugins
/grid:setup
```

`/grid:setup` will:

1. Scaffold `wmill.yaml`, `.github/workflows/grid.yml`, and copy the Grid conventions into `claude/rules/`.
2. Walk you through minting a Windmill deploy token (`grid.thanx.com` → User → Account Settings → Tokens → New Token) and storing it as the `WINDMILL_DEPLOY_TOKEN` repo secret.

The resulting `.github/workflows/grid.yml` looks like:

```yaml
name: Grid

on:
  push:
    branches: [master]
  pull_request:

jobs:
  ci:
    uses: thanx-ai/grid-tooling/.github/workflows/ci.yml@master
    secrets:
      WMILL_READ_TOKEN: ${{ secrets.WMILL_READ_TOKEN }}

  deploy:
    if: github.ref == 'refs/heads/master'
    needs: ci
    # No `with: includes:` input — deploy.yml pushes the full f/** inventory
    # on every master merge with `wmill <type> push` (unchanged items no-op
    # on their content hash). See claude/rules/deploy-full-inventory.md.
    uses: thanx-ai/grid-tooling/.github/workflows/deploy.yml@master
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

That's it — merges to `master` deploy automatically.

## Adoption is opt-in and additive

Projects already deploying via their own pipelines keep their existing workflows. The plugin adds files; it doesn't replace existing CI. Adopt the reusable workflows when you want to retire your own deploy plumbing — never as a forced migration.

## Where apps live

Every app you ship to the Grid lands in one of two folders, picked **per-app** based on use-case (not per-repo):

- **`f/company/`** — workspace-wide. Use when the app is genuinely cross-functional and everyone at Thanx should be able to find and run it.
- **`f/<dept>/`** — department-scoped (`f/eng/`, `f/cs/`, `f/sales/`, …). Workspace-wide read+run; dept-group write via SCIM. Use when the app is owned by one team, even if other teams might occasionally read it.

Both folders are readable workspace-wide; the distinction is ownership and write access. Default to `f/<dept>/`; reach for `f/company/` only when an app truly belongs to no single department.

A single project repo can ship apps to both folders — `/grid:create` asks each time.

## Versioning

We ship on `master`. Always pin callers to `@master`. Breaking changes are announced via `#ai-help-desk` before they land.

This is a deliberate trade for a pre-`v1` Thanx-internal repo: every merge to `master` ships to every consumer on their next workflow run, so there's no run-to-run reproducibility and no way to opt out of a breaking change without re-pinning. We accept that because the alternative (every project repo separately tracks tag bumps while the surface is unstable) costs more than it saves. Revisit at `v1`.

Earlier `v0.x` tags still exist on the remote from before this policy landed; they're frozen and won't be updated. Don't pin to them — they exist only so older callers don't break instantly.

## Help

- Questions, bugs, access issues — `#ai-help-desk` on Slack.
- Convention questions — read `claude/rules/` first; they capture every gotcha that's bitten us in the past.
- PR review — request `@eng-platform`.

## Developing this repo

See [`DEVELOPING.md`](./DEVELOPING.md) for plugin and workflow development.
