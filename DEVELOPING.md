# Developing `thanx-ai/grid-tooling`

This doc covers developing the reusable workflows and the `grid` Claude Code plugin **in this repo**. For working in a project repo against the Grid (the consumer side), see the rules under `claude/rules/` — they're copied into each project repo by the `setup` skill.

## Layout reminder

```
.claude-plugin/         # plugin manifest + marketplace.json
.github/workflows/
  ci.yml                # reusable: lint raw apps + check variable refs
  deploy.yml            # reusable: per-item `wmill <type> push` + deploy tests
  self-test.yml         # this repo's own CI (actionlint + shellcheck)
claude/rules/           # conventions (canonical; plugin copies to project repos)
scripts/                # bash scripts invoked by reusable workflows
skills/                 # plugin skills (setup, create, import)
```

## Local development

You need:

- `bash` (Linux/macOS — Windows via WSL).
- `shellcheck` — `brew install shellcheck` / `apt install shellcheck`.
- `actionlint` (optional but recommended) — `bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)`.
- `gh` — for testing workflow changes against `thanx-ai/grid-shared`.

You do **not** need:

- A local Windmill instance (the meta-repo doesn't run scripts itself).
- A `wmill` CLI install (it's installed inside the reusable workflows at runtime).

## Offline script tests

`scripts/test/*-test.sh` are behavioral tests for the deploy scripts. They build throwaway git repos and put fake `wmill` / `curl` / `sleep` binaries on `PATH`, so they never touch a workspace. `self-test.yml` runs every one of them (its `script-tests` job). Run them locally before pushing:

```bash
for t in scripts/test/*-test.sh; do bash "$t" || echo "FAILED: $t"; done
```

They need bash 4+ (`push-grid-items.sh` uses `mapfile`). On macOS, `brew install bash` and make sure it's first on `PATH`. A change to push order (`classify-grid-paths.sh`, `order-by-imports.sh`) or to deploy-test handling (`run-deploy-tests.sh`) should come with a case in the matching test. The tests prove the scripts' logic. They don't replace the `grid-shared` end-to-end run below, which is the only check against a live workspace.

## Iterating on a reusable workflow

The self-test workflow (`self-test.yml`) only catches YAML and shell syntax errors. Semantic regressions (checkout pattern, ref resolution, lint behavior) only show up against a real caller. The dev loop:

1. Make the change on a feature branch in this repo.
2. Push the branch.
3. In `thanx-ai/grid-shared`, temporarily change the workflow ref from `@master` to `@<your-branch>` in `.github/workflows/grid.yml`.
4. Open a PR in `grid-shared` against its master to trigger CI. Or push to a branch and `workflow_dispatch`.
5. Watch the run in the GitHub Actions tab.
6. When green, revert the workflow ref in `grid-shared` and merge your meta-repo PR.

```bash
# In thanx-ai/grid-shared:
sed -i '' 's|@master|@<your-branch>|g' .github/workflows/grid.yml
git checkout -b test-thanx-ai-grid-<your-branch>
git commit -am "test: pin to <your-branch>"
gh pr create --draft
```

After CI passes, **don't merge the grid-shared test PR** — close it and revert the ref locally.

## Iterating on the plugin

Plugin skills are markdown files under `skills/<name>/SKILL.md`. They're read by Claude Code at invocation time; no compilation step. To test locally:

1. Push your feature branch to `thanx-ai/grid-tooling`, then register the marketplace pointing at that branch:
   ```text
   /plugin marketplace add thanx-ai/grid-tooling#<your-branch>
   /plugin install grid@thanx-ai-grid-tooling
   /reload-plugins
   ```
   (If the marketplace was already registered against a different ref, run `/plugin marketplace update thanx-ai-grid-tooling` to refresh after pushing.)
2. Open a fresh test repo (`mkdir /tmp/grid-test && cd /tmp/grid-test && git init`).
3. Run the skill: `/grid:setup`.
4. Inspect the scaffolded files and the bundled-rules copy.

If the skill produces wrong output, edit `skills/<name>/SKILL.md`, push to your branch, run `/plugin marketplace update thanx-ai-grid-tooling` to refresh, and re-test.

## Adding a new rule

Rules under `claude/rules/` are picked up by Claude at the start of every session in this repo, and copied into project repos by `setup` (Step 4).

To add one:

1. Write `claude/rules/<topic>.md` with YAML frontmatter (`title`, `tags`).
2. Lead with one sentence summarizing the rule.
3. Explain _why_ it bit us (what was confusing, what the buggy assumption was).
4. Explain _how to verify_ (a check, a command, a regex).
5. Decide whether it applies to project repos. If meta-repo-internal only (e.g. about workflow authoring), add the filename to the skip-list in `skills/setup/SKILL.md` Step 4.

## Releasing

There is no release step. We ship on `master`: every merge to `master` is live for every project repo on its next workflow run, because callers pin `@master`. That means PR review **is** the release gate — don't merge anything you wouldn't want every project repo running on its next deploy.

For breaking changes (workflow input/secret renames, removed scaffolded files), announce in `#ai-help-desk` **before** merging so consumers can update their callers in lockstep.

**Rollback:** if a merge to `master` ships a regression, open a revert PR and merge it. Every consumer's next workflow run resolves `@master` afresh, so the revert lands automatically — no need to touch consumer repos. For a fast-moving incident, a Thanx-org admin can also push a revert commit directly to `master` (followed by the standard post-incident PR).

## Style conventions

- Prose: "the Grid" lowercase-determiner. Exact strings preserved: `thanx-ai/grid-tooling` (repo), `grid` (plugin name), `# The Grid` (README title). The plugin previously shipped as `thanx-grid` — don't reintroduce that name.
- Slack: `#ai-help-desk` for all access/help/bug questions. There is no `#eng-platform` channel.
- GitHub: `@eng-platform` is the review team.
- Skill `description:` frontmatter must include trigger phrases the user is likely to type (e.g. "set up grid", "bootstrap grid in this repo").
- Workflow `description:` fields are required on every input and secret. Generated docs render them.

## Pre-merge checklist

Because merging is releasing, every PR needs:

- [ ] Self-test CI green (`actionlint` + `shellcheck`)
- [ ] `grid-shared` workflow tested end-to-end against the PR branch (see "Iterating on a reusable workflow" above)
- [ ] If breaking: announced in `#ai-help-desk` with the upgrade path **before** merge
