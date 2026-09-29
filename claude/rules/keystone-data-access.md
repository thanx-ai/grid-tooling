# Query Snowflake/replica data through Keystone — don't provision a dedicated DB service account

**Rule.** When a Grid app or scheduled flow needs Thanx data (Snowflake `ANALYTICS.*`, the MySQL/Postgres read replicas, etc.), query it **through Keystone**, not through a per-app Snowflake service account wired up as a `c_snowflake` Windmill resource. Keystone gives you PII sanitization + audit logging for free and means no warehouse credential ever gets minted, stored, or rotated for your app.

This applies in two distinct places, and the mechanism differs between them:

| Context | Who | How |
| --- | --- | --- |
| **Dev-time** — exploring schema, writing/testing the queries | the authoring agent | the **Keystone MCP tools** you already have loaded |
| **Runtime** — the deployed flow/loader running on `grid.thanx.com` | the Windmill job | a **REST call** to Keystone, authed with the shared token (MCP isn't available inside a Windmill job) |

## Dev-time: use the Keystone MCP tools

Everyone's agent has the Keystone MCP server loaded. Before you wire anything into Windmill, develop and validate the queries with it. The **tool names below are stable** across installs (`snowflake_query`, `get_api_documentation`, …); the **server prefix is not** — eng installs Keystone via the `cortex` plugin (tools surface as `mcp__plugin_cortex_keystone__<tool>`), while non-eng folks install it directly, so their tools surface under a different prefix (e.g. `mcp__keystone__<tool>`). Match on the tool name, not the prefix — don't hardcode `mcp__plugin_cortex_keystone__*` into anything, and if you can't see the tools, search your available MCP tools for `snowflake_query` rather than assuming a prefix.

- `snowflake_query` — run SQL against Snowflake (`database`: `RAW` | `ANALYTICS` | `SNOWFLAKE`; `schema`: e.g. `THANX` for `ANALYTICS.THANX.*`). Results come back PII-masked.
- `list_snowflake_databases`, `schema_table_info`, `schema_column_info` — explore what's there before guessing column names.
- `replica_query` / `list_replica_databases` — same idea for the MySQL/Postgres read replicas.
- `get_api_documentation` — returns the full, authoritative Keystone REST + MCP reference. **Call this for the live contract** rather than trusting the snippet below; the API evolves (human docs: <https://keystone.thanx.com/admin/docs>, MCP docs: <https://keystone.thanx.com/admin/docs/mcp/documentation>).

## Runtime: REST call from the Windmill job, authed with the shared token

A deployed Windmill flow/script can't call MCP — MCP is an agent-side transport, and a Windmill job runs as an isolated process with no MCP client runtime, so the `snowflake_query` *tool* simply isn't there at runtime. It calls Keystone's REST API instead, reading the workspace-shared token from the Windmill variable **`f/shared/KEYSTONE_ACCESS_TOKEN`** (already provisioned — you don't mint your own). This is the answer to "what's the contract":

1. **Endpoint:** `POST https://keystone.thanx.com/api/v1/snowflake/query` (replicas: `POST https://keystone.thanx.com/api/v1/replica/query`).
2. **Auth header:** `Authorization: Bearer <token>` — yes, Bearer.
3. **Payload:** raw SQL, same shape as the MCP tool — `{"query": "...", "database": "ANALYTICS", "schema": "THANX"}`.
4. **Response:** `{ "data": {...}, "metadata": {...} }`, PII already sanitized. **`data` is an envelope, not the row array** — it's shaped `{ schema, results, database, row_count, truncated, total_rows }`. **`data.results` is the actual array of rows.** Destructuring `data` and using it directly where a row array is expected silently produces empty/all-null results (a stuck loading spinner, or all-zero metrics) — this has already bitten one project repo in production, caught only by a live smoke test, not by local unit tests.

Crib (TypeScript Windmill script; the thing a scheduled refresh flow runs):

```ts
import * as wmill from "windmill-client";

export async function main(): Promise<void> {
  const token = await wmill.getVariable("f/shared/KEYSTONE_ACCESS_TOKEN");

  const res = await fetch("https://keystone.thanx.com/api/v1/snowflake/query", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query: "SELECT ... FROM analytics.thanx.your_model",
      database: "ANALYTICS",
      schema: "THANX",
    }),
  });
  if (!res.ok) throw new Error(`Keystone ${res.status}: ${await res.text()}`);
  const { data } = await res.json();
  const rows = data?.results ?? []; // `data` is an envelope; `.results` is the row array — see note above

  // Cache for the app's loaders to read at runtime:
  await wmill.setVariable("f/<scope>/your_dashboard_data", JSON.stringify(rows));
}
```

(Python: `wmill.get_variable(...)` / `wmill.set_variable(...)`, same endpoint and payload.)

The typical dashboard shape is exactly this: an hourly scheduled flow runs the queries through Keystone and writes results into Windmill Variables; the app's loader scripts read those Variables at runtime. The flow needs read access to `f/shared/` (where the token lives) — if `wmill.getVariable` can't resolve the token, that's the missing grant, ask in `#ai-help-desk`.

## Why this matters

This came out of a real request (a project repo's product-adoption dashboard migration, Phase 2, mid-2026): the plan was to ask data-eng to provision a read-only Snowflake service account and configure it as a `c_snowflake` resource at `f/<scope>/snowflake_dashboard_reader`, holding account/warehouse/role/username/password. The better answer is Keystone:

- **No credential lifecycle.** No service account to provision, no password sitting in a Windmill resource, nothing to rotate. The only secret is the shared `KEYSTONE_ACCESS_TOKEN`, managed centrally.
- **PII masking is automatic and non-optional.** Keystone sanitizes results before returning them. This is the same reason raw customer PII is intentionally *not* reachable through agentic systems at Thanx — Keystone is the sanctioned, audited path. If a dashboard genuinely needs unmasked PII (rare), that is a different, non-Grid conversation — don't try to route it through a Grid app.
- **Every query is audit-logged.** Centralized, not per-app.

## How to verify

- Dev-time: you ran the query via `snowflake_query` (or `replica_query`) and got masked rows back before writing any loader.
- Runtime: the deployed script reads `f/shared/KEYSTONE_ACCESS_TOKEN` via `wmill.getVariable` and hits `https://keystone.thanx.com/api/v1/...` — there is **no** `c_snowflake` (or other DB) resource in the repo for this data, and no warehouse username/password anywhere.
- For the exact, current request/response contract, you called `get_api_documentation` rather than relying on this file.

## Related

- [`sql-as-script.md`](./sql-as-script.md) — the `Resource<"snowflake">` / workspace-DB-resource pattern. Reach for that only when Keystone can't serve the source (a warehouse Keystone doesn't proxy, or you need writes); for read-only Snowflake/replica analytics, prefer the Keystone path above.
- [`local-windmill-dev.md`](./local-windmill-dev.md) — a local Windmill workspace has no `f/shared/KEYSTONE_ACCESS_TOKEN` (that's provisioned in the prod workspace only). To exercise the runtime path above locally, mint a personal Keystone token and set it as a variable at the same path in your local workspace.
