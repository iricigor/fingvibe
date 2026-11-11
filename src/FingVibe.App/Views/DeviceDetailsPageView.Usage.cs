using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

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
    private bool _editingUsage;
    public event EventHandler<UsageCategorySaveRequest>? UsageCategorySaveRequested;
    public event EventHandler<Guid>? UsageCategoryReloadRequested;
    public event EventHandler? UsageCategoryRefreshRequested;

    private void InitializeUsageCategory()
    {
        foreach (var choice in UsageChoices)
            UsageCategoryPicker.Items.Add(new ComboBoxItem { Content = choice.Label, Tag = choice });
        UsageCategorySampling.Text = UsageCategoryPresentation.SamplingNotice;
    }

    private void UsageCategoryEdit_Click(object sender, RoutedEventArgs e)
    {
        _editingUsage = true;
        RenderUsageEdit();
        UsageCategoryPicker.Focus(FocusState.Programmatic);
    }

    internal void ShowUsageCategory(ScanResultRow row, bool enabled, bool reset = false)
    {
        if (reset) _editingUsage = false;
        _usageEnabled = enabled;
        if (reset || _usageEdit.Identity != row.UsageIdentity
            || !_usageEdit.HasChanges && !_usageEdit.IsBusy && _usageEdit.Error is null)
            _usageEdit.Load(row.UsageIdentity, row.UsageCategoryOverride);
        UsageCategoryEffective.Inlines.Clear();
        UsageCategoryEffective.Inlines.Add(new Run { Text = row.UsageCategoryCellText });
        UsageCategoryEffective.Inlines.Add(new Run
        {
            Text = $" | {row.UsageCategorySource}", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Normal
        });
        UsageCategoryEffective.Opacity = row.UsageCategoryText == "Unclassified" ? .65 : 1;
        UsageCategorySummary.Text = row.UsageInference is { } summary
            ? UsageCategoryPresentation.Counts(summary.Total) : row.UsageStatus;
        UsageCategoryEvidence.Text = row.UsageInference is { } inference
            ? UsageCategoryPresentation.Evidence(inference) : row.UsageStatus;
        UsageCategoryWindow.Text = row.UsageInference is { } window ? UsageCategoryPresentation.Window(window) : string.Empty;
        UsageCategoryLimited.Text = row.UsageInference is { } limited ? UsageCategoryPresentation.Limitations(limited).Trim() : string.Empty;
        RenderUsageEdit();
    }

    private void RenderUsageEdit()
    {
        UsageCategoryEditor.Visibility = _editingUsage || _usageEdit.Error is not null ? Visibility.Visible : Visibility.Collapsed;
        UsageCategoryEdit.IsEnabled = !_editingUsage && !_usageEdit.IsBusy;
        _updatingUsage = true;
        UsageCategoryPicker.SelectedItem = UsageCategoryPicker.Items.OfType<ComboBoxItem>()
            .First(item => item.Tag is UsageChoice choice && choice.Category == _usageEdit.Draft);
        _updatingUsage = false;
        UsageCategoryPicker.IsEnabled = _usageEnabled && !_usageEdit.IsBusy && !_usageEdit.NeedsReload;
        UsageCategorySave.IsEnabled = _usageEnabled && _usageEdit.HasChanges && !_usageEdit.IsBusy && !_usageEdit.NeedsReload;
        UsageCategorySave.Content = _usageEdit.Error is null ? "Save category" : "Retry save";
        UsageCategoryCancel.IsEnabled = !_usageEdit.IsBusy;
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
        if (error is null)
        {
            _usageEdit.Load(row.UsageIdentity, row.UsageCategoryOverride);
            _editingUsage = false;
        }
        else _usageEdit.Failed($"{error}\nYour category draft is retained; the saved category has not been overwritten.", conflict);
        ShowUsageCategory(row, _usageEnabled);
        if (error is null) UsageCategoryEdit.Focus(FocusState.Programmatic);
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
        _editingUsage = _usageEdit.NeedsReload;
        RenderUsageEdit();
        UsageCategoryEdit.Focus(FocusState.Programmatic);
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
