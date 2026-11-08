using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed record UsageCategorySaveRequest(Guid EditToken, LogicalDeviceId Identity,
    DeviceUsageCategory? Previous, DeviceUsageCategory? Category);

public sealed partial class DeviceDetailsPageView
{
    private sealed record UsageChoice(string Label, DeviceUsageCategory? Category);
    private static readonly UsageChoice[] UsageChoices =
    [
        new("Automatic", null), new("Permanent", DeviceUsageCategory.Permanent),
        new("Personal", DeviceUsageCategory.Personal), new("Guest", DeviceUsageCategory.Guest),
        new("Unclassified", DeviceUsageCategory.Unclassified)
    ];
    private readonly UsageCategoryEditState _usageEdit = new();
    private bool _updatingUsage;
    private bool _usageEnabled;
    public event EventHandler<UsageCategorySaveRequest>? UsageCategorySaveRequested;
    public event EventHandler<Guid>? UsageCategoryReloadRequested;
    public event EventHandler? UsageCategoryRefreshRequested;

    private void InitializeUsageCategory()
    {
        foreach (var choice in UsageChoices)
            UsageCategoryPicker.Items.Add(new ComboBoxItem { Content = choice.Label, Tag = choice });
        UsageCategorySampling.Text = UsageCategoryPresentation.SamplingNotice;
    }

    internal void ShowUsageCategory(ScanResultRow row, bool enabled, bool reset = false)
    {
        _usageEnabled = enabled;
        if (reset || _usageEdit.Identity != row.UsageIdentity
            || !_usageEdit.HasChanges && !_usageEdit.IsBusy && _usageEdit.Error is null)
            _usageEdit.Load(row.UsageIdentity, row.UsageCategoryOverride);
        UsageCategoryEffective.Text = $"Saved effective category: {row.UsageCategoryText} | {row.UsageCategorySource}";
        UsageCategoryEvidence.Text = row.UsageInference is { } inference
            ? UsageCategoryPresentation.Evidence(inference) : row.UsageStatus;
        UsageCategoryWindow.Text = row.UsageInference is { } window ? UsageCategoryPresentation.Window(window) : string.Empty;
        UsageCategoryLimited.IsOpen = row.UsageInference is { Total.Eligible: > 0, LimitedEvidence: true };
        RenderUsageEdit();
    }

    private void RenderUsageEdit()
    {
        _updatingUsage = true;
        UsageCategoryPicker.SelectedItem = UsageCategoryPicker.Items.OfType<ComboBoxItem>()
            .First(item => item.Tag is UsageChoice choice && choice.Category == _usageEdit.Draft);
        _updatingUsage = false;
        UsageCategoryPicker.IsEnabled = _usageEnabled && !_usageEdit.IsBusy && !_usageEdit.NeedsReload;
        UsageCategorySave.IsEnabled = _usageEnabled && _usageEdit.HasChanges && !_usageEdit.IsBusy && !_usageEdit.NeedsReload;
        UsageCategorySave.Content = _usageEdit.Error is null ? "Save category" : "Retry save";
        UsageCategoryCancel.IsEnabled = !_usageEdit.IsBusy && (_usageEdit.HasChanges || _usageEdit.Error is not null);
        UsageCategoryError.IsOpen = _usageEdit.Error is not null;
        UsageCategoryError.Message = _usageEdit.Error ?? string.Empty;
        UsageCategoryReload.Visibility = _usageEdit.NeedsReload ? Visibility.Visible : Visibility.Collapsed;
        UsageCategoryReload.IsEnabled = !_usageEdit.IsBusy;
        UsageCategoryRefresh.IsEnabled = !_usageEdit.IsBusy;
        UsageCategoryEditStatus.Text = _usageEdit.IsReloading ? "Reloading saved category..."
            : _usageEdit.IsSaving ? "Saving category..."
            : _usageEdit.NeedsReload ? "Reload the saved category before editing or retrying. Reload discards this category draft."
            : !_usageEnabled ? "Category changes require a loaded, saved device identity."
            : _usageEdit.HasChanges ? "Unsaved category changes." : "No unsaved category changes.";
    }

    private void UsageCategory_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUsage || UsageCategoryPicker.SelectedItem is not ComboBoxItem { Tag: UsageChoice choice }) return;
        _usageEdit.Choose(choice.Category);
        RenderUsageEdit();
    }

    private void UsageCategorySave_Click(object sender, RoutedEventArgs e)
    {
        _usageEdit.BeginSave();
        var request = new UsageCategorySaveRequest(_usageEdit.Token, _usageEdit.Identity!, _usageEdit.Saved, _usageEdit.Draft);
        RenderUsageEdit();
        UsageCategorySaveRequested?.Invoke(this, request);
    }

    internal void CompleteUsageCategorySave(UsageCategorySaveRequest request, ScanResultRow row, string? error, bool conflict)
    {
        if (_usageEdit.Token != request.EditToken) return;
        if (error is null) _usageEdit.Load(row.UsageIdentity, row.UsageCategoryOverride);
        else _usageEdit.Failed($"{error}\nYour category draft is retained; the saved category has not been overwritten.", conflict);
        ShowUsageCategory(row, _usageEnabled);
    }

    internal void CompleteUsageCategoryReload(Guid token, ScanResultRow row, bool enabled)
    {
        if (_usageEdit.Token == token) ShowUsageCategory(row, enabled, reset: true);
    }

    internal void UsageCategoryReloadFailed(Guid token, string message)
    {
        if (_usageEdit.Token != token) return;
        _usageEdit.Failed(message, conflict: true);
        RenderUsageEdit();
    }

    private void UsageCategoryCancel_Click(object sender, RoutedEventArgs e)
    {
        _usageEdit.Cancel();
        RenderUsageEdit();
        UsageCategoryPicker.Focus(FocusState.Programmatic);
    }

    private void UsageCategoryReload_Click(object sender, RoutedEventArgs e)
    {
        _usageEdit.BeginReload();
        RenderUsageEdit();
        UsageCategoryReloadRequested?.Invoke(this, _usageEdit.Token);
    }
    private void UsageCategoryRefresh_Click(object sender, RoutedEventArgs e) =>
        UsageCategoryRefreshRequested?.Invoke(this, EventArgs.Empty);
}
