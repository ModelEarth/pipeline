## Claude Session Sandbox

At the start of every session in this repo, set up a Python sandbox for Claude's own use (not for the websites below) using the steps in https://raw.githubusercontent.com/ModelEarth/cloudroot/refs/heads/main/PYTHON.md

## Start Websites

Invoke local websites on these ports using these commands. 
These run directly with system python3/node and do not use or require the Claude session sandbox above.
Open a Brave browser tab for each, and use a target called "target-[port]" to reuse existing tabs.

###  Start CloudRoot 3700

In the ../CloudRoot folder, run:

PORT=3700 node chat/server.mjs


###  Start Azure - Pipeline DBMonitor .NET Tradeflow 5156 for http and 7284

In the ../pipeline folder, run:

dotnet run --project DBMonitor/DBMonitor.csproj --launch-profile https

This .NET 10 app serves http on 5156 and https on 7284, as set in DBMonitor/Properties/launchSettings.json. Without `--launch-profile https`, `dotnet run` uses the http profile and serves only 5156. More details in the sections below.



## Commands

```bash
# Build
dotnet build

# Run (HTTP on :5156, HTTPS on :7284 — see DBMonitor/Properties/launchSettings.json)
dotnet run --project DBMonitor/DBMonitor.csproj

# Run with Docker (see caveat under "Known drift" below)
docker build -t dbmonitor .
docker run -p 8080:8080 -p 8081:8081 dbmonitor

# EF Core migrations
dotnet ef migrations add <MigrationName> --project DBMonitor
dotnet ef database update --project DBMonitor
```

No test project exists.

## Architecture

**ASP.NET Core MVC on .NET 10** — a multi-provider database web console: connection profile manager, schema browser, ad-hoc SQL editor, stored-procedure runner, CSV/TSV bulk importer, saved-query library, query audit log, and a GitHub-hosted script runner ("Pipelines"). Users can register personal DB connections (SQL Server or PostgreSQL) or use profiles marked shared.

**App's own store:** SQL Server via EF Core (`ApplicationDbContext` extends `IdentityDbContext`; design-time migrations use `ApplicationDbContextFactory` so `dotnet ef` never runs the app's real startup code against the live database).
**Target databases** users connect to: SQL Server (`Microsoft.Data.SqlClient`) or PostgreSQL (`Npgsql`), abstracted behind provider factories.

### Request paths
- MVC: `Controllers/` → Razor Views in `Views/` (all controllers `[Authorize]` except error pages)
- Identity: `Areas/Identity/Pages/` (default scaffold; Google OAuth wired in `Program.cs`)
- Health/ops: `/health` (DbContext check), `/version` (assembly version + UTC), both `AllowAnonymous`

### Key entities (`Models/`)
- `DbConnectionProfile` — encrypted conn string, owner, `IsShared`, pin/sort, last-used
- `QueryAuditEntry` — SQL command (≤8KB), elapsed, rows affected, success/error (≤2KB)
- `ImportSession` — temp CSV upload metadata, 1-hour expiry
- `SavedQuery` — up to 50K chars, per profile
- `UserPreferences` — theme
- `DbProviderKind` — enum: `SqlServer`, `PostgreSql`

### Services (`Services/`, organized by concern)
- **Root:** `IConnectionStringProtector` (Data Protection API), `IConnectionTester`, `IDbProviderFactory`
- **`Schema/`:** `ISchemaReader` + SQL Server / PostgreSQL implementations behind `SchemaReaderFactory`
- **`Query/`:** `IQueryExecutor`, `ITableDataReader`, `IProcedureExecutor` (per-provider variants + factories); filter builder types (`TableQuery`, `ColumnFilter`, `FilterOp`)
- **`Import/`:** `ICsvInspector` (delimiter/encoding/header detection), `CsvSchemaInferrer` (types → CREATE TABLE), `IBulkImporter` per provider behind `IBulkImporterFactory`
- **Hosted:** `ImportSessionCleanupService` — purges expired upload temp files

### Frontend
Bootstrap 5 + jQuery from `wwwroot/lib/`. Custom JS in `wwwroot/js/` (schema browser, SQL editor, import wizard, procedure runner, result grid, table data, connections). Theme (light/dark) in `wwwroot/css/theme.css`. Layout: `Views/Shared/_Layout.cshtml`.

## Configuration

Configuration resolves in this order at startup (see `Program.cs`):

1. **Bootstrap phase:** environment variables + user secrets are read to find `GITHUB_CONFIG_TOKEN`.
2. If the token is set, the app fetches `.env` from `raw.githubusercontent.com/garmartirosy/netdev/main/.env` and loads it into the environment via `DotNetEnv`.
3. If not set, the app looks for a repo folder near this checkout whose name starts with `cloud` and that has an `automation/paths.yaml` file; if found, it loads whatever env file that file points to. This is local-only — it does nothing (and logs nothing about it) when no such repo is present, e.g. in Docker or CI.
4. If that also finds nothing, `DotNetEnv.Env.TraversePath().Load()` loads a local `.env`.
5. Standard `WebApplication.CreateBuilder(args)` then reads `appsettings.json`, environment, and user secrets normally.

**Required keys** (env, secrets, or `.env`):
- `ConnectionStrings:DefaultConnection` — SQL Server (Azure SQL) for the app's own store (Identity + profiles + audit), a database named `DBMonitor`. `appsettings.json` ships with an empty string; if unset, it's built from `DBMONITOR_HOST`, `DBMONITOR_USER`, `DBMONITOR_PASSWORD` (`DBMONITOR_PORT` default 1433, `DBMONITOR_NAME` default `DBMonitor`) — startup throws if `DBMONITOR_HOST` is also unset.
- `Authentication:Google:ClientId` / `ClientSecret` — startup throws without these. Falls back to flat `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` if the hierarchical keys aren't set.
- `EXIOBASE_HOST`, `EXIOBASE_NAME`, `EXIOBASE_USER`, `EXIOBASE_PASSWORD`, `EXIOBASE_PORT` (default 5432), `EXIOBASE_SSL_MODE` (default `Require`) — a separate Azure Postgres server/account. Used by `SeedDefaultConnectionsAsync` to seed the "IndustryDB (Azure PostgreSQL)" shared profile (fixed GUID `0000...0001`). Seeder runs `db.Database.MigrateAsync()` on every startup and upserts the profile.

**Other:** User Secrets ID `aspnet-DBMonitor-6ee26c51-a0a3-4b84-a74c-9cac22db2c6e`. Uploads capped at 100 MB (Kestrel + `FormOptions`). Identity is configured with `RequireConfirmedAccount = false`.

## Known drift and caveats

- **Dockerfile targets .NET 8**, but the csproj is `net10.0`. `docker build` will succeed, but the runtime image will fail to load the assembly. Bump `mcr.microsoft.com/dotnet/{aspnet,sdk}:8.0` → `:10.0` before shipping a container.
- **Data Protection keys are not persisted** (`AddDataProtection()` with no key ring provider — TODO in `Program.cs`). After any container/process restart, previously encrypted `DbConnectionProfile.EncryptedConnectionString` values become unreadable. Fix before deploying to any environment where the process isn't pinned to a host with a stable key ring path.
- **`RequireConfirmedAccount = false`** — anyone who registers can sign in immediately. Fine for local dev; reconsider before public exposure.
- **GitHub-hosted `.env`** — the bootstrap fetch is convenient but the token grants read access to production-shaped secrets; treat `GITHUB_CONFIG_TOKEN` as a top-tier secret.

## Conventions

- All new controllers should be `[Authorize]` by default; explicitly `AllowAnonymous` only for health/error pages.
- New DB-facing features must go through the provider factory pattern (`Schema/`, `Query/`, `Import/`) — don't hardcode `SqlConnection` or `NpgsqlConnection` in controllers.
- Anything storing a connection string must round-trip through `IConnectionStringProtector`.
- Anything executing user SQL should log through the `QueryAuditEntry` path (see `SqlController` and `QueryExecutor` for the pattern) — parameter values in procedure calls are redacted deliberately.

## Commit Message Requirements:
- **No Agent (Claude) attribution**: Never include Claude Code credits or co-authored-by lines for any agent
- **Repository-specific**: Each commit message describes only that repository's changes
- **No cross-references**: Don't mention other repositories' changes in individual commits
- **Concise and factual**: Focus on what was changed, not implementation details