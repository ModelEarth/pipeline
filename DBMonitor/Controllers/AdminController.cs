using DBMonitor.Models;
using DBMonitor.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;

namespace DBMonitor.Controllers;

[Authorize(Roles = Roles.Admin)]
public class AdminController : Controller
{
    private readonly UserManager<IdentityUser> _userManager;

    public AdminController(UserManager<IdentityUser> userManager) => _userManager = userManager;

    // ── Users list ────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Users()
    {
        var currentUserId = _userManager.GetUserId(User)!;

        // Load users then enrich with role membership. For small user counts
        // (dozens) the per-user role query is fine; swap to a single join if
        // this grows past a few hundred users.
        var users = _userManager.Users.OrderBy(u => u.Email).ToList();
        var rows  = new List<AdminUserVm>(users.Count);
        foreach (var u in users)
        {
            rows.Add(new AdminUserVm(
                Id:                  u.Id,
                Email:               u.Email ?? "(no email)",
                IsAdmin:             await _userManager.IsInRoleAsync(u, Roles.Admin),
                HasIndustryDbAccess: await _userManager.IsInRoleAsync(u, Roles.IndustryDbAccess),
                IsSelf:              u.Id == currentUserId));
        }

        return View(rows);
    }

    // ── Toggle IndustryDbAccess ───────────────────────────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleIndustryAccess(string id)
    {
        var user = await _userManager.FindByIdAsync(id);
        if (user is null) return NotFound();

        if (await _userManager.IsInRoleAsync(user, Roles.IndustryDbAccess))
            await _userManager.RemoveFromRoleAsync(user, Roles.IndustryDbAccess);
        else
            await _userManager.AddToRoleAsync(user, Roles.IndustryDbAccess);

        return RedirectToAction(nameof(Users));
    }

    // Promoting/demoting admins is intentionally not exposed in the UI —
    // admins are seeded exclusively from the ADMIN_EMAILS env var at startup
    // (see SeedRolesAndAdminsAsync in Program.cs). This keeps privilege
    // escalation out of the running app surface.
}
