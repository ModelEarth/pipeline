namespace DBMonitor.Models.ViewModels;

public record AdminUserVm(
    string Id,
    string Email,
    bool IsAdmin,
    bool HasIndustryDbAccess,
    bool IsSelf);
