# Deploy tests must not nest jobs — direct-import `main()` instead

Don't use `wmill.runScript(...)` inside a `// test:` deploy test on Grid. The child job queues for the same `bun` worker the test is holding, and Grid's single-bun-worker docker setup deadlocks on it. Import the target's `main` directly with a relative path; it runs in-process, no child job.

## Why it bit us

Grid's deploy step in `.github/workflows/deploy.yml` runs the per-item push loop (`scripts/deploy-grid-items.sh`) then `scripts/run-deploy-tests.sh`. The test wrappers looked like:

```ts
// test: script/f/shared/load_customer_cube
import * as wmill from "windmill-client";
export async function main() {
  const snap = await wmill.runScript("f/shared/load_customer_cube", null, {});
  // …assertions…
}
```

`wmill.runScript` enqueues a _child job_ and awaits its result. The parent test job still occupies the `bun` worker while awaiting. The local `docker compose up` stack ships one worker for tag `bun`. The child can't be dispatched because the only matching worker is busy. Deadlock — and the same deadlock is what made every deploy fail on grid.thanx.com:

```
▶ f/shared/load_cs_metrics_test
  ❌ HTTP 504 (after 5 minutes)
▶ f/shared/load_customer_cube_test
  ❌ HTTP 504
```

Even `load_cs_metrics_test` (a 3-row hardcoded script) 504'd, because Windmill's `// test:` annotation auto-fires the test on deploy, which pinned the only worker on the slow `load_customer_cube_test`; then CI's explicit POST to `run_wait_result/p/load_cs_metrics_test` queued behind it and hit the proxy's 5-minute idle timeout.

## How to write a test instead

Relative imports between sibling scripts work in Windmill's Bun runtime (despite what `CLAUDE.md`'s "call other scripts via the typed wmill client" line implies). Use them:

```ts
// f/shared/load_customer_cube_overview_test.ts
// test: script/f/shared/load_customer_cube_overview

import { main as overview } from "./load_customer_cube_overview.ts";

export async function main(): Promise<{ ok: true; customer_count: number }> {
  const snap = await overview();
  // …assertions…
  return { ok: true, customer_count: snap.cube.customer_count };
}
```

In-process call, no nested job, no deadlock — and the test is faster to boot because there's only one bundle compile.

The direct import is also why the deploy pushes the imported script before the test: the test's lock build needs `./load_customer_cube_overview.ts` to exist on the workspace (see [`deploy-script-import-order.md`](./deploy-script-import-order.md)).

Don't reach for `deploy.yml`'s `test_retries` input to paper over this. A deadlocked test 504s on every attempt, so retries only multiply the 5-minute wait. `test_retries` is for genuinely transient failures, like a cold worker or an upstream blip, and a test that passes only on a retry is still annotated as flaky.

## How to verify

After pushing a test script (`wmill script push <path>` from your laptop, or via the deploy workflow), hit `run_wait_result/p/<test_path>` and inspect the queue:

```bash
curl -sH "Authorization: Bearer $TOKEN" \
  http://localhost:8000/api/w/dev/jobs/queue/list | jq '.[] | {id, script_path, running}'
```

If the test sits with a child job entry (e.g. `script_path: f/shared/load_customer_cube`) that's `running: false` while the parent is `running: true`, that's the deadlock — switch the test to a direct import.
