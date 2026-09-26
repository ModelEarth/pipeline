# Pipeline

## Getting Started

Setting up or managing Azure resources (SQL/PostgreSQL databases, schema deployment)? Start at
**[pipeline/azure](azure/)** for the automation script and its config.

.NET 10 database console (`DBMonitor/`) — see [CLAUDE.md](CLAUDE.md) for architecture and setup.
Used, among other things, to browse and query the Exiobase Industry Database instances described
in [exiobase/tradeflow](https://github.com/ModelEarth/exiobase/tree/main/tradeflow) and
[team/PLAN-merge.md](https://github.com/ModelEarth/team/blob/main/PLAN-merge.md).

**[View Schema](https://model.earth/exiobase/tradeflow/)** — live schema/row-count diagram for the
Industry Database, per year.

## Azure: activating `dblink` for the multi-year Industry Database merge

`team/PLAN-merge.md` plans to merge the per-year Industry Databases (`industrydb_2019`,
`industrydb_2021`, ...) into one shared multi-year `industrydb`, entirely inside Azure Postgres via
the `dblink` extension. As of 2026-09-20, this is blocked: `CREATE EXTENSION dblink` (and
`postgres_fdw`) both fail with

```
extension "dblink" is not allow-listed for "azure_pg_admin" users in Azure Database for PostgreSQL
```

`azure_pg_admin` (the role the app's provisioning account has) isn't sufficient on Azure —
extensions also need to be on the server's `azure.extensions` allow-list, which is an **Azure
resource-level setting** (Portal or `az` CLI against the right subscription), not something any
Postgres login can grant itself. `SHOW azure.extensions` on this server currently returns empty.

Whoever has Azure access for `modelearth-postgres-server` needs to:

1. **Confirm which Azure Postgres offering this server is** — the exact `az` command group
   differs between them. [`azure/azure.sh`](azure/) (in this repo) calls
   `az postgres server ...` (not `az postgres flexible-server ...`), which points at the older
   **Single Server** SKU, but confirm directly rather than trust that:
   ```bash
   az postgres server show --name modelearth-postgres-server --resource-group <resource-group>
   # If that 404s, it's Flexible Server instead:
   az postgres flexible-server show --name modelearth-postgres-server --resource-group <resource-group>
   ```
2. **Add `dblink` to the server's extension allow-list** (`postgres_fdw` too, while at it, in case
   a future pass prefers it) — the command depends on which of the two above worked:
   - **Single Server:**
     ```bash
     az postgres server configuration set \
       --resource-group <resource-group> \
       --server-name modelearth-postgres-server \
       --name azure.extensions \
       --value dblink,postgres_fdw
     ```
   - **Flexible Server:**
     ```bash
     az postgres flexible-server parameter set \
       --resource-group <resource-group> \
       --server-name modelearth-postgres-server \
       --name azure.extensions \
       --value dblink,postgres_fdw
     ```
   - **Portal equivalent:** the server's page → **Settings → Server parameters** (Flexible
     Server) or **Server parameters** under Single Server's older blade → find `azure.extensions`
     → add `dblink` (and `postgres_fdw`) to its value → **Save**.
   - This is a server-wide allow-list, not per-database — setting it once covers `industrydb` and
     every `industrydb_{year}` database on this same server.
3. **Restart may be required.** Some Azure Postgres parameters apply immediately; others need a
   server restart to take effect. If `CREATE EXTENSION dblink` (step 4) still fails right after
   saving, restart the server and retry.
4. **Verify**, from any raw connection to the server (not through DBMonitor's SQL editor if it
   restricts to `SELECT`-only — check first):
   ```sql
   SHOW azure.extensions;              -- should now list dblink (and postgres_fdw)
   ```
   Then hit `POST /api/db/merge-years/inspect` (in `team/src/merge_years.rs`) with
   `{"year":"2019"}` — its `ensure_merge_infra` step already retries
   `CREATE EXTENSION IF NOT EXISTS dblink` on every call, so it succeeds on its own the next time
   either merge-years endpoint is called; no separate manual `CREATE EXTENSION` step or app
   redeploy needed.
