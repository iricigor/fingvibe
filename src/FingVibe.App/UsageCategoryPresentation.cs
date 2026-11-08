using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class UsageCategoryPresentation
{
    internal const string SamplingNotice =
        "Usage estimates depend on when scans run; they are not confirmed ownership or visitor facts.";

    internal static string Counts(UsageResponseCounts counts) => counts.Percentage is { } percentage
        ? $"{counts.Responded:N0} of {counts.Eligible:N0} eligible scans responded ({percentage:0}%)."
        : "No eligible scans; response rate unavailable.";

    internal static string Reason(DeviceUsageInference inference) => inference.Category switch
    {
        DeviceUsageCategory.Permanent => "At least 80% of eligible scans responded.",
        DeviceUsageCategory.Guest => "At most 10% of eligible scans responded.",
        DeviceUsageCategory.Personal => "Overnight/weekend response rate is at least 60% and at least 20 percentage points above weekday daytime.",
        _ when inference.Total.Eligible == 0 => "No completed eligible evidence for this device on the selected network.",
        _ when inference.OvernightWeekend.Eligible == 0 || inference.WeekdayDaytime.Eligible == 0
            => "No overall rule matched; the Personal comparison needs evidence in both periods.",
        _ => "The available evidence does not match a usage-category rule."
    };

    internal static string Evidence(DeviceUsageInference inference) =>
        $"Automatic recommendation: {inference.Category}. {Reason(inference)}\n{Counts(inference.Total)}\n"
        + $"Overnight/weekend: {Counts(inference.OvernightWeekend)}\nWeekday daytime: {Counts(inference.WeekdayDaytime)}";

    internal static string Window(DeviceUsageInference inference) =>
        $"{inference.FirstDate:d} - {inference.LastDate:d} | {inference.ObservedDates} observed dates | {inference.TimeZoneId}\n"
        + $"Network: {inference.NetworkId} | {inference.Subnet}. Today is partial; only evidence collected so far is used.";

    internal static string Description(DeviceUsageCategory? manual, DeviceUsageInference? inference, string status) =>
        (manual is { } category ? $"{category} - Manual override. " : inference is { } result ? $"{result.Category} - Automatic. " : string.Empty)
        + (inference is null ? status : $"{Evidence(inference)}\n{Window(inference)}"
            + (inference.LimitedEvidence ? "\nLimited evidence - provisional estimate." : string.Empty))
        + $"\n{SamplingNotice}";
}

internal sealed class UsageCategoryEditState
{
    internal Guid Token { get; private set; }
    internal LogicalDeviceId? Identity { get; private set; }
    internal DeviceUsageCategory? Saved { get; private set; }
    internal DeviceUsageCategory? Draft { get; private set; }
    internal bool IsSaving { get; private set; }
    internal bool IsReloading { get; private set; }
    internal bool IsBusy => IsSaving || IsReloading;
    internal bool NeedsReload { get; private set; }
    internal string? Error { get; private set; }
    internal bool HasChanges => Draft != Saved;

    internal void Load(LogicalDeviceId? identity, DeviceUsageCategory? saved)
    {
        Token = Guid.NewGuid();
        Identity = identity;
        Saved = Draft = saved;
        IsSaving = IsReloading = NeedsReload = false;
        Error = null;
    }

    internal void Choose(DeviceUsageCategory? choice)
    {
        if (IsBusy || NeedsReload) throw new InvalidOperationException("Finish or reload the current category edit first.");
        if (choice is { } value && !Enum.IsDefined(value)) throw new ArgumentOutOfRangeException(nameof(choice));
        Draft = choice;
        Error = null;
    }

    internal void BeginSave()
    {
        if (Identity is null || IsBusy || NeedsReload || !HasChanges)
            throw new InvalidOperationException("There is no category edit ready to save.");
        IsSaving = true;
    }

    internal void BeginReload()
    {
        if (Identity is null || IsBusy || !NeedsReload)
            throw new InvalidOperationException("There is no category conflict ready to reload.");
        IsReloading = true;
    }

    internal void Failed(string message, bool conflict)
    {
        IsSaving = IsReloading = false;
        Error = message;
        NeedsReload = conflict;
    }

    internal void Cancel()
    {
        if (IsBusy) throw new InvalidOperationException("Wait for the category operation to finish.");
        Draft = Saved;
        if (!NeedsReload) Error = null;
    }
}
