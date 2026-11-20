namespace FingVibe.Core.Networking;

public enum ServiceStatusCategory
{
    Consumer,
    Infrastructure
}

public enum ServiceStatusSourceKind
{
    /// <summary>An official public feed exists; reports are only available once a source supplies them.</summary>
    OfficialFeed,
    /// <summary>Only an official human-readable page exists; the entry is never monitored.</summary>
    OfficialPageOnly,
    /// <summary>No approved status source exists; the entry is never monitored.</summary>
    NoApprovedSource
}

public sealed record ServiceStatusEntry(
    string Id,
    string Provider,
    string Service,
    ServiceStatusCategory Category,
    ServiceStatusSourceKind SourceKind,
    string SourceName,
    Uri Link,
    string LinkLabel);

/// <summary>The approved six-provider, twelve-entry Service status selection (#354).</summary>
public static class ServiceStatusCatalog
{
    public static IReadOnlyList<ServiceStatusEntry> Entries { get; } =
    [
        new("microsoft-outlook", "Microsoft", "Outlook.com", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.NoApprovedSource, "No agreed public feed", new("https://outlook.live.com/"), "Open service"),
        new("microsoft-azure", "Microsoft", "Azure", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialFeed, "Official RSS", new("https://azure.status.microsoft/en-us/status/"), "Status page"),
        new("google-gmail", "Google", "Gmail", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.OfficialFeed, "Official incident feed", new("https://www.google.com/appsstatus/dashboard/"), "Status page"),
        new("google-cloud", "Google", "Google Cloud", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialFeed, "Official incident feed", new("https://status.cloud.google.com/"), "Status page"),
        new("amazon-shopping", "Amazon", "Amazon.de shopping", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.NoApprovedSource, "Retail source unresolved", new("https://www.amazon.de/"), "Open storefront"),
        new("amazon-aws", "Amazon", "AWS", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialFeed, "Official health feeds", new("https://health.aws.amazon.com/health/status"), "Status page"),
        new("cloudflare-dns", "Cloudflare", "1.1.1.1 public DNS", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.OfficialFeed, "Official status API", new("https://www.cloudflarestatus.com/"), "Status page"),
        new("cloudflare-network", "Cloudflare", "CDN / network", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialFeed, "Official status API", new("https://www.cloudflarestatus.com/"), "Status page"),
        new("apple-icloud", "Apple", "iCloud", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.OfficialPageOnly, "Apple System Status", new("https://www.apple.com/support/systemstatus/"), "Status page"),
        new("apple-developer", "Apple", "Developer services", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialPageOnly, "Apple Developer Status", new("https://developer.apple.com/system-status/"), "Status page"),
        new("github-website", "GitHub", "Website / repositories", ServiceStatusCategory.Consumer,
            ServiceStatusSourceKind.OfficialFeed, "Official status API", new("https://www.githubstatus.com/"), "Status page"),
        new("github-actions", "GitHub", "Actions", ServiceStatusCategory.Infrastructure,
            ServiceStatusSourceKind.OfficialFeed, "Official status API", new("https://www.githubstatus.com/"), "Status page")
    ];
}
