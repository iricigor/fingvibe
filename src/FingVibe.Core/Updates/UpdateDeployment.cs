namespace FingVibe.Core.Updates;

public sealed record UpdateDeployment(bool IsInstalled, string Description)
{
    public static UpdateDeployment Assess(string executableDirectory, string? registeredDirectory,
        string? registeredVersion, Version installedVersion, bool hasInstallerOwnership)
    {
        if (registeredDirectory is null && registeredVersion is null && !hasInstallerOwnership)
            return new(false, "Portable or unregistered copy: download the ZIP, close FingVibe and replace the portable files manually.");
        if (hasInstallerOwnership && !string.IsNullOrWhiteSpace(registeredDirectory)
            && Path.GetFullPath(executableDirectory).TrimEnd(Path.DirectorySeparatorChar)
                .Equals(Path.GetFullPath(registeredDirectory).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)
            && registeredVersion is not null && StableRelease.TryParseVersion(registeredVersion, out var registered)
            && registered == installedVersion)
            return new(true, "Verified per-user installation. Download Setup, then explicitly confirm installation and closing FingVibe.");
        return new(false, "Installation type could not be verified. Use the ZIP/manual replacement path; Setup is not offered.");
    }
}
