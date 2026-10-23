---
name: create
description: Scaffold a new Windmill raw_app in this project repo. Asks which scope folder (`f/company/` or `f/<dept>/`) the app lives under, then creates the canonical full-code app layout. Use when the user says "new app", "add an app", "scaffold a raw_app", or "create a dashboard".
---

# create

Scaffold a new Windmill raw_app under this project repo. The output mirrors the canonical full-code layout — files live at the `.raw_app/` directory root (not nested under `src/`) — and the directory determines the remote app path (`<scope>/<name>.raw_app/` → deploys to `<scope>/<name>`).

## When NOT to use

- Editing an existing app — just edit the files directly.
- Building a backend script (not a frontend app) — use a plain `<scope>/<name>.script.ts` file instead, no `.raw_app/` wrapper.
- A new flow — use a `<scope>/<name>.flow/flow.yaml` file instead.

## Step 0: Confirm context

```bash
test -f wmill.yaml || { echo "no wmill.yaml — run /grid:setup first"; exit 1; }
```

If there's no `wmill.yaml`, stop and tell the user to run `/grid:setup`.

## Step 1: Pick the scope

Apps live in one of two top-level folders. The choice is **per app**, not per repo — one project repo can ship apps to both. Use `AskUserQuestion`:

> Where should this app live?
>
> 1. **`f/company/`** — workspace-wide. Everyone at Thanx can read and run it. Pick this when the app is genuinely cross-functional.
> 2. **`f/<dept>/`** — department-owned (`f/eng/`, `f/cs/`, `f/sales/`, …). Workspace-wide read+run; only the dept's SCIM group can write. Pick this when one team clearly owns the app.

If the user picks `f/<dept>/`, ask which department. Common ones: `engineering`, `product`, `design`, `success`, `operations`, `onboarding`, `support`, `finance`, `exec`, `marketing`, `sales`, `agents`, `scheduled`. Reject `f/shared/` — that folder is admin-only and not appropriate to scaffold under.

Store the chosen path as `<SCOPE>` (e.g. `f/company` or `f/engineering`).

## Step 2: Gather the inputs

Use `AskUserQuestion` to collect (one question at a time):

1. **App name** — `snake_case`, no spaces, no `.raw_app` suffix. Example: `merchant_health_dashboard`.
2. **Framework** — default `react18`. Options: `react18`, `react19`, `svelte5`, `vue`.
3. **One-line summary** — surfaces in the Windmill UI and in `raw_app.yaml`.
4. **Backend runnables** — optional. If the app calls existing workspace scripts, ask for their paths (e.g. `f/eng/load_cs_metrics`). For each, you'll create a `backend/<camelCaseName>.yaml` that references it. Cross-folder script references work as long as the script's folder grants read to `g/all` (which all `f/<dept>/` folders do by convention).

If a path collision exists (e.g. `<SCOPE>/merchant_health.script.ts` already exists and the user wants `merchant_health` as the app name), warn — Windmill allows both at the same path but it's confusing. Suggest a disambiguated name.

## Step 3: Pre-flight for external-system writes (conditional)

If any backend runnable named in Step 2 writes to an external system (Salesforce, Slack, Gmail, or similar — not just reading/aggregating internal data), stop and ask the user these four questions via `AskUserQuestion` before scaffolding anything:

1. **What can this touch?** Which systems, objects, or scopes can the runnable write to?
2. **What is the blast radius if it is wrong?** What happens downstream if this writes bad data or fires more than intended?
3. **Does it have a stable idempotency/dedup key?** Not an auto-generated ID that only exists after the write — a stable identifier (email, thread ID, external record ID) that exists before the write happens.
4. **Who reviews its failures, and how often?** A named owner and a cadence, not "someone will notice."

Worked example of what happens when this is skipped: a downstream consumer of this plugin had a draft-dedup bug where the check keyed on a new draft's own ID — a value that does not exist until after the write — instead of a stable identifier. Two unattended jobs silently re-created the same draft every run, accumulating hundreds of duplicates over months before anyone noticed. Full writeup lives in that project's own knowledge base (`context/knowledge/cos-architecture.md` in `chris-ai-workspace`, "Known issues") — not reproduced here since it is specific to that repo.

Record the answers in a short "Blast radius" note in the app's own `raw_app.yaml` description or a comment in the relevant `backend/<id>.yaml`, so the next person reading the app sees them too. If no backend runnable writes externally, skip this step.

## Step 4: Ensure the parent folder is set up

Apps under `f/<scope>/` need a `folder.meta.yaml` at `f/<scope>/folder.meta.yaml` so the Grid knows the folder's permissions. If it doesn't exist yet, scaffold one.

```bash
test -f "<SCOPE>/folder.meta.yaml" || {
  mkdir -p "<SCOPE>"
  # Write folder.meta.yaml — content depends on which scope (see below).
}
```

**For `f/company/`:**

```yaml
summary: Workspace-wide cross-functional apps and scripts
display_name: company
extra_perms:
  admin@windmill.dev: true
  g/all: false
owners:
  - admin@windmill.dev
```

**For `f/<dept>/`** (substitute the actual dept name for `<DEPT>`):

```yaml
summary: <Dept> team-owned apps and scripts
display_name: <DEPT>
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/<DEPT>: true
owners:
  - admin@windmill.dev
```

`g/all: false` is workspace-wide read+run (the value is the _write_ bit). `g/<DEPT>: true` grants write to the dept's SCIM group.

**Special case — `f/success/`**: the Google Workspace SCIM group is `customer_success` (predates the folder rename). Use `g/customer_success: true` for the success folder until the SCIM rename ships.

If the SCIM group `g/<DEPT>` doesn't exist in Google Workspace yet, the dept's members won't have write access — the YAML grant is a no-op until provisioned. Request new groups in `#ai-help-desk`.

## Step 5: Scaffold the files

Create the directory and files in this exact shape:

```
<SCOPE>/<name>.raw_app/
├── raw_app.yaml          # required descriptor
├── package.json          # minimal deps for the chosen framework
├── index.tsx             # entry point — calls ReactDOM.createRoot
├── App.tsx               # root component — placeholder content
├── index.css             # styles — minimal reset
├── wmill.ts              # local dev stub for typed runnables
└── backend/
    └── <runnable>.yaml   # one per backend script the app calls (optional)
```

### File contents

**`raw_app.yaml`:**

```yaml
summary: <one-line summary>
description: <optional longer description, can be omitted>
framework: <react18|react19|svelte5|vue>
```

**`package.json`** (for react18):

```json
{
  "name": "<name>",
  "private": true,
  "type": "module",
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0"
  }
}
```

For `react19`, use `^19.0.0` for react/react-dom and `^19.0.0` for @types/\*.

**`index.tsx`:**

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
```

**`App.tsx`** (placeholder):

```tsx
import * as wmill from "./wmill";
import "./index.css";

// Replace the h1 text with the app's display name in Title Case.
export default function App() {
  return (
    <main>
      <h1>App Name</h1>
      <p>TODO: render dashboard.</p>
    </main>
  );
}
```

**`index.css`** (minimal reset):

```css
:root {
  font-family: system-ui, sans-serif;
  color: #1a1814;
  background: #f1ece1;
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}
html,
body,
#root {
  min-height: 100vh;
}
main {
  padding: 2rem;
  max-width: 960px;
  margin: 0 auto;
}
```

**`wmill.ts`** (hand-authored local-dev / typecheck stub — at build time the Windmill CLI replaces this whole module with the wmill-virtual runtime client, whose only surviving export is `backend`. Mirror that shape: export `backend` as an **object** of typed mock methods, NOT top-level functions. See `claude/rules/raw-app-wmill-virtual.md`.):

```ts
// Hand-authored local-dev / typecheck stub. At build time the Windmill CLI
// swaps this whole module for the wmill-virtual runtime client — the only
// export that survives is `backend`. Keep these signatures in sync with the
// backend/<id>.yaml runnables so App.tsx typechecks against the real shape.

// One type per runnable's return value.
export type ExampleRow = { id: string; label: string };

export const backend = {
  // One method per backend/<id>.yaml. The method name MUST match the YAML
  // filename: backend/loadCsMetrics.yaml → wmill.backend.loadCsMetrics(...).
  // Methods take a single args OBJECT. The mock body runs only under
  // `wmill app dev`; production proxies the call to the real runnable.
  async loadCsMetrics(
    _args: { lookbackDays?: number } = {},
  ): Promise<ExampleRow[]> {
    return [{ id: "stub-1", label: "stub row" }];
  },
};
```

`loadCsMetrics` / `ExampleRow` above are illustrative — rename them to this app's actual runnables and return types. If the app has no backend runnables yet, scaffold the stub with an empty object — `export const backend = {};` — and add methods as you wire up `backend/<id>.yaml` files.

**`backend/<runnable>.yaml`** (one per backend script the app calls):

```yaml
type: script
path: <SCOPE>/<existing_script_name>
```

The YAML filename (camelCase) is the key on the `backend` proxy. So `backend/loadCsMetrics.yaml` is invoked from the frontend as `wmill.backend.loadCsMetrics({ ... })` — through the `backend` namespace, with a single args **object**. Not `wmill.loadCsMetrics(...)`, which builds clean but is `undefined` at runtime (esbuild emits an `import-is-undefined` warning that CI treats as fatal). See `claude/rules/raw-app-wmill-virtual.md`.

If the user specified no backend scripts, **do not skip** the `backend/` folder — `wmill app lint` requires at least one runnable. Either:

- Ask the user to name an existing script to wire up, or
- Create a placeholder inline runnable they can edit later. **The source goes under `inlineScript`, not at the top level** — `wmill app lint` accepts the wrong shape silently and only the dev/runtime client rejects it. See `claude/rules/raw-app-inline-runnable-yaml.md`.

  ```yaml
  # backend/placeholder.yaml
  type: inline
  inlineScript:
    language: bun # this repo defaults to Bun (wmill.yaml: defaultTs: bun); use deno/node16/python3/go/bash for others
    content: |
      export async function main() {
        return { ok: true };
      }
  ```

  **The moment the runnable body calls `wmill.*`** (`wmill.getVariable`, `wmill.getResource`, …), add `import * as wmill from "windmill-client";` as the first line of `content` — otherwise it throws `wmill is not defined` at runtime, and lint won't catch it. See `claude/rules/raw-app-windmill-client-import.md`. The empty `{ ok: true }` placeholder above doesn't need it.

## Step 6: Lint and smoke-test

1. `wmill app lint <SCOPE>/<name>.raw_app` — must end with `✅ All checks passed`. Lint runs `npm install`, builds the esbuild bundle, and validates the wmill-virtual interception. Treat any `[WARNING]` as a blocker (CI does too).
2. **For any new inline runnable**, also run `wmill app dev <SCOPE>/<name>.raw_app` and load `http://localhost:5173` in a browser. The lint accepts mis-shaped backend YAML silently; only the dev/runtime client rejects an inline runnable that's missing the `inlineScript:` wrapper (`claude/rules/raw-app-inline-runnable-yaml.md`) or a runnable body that calls `wmill.*` without `import * as wmill from "windmill-client"` (`claude/rules/raw-app-windmill-client-import.md`) — both lint clean and throw on first load.
   - `wmill app dev` needs a configured `local` workspace. If `wmill workspace list` is empty, see `claude/rules/local-windmill-dev.md` before running this step. Scripted setup is `wmill workspace add --create local dev http://localhost:8000/ --token "$TOKEN"` (mint `$TOKEN` via the auth-login + token-create curl pair documented there — the wmill CLI has no `--email --password` bootstrap).
   - If a runnable calls a service on your **host** machine, `wmill app dev` runs it in a container — `127.0.0.1` won't reach the host. Use `http://host.docker.internal:<port>` and bind the host service to `0.0.0.0`. See `claude/rules/raw-app-dev-host-networking.md`.

## Step 7: Report

Tell the user:

```
Created <SCOPE>/<name>.raw_app/ — lint passes.

Local dev:        wmill app dev <SCOPE>/<name>.raw_app
Push by hand:     wmill app push <SCOPE>/<name>.raw_app --workspace thanx \
                    --base-url https://grid-origin.thanx.com --token "$TOKEN"
Auto-deploy:      merge to master — .github/workflows/grid.yml pushes the
                  full f/** inventory via the reusable deploy workflow (this
                  app included). See claude/rules/per-item-push-not-sync.md.
Once live:        https://grid.thanx.com/apps/get/<SCOPE>/<name>
```

Mention if you stubbed a placeholder backend runnable that the user needs to fill in.

## Pitfalls

- **`.raw_app` suffix is required.** Without it the wmill CLI silently doesn't recognise the directory as an app. See `claude/rules/flow-yaml-shape.md` for the broader pattern (suffixes are how `wmill <type> push` infers what kind of item to push).
- **Don't nest under `src/`.** The canonical layout puts `App.tsx`, `index.tsx`, `index.css` at the root of the `.raw_app/` directory. Vite-style nesting under `src/` does not get bundled.
- **`backend/` is required.** At least one runnable. Lint fails otherwise.
- **Don't commit `node_modules/` or `dist/`.** Both are gitignored at the repo root.
- **Don't include `vite.config.ts`, `index.html`, or `tsconfig.json`.** Windmill bundles with esbuild server-side; those Vite files are inert and misleading.
- **App path collisions with scripts.** A script at `f/eng/merchant_health.script.ts` and a raw_app at `f/eng/merchant_health.raw_app/` will both deploy to `f/eng/merchant_health` (typed by kind in Windmill — script ≠ app). Allowed but confusing — prefer a distinct name.
