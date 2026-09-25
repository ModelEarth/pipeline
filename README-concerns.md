# Open concerns — local secrets / Azure config work

Notes from wiring up local secret loading and the `EXIOBASE_*` / `DBMONITOR_*`
config changes in `Program.cs`. Flagging these rather than assuming they're
fine.

## Needs Gary's input before/around the next deploy

**Possible naming mismatch in production.** The IndustryDB seeder was
changed from reading `POSTGRES_HOST/DB/USER/PASSWORD/PORT` to
`EXIOBASE_HOST/NAME/USER/PASSWORD/PORT/SSL_MODE`, with no fallback to the
old names. This matches the shared local secrets file, but I can't see
Azure App Service's actual "Application settings" (or the private `netdev`
repo's `.env`, fetched via `GITHUB_CONFIG_TOKEN`) from this repo. If
production still uses the old `POSTGRES_*` names, this won't crash on
deploy — it'll silently seed the "IndustryDB" shared connection profile
with a blank connection string instead. **Needs confirmation**: does
production already use `EXIOBASE_*` naming, or still `POSTGRES_*`? If the
latter, either rename the Azure settings or tell me and I'll add a
fallback in code.

**Missing DBMonitor SQL Server credentials.** `DBMONITOR_HOST`,
`DBMONITOR_USER`, `DBMONITOR_PASSWORD` are blank placeholders in the local
secrets file and in `pipeline/.env.example` — Gary still needs to send the
real values (Azure SQL server hostname, login, password) for the existing
`DBMonitor` database before local runs can fully start. `DBMONITOR_PORT`
(1433) and `DBMONITOR_NAME` (`DBMonitor`) are already filled in as
defaults, not secrets.

## Housekeeping / already handled, noting for the record

- **Provider mix-up, fully reverted:** I initially assumed the app's own
  `DBMonitor` store lived on the same Azure Postgres server as EXIOBASE and
  switched `ApplicationDbContext` to `UseNpgsql`, deleting the original SQL
  Server EF Core migrations. Once corrected (DBMonitor is Azure **SQL
  Server**, a separate resource), this was fully reverted — `git diff` on
  `DBMonitor.csproj` and `Data/Migrations/` shows no difference from the
  pre-change state.
- **Google OAuth validation is lazy.** `options.ClientId`/`ClientSecret`
  in the `AddGoogle(...)` configure delegate only actually run the first
  time someone attempts Google sign-in, not at app startup — a missing
  value won't surface as a startup crash, it'll surface as a runtime error
  on first login attempt.
- **Local secrets loader is best-effort and silent.** If no sibling
  `cloud*`-named repo folder with `automation/paths.yaml` is found near the
  checkout, `TryLoadLocalCloudRepoSecrets()` in `Program.cs` does nothing
  and logs nothing about it, falling through to the existing
  `DotNetEnv.Env.TraversePath().Load()`. Fine by design for CI/Docker/other
  machines, but means a developer without that adjacent folder needs their
  own local `.env` (see `pipeline/.env.example`) or explicit config.
- **Pre-existing, not introduced by this work:** Data Protection keys
  aren't persisted (`AddDataProtection()` with no key ring provider,
  documented in `pipeline/CLAUDE.md`'s "Known drift" section) — every
  container/process restart makes previously encrypted
  `DbConnectionProfile.EncryptedConnectionString` values unreadable,
  including the `DBMonitor`/`IndustryDB` profile rows this seeder writes.
