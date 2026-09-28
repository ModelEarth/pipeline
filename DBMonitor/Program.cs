using DBMonitor.Data;
using DBMonitor.Models;
using DBMonitor.Services;
using DBMonitor.Services.Import;
using DBMonitor.Services.Query;
using DBMonitor.Services.Schema;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

// Bootstrap configuration used to obtain the GitHub configuration token
// from environment variables, Azure App Settings, or User Secrets.
var bootstrap = new ConfigurationBuilder()
    .AddEnvironmentVariables()
    .AddUserSecrets<Program>(optional: true)
    .Build();

var githubToken = bootstrap["GITHUB_CONFIG_TOKEN"];

if (!string.IsNullOrWhiteSpace(githubToken))
{
    using var http = new HttpClient();

    http.DefaultRequestHeaders.UserAgent.ParseAdd("DBMonitor/1.0");
    http.DefaultRequestHeaders.Authorization =
        new System.Net.Http.Headers.AuthenticationHeaderValue(
            "Bearer",
            githubToken);

    var envContent = await http.GetStringAsync(
        "https://raw.githubusercontent.com/garmartirosy/netdev/main/.env");

    DotNetEnv.Env.LoadContents(envContent);
}
else if (!TryLoadLocalCloudRepoSecrets())
{
    DotNetEnv.Env.TraversePath().Load();
}

// No GITHUB_CONFIG_TOKEN set: this is a local run. Looks for a repo folder
// near this checkout whose name starts with "cloud" and that has an
// automation/paths.yaml file — the same file that repo's own
// automation/sync-config.sh reads to find its env file — and, if found,
// loads whatever env file it points to. Never logs the resolved path or
// its contents. Silently does nothing if no such repo/file is present
// (e.g. in Docker or CI), so DotNetEnv.Env.TraversePath().Load() still
// runs as the fallback in that case.
static bool TryLoadLocalCloudRepoSecrets()
{
    var dir = new DirectoryInfo(Directory.GetCurrentDirectory());

    for (var depth = 0; depth < 4 && dir?.Parent is not null; depth++)
    {
        var parent = dir.Parent;

        IEnumerable<DirectoryInfo> siblings;
        try
        {
            siblings = parent.GetDirectories();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            break;
        }

        foreach (var sibling in siblings)
        {
            if (sibling.FullName == dir.FullName) continue;
            if (!sibling.Name.StartsWith("cloud", StringComparison.OrdinalIgnoreCase)) continue;

            var pathsYaml = Path.Combine(sibling.FullName, "automation", "paths.yaml");
            if (!File.Exists(pathsYaml)) continue;

            var envFile = ResolveEnvFileFromPathsYaml(pathsYaml);
            if (envFile is not null && File.Exists(envFile))
            {
                DotNetEnv.Env.Load(envFile);
                return true;
            }
        }

        dir = parent;
    }

    return false;
}

static string? ResolveEnvFileFromPathsYaml(string pathsYamlPath)
{
    var envFileLine = File.ReadLines(pathsYamlPath)
        .Select(line => line.Trim())
        .Where(line => line.StartsWith("env_file:", StringComparison.OrdinalIgnoreCase))
        .LastOrDefault();

    if (envFileLine is null) return null;

    var value = envFileLine["env_file:".Length..].Trim().Trim('"');
    if (value.Length == 0) return null;

    return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(pathsYamlPath)!, value));
}

// Builds the connection string for the EXIOBASE industry database, an
// Azure Postgres server/account separate from the app's own SQL Server
// store.
static string BuildExiobaseConnectionString(IConfiguration configuration) =>
    $"Host={configuration["EXIOBASE_HOST"]};" +
    $"Database={configuration["EXIOBASE_NAME"]};" +
    $"Username={configuration["EXIOBASE_USER"]};" +
    $"Password={configuration["EXIOBASE_PASSWORD"]};" +
    $"Port={configuration["EXIOBASE_PORT"] ?? "5432"};" +
    $"SSL Mode={configuration["EXIOBASE_SSL_MODE"] ?? "Require"};" +
    "Trust Server Certificate=true";

// Builds the connection string for the app's own Azure SQL "DBMonitor"
// store from DBMONITOR_HOST/USER/PASSWORD, so individual developers don't
// need a full ConnectionStrings:DefaultConnection entry — just those three
// values from whoever manages the Azure SQL server.
static string BuildDbMonitorConnectionString(IConfiguration configuration)
{
    var host = configuration["DBMONITOR_HOST"];
    if (string.IsNullOrWhiteSpace(host))
    {
        throw new InvalidOperationException(
            "Connection string 'DefaultConnection' was not found.");
    }

    return
        $"Server={host},{configuration["DBMONITOR_PORT"] ?? "1433"};" +
        $"Database={configuration["DBMONITOR_NAME"] ?? "DBMonitor"};" +
        $"User Id={configuration["DBMONITOR_USER"]};" +
        $"Password={configuration["DBMONITOR_PASSWORD"]};" +
        "Encrypt=True;" +
        "TrustServerCertificate=False;";
}

var builder = WebApplication.CreateBuilder(args);

// ── Data ──────────────────────────────────────────────────────────────────────

var connectionString =
    builder.Configuration.GetConnectionString("DefaultConnection") is
        { Length: > 0 } explicitConnectionString
        ? explicitConnectionString
        : BuildDbMonitorConnectionString(builder.Configuration);

builder.Services.AddDbContext<ApplicationDbContext>(options =>
    options.UseSqlServer(connectionString));

builder.Services.AddDatabaseDeveloperPageExceptionFilter();

// ── Identity and Google authentication ────────────────────────────────────────

builder.Services
    .AddDefaultIdentity<IdentityUser>(options =>
    {
        // Local users can currently sign in without confirming their email.
        options.SignIn.RequireConfirmedAccount = false;
    })
    .AddEntityFrameworkStores<ApplicationDbContext>();

builder.Services
    .AddAuthentication()
    .AddGoogle(options =>
    {
        options.ClientId =
            builder.Configuration["Authentication:Google:ClientId"]
            ?? builder.Configuration["GOOGLE_CLIENT_ID"]
            ?? throw new InvalidOperationException(
                "Google Client ID is missing.");

        options.ClientSecret =
            builder.Configuration["Authentication:Google:ClientSecret"]
            ?? builder.Configuration["GOOGLE_CLIENT_SECRET"]
            ?? throw new InvalidOperationException(
                "Google Client Secret is missing.");
    });

// ── MVC, Razor Pages and HTTP services ────────────────────────────────────────

builder.Services.AddControllersWithViews();
builder.Services.AddRazorPages();
builder.Services.AddHttpClient();

// ── Data Protection ───────────────────────────────────────────────────────────

// TODO:
// Production deployments need persistent key storage such as Azure Key Vault,
// Redis, or an Azure file share. Otherwise, regenerated keys could make saved
// encrypted connection profiles unreadable after a container restart.
builder.Services.AddDataProtection();

// ── Domain services ───────────────────────────────────────────────────────────

builder.Services.AddScoped<
    IConnectionStringProtector,
    DataProtectionConnectionStringProtector>();

builder.Services.AddScoped<
    IDbProviderFactory,
    DbProviderFactoryResolver>();

builder.Services.AddScoped<
    IConnectionTester,
    ConnectionTester>();

builder.Services.AddSingleton<SchemaReaderFactory>();
builder.Services.AddSingleton<TableDataReaderFactory>();
builder.Services.AddSingleton<ProcedureExecutorFactory>();

builder.Services.AddSingleton<
    IBulkImporterFactory,
    BulkImporterFactory>();

builder.Services.AddSingleton<
    ICsvInspector,
    CsvInspector>();

builder.Services.AddSingleton<CsvSchemaInferrer>();

builder.Services.AddScoped<
    IQueryExecutor,
    QueryExecutor>();

builder.Services.AddHostedService<ImportSessionCleanupService>();

// ── Health checks ─────────────────────────────────────────────────────────────

builder.Services
    .AddHealthChecks()
    .AddDbContextCheck<ApplicationDbContext>();

// ── Upload limits ─────────────────────────────────────────────────────────────

builder.Services.Configure<
    Microsoft.AspNetCore.Http.Features.FormOptions>(options =>
{
    options.MultipartBodyLengthLimit = 100_000_000;
});

builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = 100_000_000;
});

// All services must be registered before this line.
var app = builder.Build();

// ── Seed default connections ──────────────────────────────────────────────────

await SeedDefaultConnectionsAsync(app);

// ── HTTP request pipeline ─────────────────────────────────────────────────────

if (app.Environment.IsDevelopment())
{
    app.UseMigrationsEndPoint();
}
else
{
    app.UseExceptionHandler("/Error/500");
    app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/Error/{0}");

app.UseHttpsRedirection();
app.UseStaticFiles();

app.UseRouting();

// Authentication must come before authorization.
app.UseAuthentication();
app.UseAuthorization();

// ── Routes ────────────────────────────────────────────────────────────────────

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.MapRazorPages();

// ── Operational endpoints ─────────────────────────────────────────────────────

app.MapHealthChecks("/health")
    .AllowAnonymous();

app.MapGet("/version", () =>
{
    return Results.Ok(new
    {
        version =
            typeof(Program).Assembly.GetName().Version?.ToString()
            ?? "0.0.0",

        utc = DateTime.UtcNow
    });
})
.AllowAnonymous();

app.Run();

// ── Default connection seeder ─────────────────────────────────────────────────

static async Task SeedDefaultConnectionsAsync(WebApplication app)
{
    var defaults = new[]
    {
        new
        {
            Id = new Guid(
                "00000000-0000-0000-0000-000000000001"),

            Name = "IndustryDB (Azure PostgreSQL)",

            Provider = DbProviderKind.PostgreSql,

            PlaintextConnStr = BuildExiobaseConnectionString(app.Configuration)
        }
    };

    await using var scope = app.Services.CreateAsyncScope();

    var db =
        scope.ServiceProvider
            .GetRequiredService<ApplicationDbContext>();

    var protector =
        scope.ServiceProvider
            .GetRequiredService<IConnectionStringProtector>();

    await db.Database.MigrateAsync();

    foreach (var definition in defaults)
    {
        var existing =
            await db.ConnectionProfiles.FindAsync(definition.Id);

        var encryptedConnectionString =
            protector.Protect(definition.PlaintextConnStr);

        if (existing is null)
        {
            db.ConnectionProfiles.Add(
                new DbConnectionProfile
                {
                    Id = definition.Id,
                    Name = definition.Name,
                    Provider = definition.Provider,

                    EncryptedConnectionString =
                        encryptedConnectionString,

                    OwnerId = "system",
                    IsShared = true,
                    CreatedUtc = DateTime.UtcNow
                });
        }
        else
        {
            existing.EncryptedConnectionString =
                encryptedConnectionString;

            existing.Name = definition.Name;
        }
    }

    await db.SaveChangesAsync();
}