using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace DBMonitor.Data;

// `dotnet ef` prefers this factory over running Program.cs's top-level
// statements, which otherwise execute startup code — including
// SeedDefaultConnectionsAsync's live MigrateAsync — against the real,
// external Azure SQL "DBMonitor" database that ConnectionStrings:DefaultConnection
// points to. The connection string here is never opened for
// `migrations add` (model generation doesn't connect), only for
// `database update`.
public class ApplicationDbContextFactory : IDesignTimeDbContextFactory<ApplicationDbContext>
{
    public ApplicationDbContext CreateDbContext(string[] args)
    {
        var optionsBuilder = new DbContextOptionsBuilder<ApplicationDbContext>();
        optionsBuilder.UseSqlServer("Server=localhost;Database=dbmonitor_designtime;Trusted_Connection=True;");
        return new ApplicationDbContext(optionsBuilder.Options);
    }
}
