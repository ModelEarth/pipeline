using System.Security.Claims;
using DBMonitor.Models;

namespace DBMonitor.Data;

public static class ProfileQueryExtensions
{
    public static bool CanSeeSharedConnections(this ClaimsPrincipal user) =>
        user.IsInRole(Roles.Admin) || user.IsInRole(Roles.IndustryDbAccess);

    public static bool CanModifySharedConnections(this ClaimsPrincipal user) =>
        user.IsInRole(Roles.Admin);

    // Owned by the user, OR shared and the user has IndustryDbAccess / Admin.
    public static IQueryable<DbConnectionProfile> VisibleTo(
        this IQueryable<DbConnectionProfile> source, string userId, ClaimsPrincipal user)
    {
        var canSeeShared = user.CanSeeSharedConnections();
        return source.Where(p => p.OwnerId == userId || (p.IsShared && canSeeShared));
    }

    // Owned by the user, OR shared and the user is Admin. Used for Edit/Delete.
    public static IQueryable<DbConnectionProfile> ModifiableBy(
        this IQueryable<DbConnectionProfile> source, string userId, ClaimsPrincipal user)
    {
        var canModifyShared = user.CanModifySharedConnections();
        return source.Where(p => p.OwnerId == userId || (p.IsShared && canModifyShared));
    }
}
