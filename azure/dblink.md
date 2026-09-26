
## Azure: enabling a Postgres extension (allow-list setup)

Azure Database for PostgreSQL blocks any extension not on the server's `azure.extensions`
allow-list, even for the `azure_pg_admin` role our app's provisioning account uses — a login can't
grant this to itself. It's an **Azure resource-level setting** (Portal or `az` CLI against the
right subscription), and it's **server-wide, not per-database**: setting it once covers every
database on that server.

Use these steps any time a new extension needs enabling on an Azure Postgres server — this isn't
specific to `dblink`.

1. **Confirm which Azure Postgres offering the server is** — the exact `az` command group differs
   between them:
   ```bash
   az postgres server show --name <server-name> --resource-group <resource-group>
   # If that 404s, it's Flexible Server instead:
   az postgres flexible-server show --name <server-name> --resource-group <resource-group>
   ```
   [`azure/azure.sh`](azure/) (in this repo) calls `az postgres server ...`, pointing at the older
   **Single Server** SKU — confirm directly rather than assume that for a new server.

2. **Add the extension(s) to the server's allow-list** — the command depends on which offering
   step 1 found:
   - **Single Server:**
     ```bash
     az postgres server configuration set \
       --resource-group <resource-group> \
       --server-name <server-name> \
       --name azure.extensions \
       --value dblink,postgres_fdw
     ```
   - **Flexible Server:**
     ```bash
     az postgres flexible-server parameter set \
       --resource-group <resource-group> \
       --server-name <server-name> \
       --name azure.extensions \
       --value dblink,postgres_fdw
     ```
   - **Portal equivalent:** the server's page → **Settings → Server parameters** (Flexible
     Server) or the older **Server parameters** blade (Single Server) → find `azure.extensions` →
     add the extension name(s) to its comma-separated value → **Save**.
   - `--value` replaces the whole list, so include every extension you want enabled, not just the
     new one — check the current value first if the server already allow-lists something else.

3. **Restart may be required.** Some Azure Postgres parameters apply immediately; others need a
   server restart to take effect. If `CREATE EXTENSION` still fails right after saving, restart
   the server and retry.

4. **Verify**, from any raw connection to the server (not through DBMonitor's SQL editor if it
   restricts to `SELECT`-only — check first):
   ```sql
   SHOW azure.extensions;
   ```
   That should confirm the extension(s) you added show up — for `dblink`, confirm both `dblink`
   and ideally `postgres_fdw`. If so, we're done with the one-time Azure part — no further manual
   steps needed; `CREATE EXTENSION IF NOT EXISTS <name>` inside a database is a normal SQL
   statement from here on, no special Azure access required.

## dblink on modelearth-postgres-server: resolved

`team/PLAN-merge.md` merges the per-year Industry Databases (`industrydb_2019`, `industrydb_2021`,
...) into one shared multi-year `industrydb`, entirely inside Azure Postgres via the `dblink`
extension. The allow-list setup above has been completed for `modelearth-postgres-server` —
`SHOW azure.extensions` lists `dblink` (confirmed by Gary running a live `dblink()` query
successfully).

`dblink` only needs to be enabled on the **calling** database — the one running
`SELECT * FROM dblink(...)` — not on every database being reached into. In this pipeline that's
the shared `industrydb`, and it's already automated: `ensure_merge_infra()` in
[`team/src/merge_years.rs`](https://github.com/ModelEarth/team/blob/main/src/merge_years.rs) runs
`CREATE EXTENSION IF NOT EXISTS dblink` against `industrydb` on every call to
`POST /api/db/merge-years/inspect` or `/run`. No manual per-database step is needed — including
for newly created per-year databases, which don't need the extension at all.
