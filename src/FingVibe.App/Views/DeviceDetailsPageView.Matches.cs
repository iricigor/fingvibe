using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed record DeviceMatchCard(string Name, string Status, string Addresses, string Description);

/// <summary>A device offered for linking. Suggestions carry their reason; others may be tagged Declined.</summary>
public sealed record DeviceLinkChoice(string Mac, DeviceMatchCard Card, string? ShortReason, string? Explanation, bool Declined, string Text)
{
    public bool IsSuggested => Explanation is not null;
}

public sealed record DeviceLinkRequest(string OtherMac, FingVibe.Core.Models.LinkedDeviceChoices Choices);

/// <summary>Everything the Merge MAC addresses section shows for the selected device.</summary>
public sealed record MergeSectionModel(
    MergeSectionHeader Header,
    DeviceMatchCard Device,
    IReadOnlyList<DeviceLinkChoice> Suggestions,
    IReadOnlyList<LinkedMemberLine> Members,
    Func<string?, IReadOnlyList<DeviceLinkChoice>> Search,
    Func<string, LinkedDeviceDraft?> CreateDraft);

public sealed partial class DeviceDetailsPageView
{
    private MergeSectionModel? _merge;
    private DeviceLinkChoice? _selectedMatch;
    private LinkedDeviceDraft? _draft;
    private bool _matchExpansionApplied;
    private bool _linking;
    private bool _unlinking;
    private string? _unlinkMac;
    private readonly Dictionary<LinkedField, TextBlock> _mergeResults = [];
    private TextBox? _mergeNameInput;

    public event EventHandler<string>? MatchDeclineRequested;
    public event EventHandler<DeviceLinkRequest>? LinkRequested;
    public event EventHandler<string>? UnlinkRequested;

    internal string? SelectedMatchMac => _selectedMatch?.Mac;

    /// <summary>Shows the section's state. Opening a device expands it once when there are suggestions; refreshes keep the user's choice and draft.</summary>
    internal void ShowMergeSection(MergeSectionModel model, bool opening)
    {
        if (opening)
        {
            _matchExpansionApplied = false;
            _selectedMatch = null;
            _draft = null;
            _linking = false;
            ResetUnlinkState();
            MergeMacError.IsOpen = false;
            MergeMacPickerSearch.Text = string.Empty;
        }
        _merge = model;
        var header = model.Header;
        MergeMacCount.Text = header.Text;
        AutomationProperties.SetName(MergeMacCount, header.Text);
        AutomationProperties.SetHelpText(MergeMacExpander, header.Text);
        VisualStateManager.GoToState(this, header.State switch
        {
            MergeSectionState.PossibleMatches => "MergePossibleMatches",
            MergeSectionState.Linked => "MergeLinked",
            MergeSectionState.Unavailable => "MergeUnavailable",
            _ => "MergeNoSuggestions"
        }, false);
        MergeMacExplanation.Text = header.Explanation;
        MergeMacExplanation.Visibility = string.IsNullOrEmpty(header.Explanation) ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(MergeMacExplanation, header.Explanation);
        ShowLinkedMembers(model.Members);

        var canLink = header.State is MergeSectionState.NoSuggestions or MergeSectionState.PossibleMatches;
        if (!canLink)
        {
            _selectedMatch = null;
            _draft = null;
        }
        else if (_selectedMatch is { } selected)
        {
            // Keep a manual choice or suggestion (and its draft) while it is still offered.
            var current = model.Suggestions.FirstOrDefault(item => item.Mac == selected.Mac)
                ?? (selected.IsSuggested ? null : model.Search(null).FirstOrDefault(item => item.Mac == selected.Mac));
            if (current is null) { _selectedMatch = null; _draft = null; }
            else _selectedMatch = current;
        }
        if (canLink && _selectedMatch is null && model.Suggestions.Count > 0) Select(model.Suggestions[0]);

        MergeMacThisName.Text = model.Device.Name;
        MergeMacThisStatus.Text = model.Device.Status;
        MergeMacThisAddresses.Text = model.Device.Addresses;
        MergeMacThisDescription.Text = model.Device.Description;
        MergeMacActions.Visibility = canLink ? Visibility.Visible : Visibility.Collapsed;
        if (!_matchExpansionApplied && header.State == MergeSectionState.PossibleMatches)
        {
            MergeMacExpander.IsExpanded = true;
            _matchExpansionApplied = true;
        }
        else if (opening)
        {
            MergeMacExpander.IsExpanded = false;
        }
        ShowSelectedMatch();
    }

    /// <summary>Selects Overview, expands the section and brings it into view, as requested from a Devices row.</summary>
    internal void RevealMatchSuggestions()
    {
        DetailsTabs.SelectedItem = OverviewTab;
        ShowTab(OverviewTab);
        MergeMacExpander.IsExpanded = true;
        _matchExpansionApplied = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            MergeMacExpander.UpdateLayout();
            MergeMacExpander.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0 });
        });
    }

    internal void ShowMatchError(string message)
    {
        MergeMacError.Title = "The suggestion could not be declined";
        MergeMacError.Message = message;
        MergeMacError.IsOpen = true;
        MergeMacDecline.IsEnabled = true;
    }

    /// <summary>Reports a failed link; the draft and its choices stay for a retry.</summary>
    internal void ShowLinkError(string message)
    {
        _linking = false;
        MergeMacError.Title = "The devices could not be linked";
        MergeMacError.Message = $"Nothing was saved and your choices are kept. {message}";
        MergeMacError.IsOpen = true;
        UpdateMergeState();
    }

    /// <summary>Reports a failed unlink; the inline confirmation stays available for a retry.</summary>
    internal void ShowUnlinkError(string message)
    {
        _unlinking = false;
        MergeMacError.Title = "The devices could not be unlinked";
        MergeMacError.Message = $"Nothing was saved and the devices remain linked. {message}";
        MergeMacError.IsOpen = true;
        UpdateUnlinkState();
    }

    private void Select(DeviceLinkChoice choice)
    {
        _selectedMatch = choice;
        _draft = _merge?.CreateDraft(choice.Mac);
        BuildMergeTable();
    }

    private void ShowLinkedMembers(IReadOnlyList<LinkedMemberLine> members)
    {
        MergeMacLinkedMembers.Children.Clear();
        foreach (var member in members)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var line = new TextBlock
            {
                Text = member.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                VerticalAlignment = VerticalAlignment.Center
            };
            AutomationProperties.SetName(line, member.Text);
            row.Children.Add(line);
            if (members.Count == 2)
            {
                var unlink = new Button
                {
                    Content = "Unlink",
                    Tag = member.Mac
                };
                AutomationProperties.SetName(unlink, $"Unlink {LinkedMemberLine.FormatMac(member.Mac)}");
                AutomationProperties.SetAutomationId(unlink, $"MergeMacUnlink{member.Mac}");
                unlink.Click += MergeMacUnlink_Click;
                Grid.SetColumn(unlink, 1);
                row.Children.Add(unlink);
            }
            MergeMacLinkedMembers.Children.Add(row);
        }
        MergeMacLinkedMembers.Visibility = members.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (members.Count == 0 || _unlinkMac is not null && members.All(member => member.Mac != _unlinkMac))
            ResetUnlinkState();
        UpdateUnlinkState();
    }

    private void ShowSelectedMatch()
    {
        var suggestions = _merge?.Suggestions ?? [];
        var selected = _selectedMatch;
        MergeMacCandidatePanel.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
        MergeMacChangeDevice.Content = selected is null ? "Choose device..." : "Change device...";
        AutomationProperties.SetName(MergeMacChangeDevice, selected is null ? "Choose device" : "Change device");
        MergeMacDecline.Visibility = selected?.IsSuggested == true ? Visibility.Visible : Visibility.Collapsed;
        if (selected is not null)
        {
            var index = suggestions.ToList().FindIndex(item => item.Mac == selected.Mac);
            MergeMacOtherHeading.Text = index >= 0
                ? $"Selected other MAC address · suggestion {index + 1} of {suggestions.Count}"
                : "Selected other MAC address · chosen manually";
            AutomationProperties.SetName(MergeMacOtherHeading, MergeMacOtherHeading.Text);
            MergeMacOtherName.Text = selected.Card.Name;
            AutomationProperties.SetName(MergeMacOtherName, selected.Card.Name);
            MergeMacOtherStatus.Text = selected.Card.Status;
            MergeMacOtherAddresses.Text = selected.Card.Addresses;
            MergeMacOtherDescription.Text = selected.Card.Description;
            MergeMacReason.Text = selected.Explanation is { } explanation
                ? $"Suggested because {explanation}. This does not establish physical identity." : string.Empty;
            MergeMacReason.Visibility = selected.IsSuggested ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetName(MergeMacReason, MergeMacReason.Text);
            MergeMacDecline.IsEnabled = !_linking;
            AutomationProperties.SetName(MergeMacDecline, $"Decline suggestion: {selected.Card.Name}");
        }
        MergeMacComparison.Visibility = _draft is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateMergeState();
    }

    private void BuildMergeTable()
    {
        _mergeResults.Clear();
        _mergeNameInput = null;
        var table = MergeMacTable;
        table.Children.Clear();
        table.RowDefinitions.Clear();
        if (_draft is not { } draft) return;
        string[] headings = ["Field", "This device", "Other MAC address", "Linked device value"];
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var column = 0; column < headings.Length; column++)
            Add(new TextBlock { Text = headings[column], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }, 0, column);
        foreach (var field in draft.Fields)
        {
            var row = table.RowDefinitions.Count;
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Add(new TextBlock { Text = field.Label, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }, row, 0);
            Add(Value(field, LinkedFieldChoice.ThisDevice, field.ThisText), row, 1);
            Add(Value(field, LinkedFieldChoice.OtherDevice, field.OtherText), row, 2);
            if (field.CanType)
            {
                var input = new TextBox
                {
                    Text = field.TypedName, PlaceholderText = field.ResultText, TextWrapping = TextWrapping.Wrap,
                    FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji")
                };
                AutomationProperties.SetName(input, "Linked device name");
                AutomationProperties.SetAutomationId(input, "MergeMacNameInput");
                input.TextChanged += (_, _) =>
                {
                    field.TypeName(input.Text);
                    if (field.Choice == LinkedFieldChoice.Typed) ClearChoice(field.Field);
                    UpdateMergeState();
                };
                _mergeNameInput = input;
                Add(input, row, 3);
            }
            else
            {
                var result = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                AutomationProperties.SetAutomationId(result, $"MergeMacResult{field.Field}");
                _mergeResults[field.Field] = result;
                Add(result, row, 3);
            }
        }

        void Add(FrameworkElement element, int row, int column)
        {
            Grid.SetRow(element, row);
            Grid.SetColumn(element, column);
            table.Children.Add(element);
        }

        FrameworkElement Value(LinkedFieldDraft field, LinkedFieldChoice side, string text)
        {
            if (!field.Differs)
                return new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            var radio = new RadioButton
            {
                Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
                GroupName = $"MergeMac{field.Field}", IsChecked = field.Choice == side, Tag = side
            };
            var sideName = side == LinkedFieldChoice.ThisDevice ? "this device" : "other MAC address";
            AutomationProperties.SetName(radio, $"{field.Label}: use {sideName} value {text}");
            AutomationProperties.SetAutomationId(radio, $"MergeMacChoice{field.Field}{(side == LinkedFieldChoice.ThisDevice ? "This" : "Other")}");
            radio.Checked += (_, _) =>
            {
                field.Choose(side);
                if (field.CanType && _mergeNameInput is { } input && input.Text.Length > 0) input.Text = string.Empty;
                UpdateMergeState();
            };
            return radio;
        }
    }

    private void ClearChoice(LinkedField field)
    {
        foreach (var radio in MergeMacTable.Children.OfType<RadioButton>().Where(item => item.GroupName == $"MergeMac{field}"))
            radio.IsChecked = false;
    }

    private void UpdateMergeState()
    {
        if (_draft is not { } draft)
        {
            MergeMacMerge.IsEnabled = false;
            return;
        }
        foreach (var field in draft.Fields)
        {
            if (_mergeResults.TryGetValue(field.Field, out var result))
            {
                result.Text = field.ResultText;
                AutomationProperties.SetName(result, $"Linked device {field.Label}: {field.ResultText}");
            }
            else if (field.CanType && _mergeNameInput is { } input)
                input.PlaceholderText = field.Choice == LinkedFieldChoice.Typed ? string.Empty : field.ResultText;
        }
        var unresolved = draft.UnresolvedCount;
        MergeMacUnresolved.Text = unresolved switch
        {
            0 => "Every value is chosen. Merge saves the shared values; nothing is saved before then.",
            1 => "1 difference needs a choice before merging.",
            _ => $"{unresolved} differences need a choice before merging."
        };
        AutomationProperties.SetName(MergeMacUnresolved, MergeMacUnresolved.Text);
        MergeMacMerge.IsEnabled = draft.CanMerge && !_linking;
        MergeMacMerge.Content = _linking ? "Merging..." : "Merge as one device";
        MergeMacCancel.IsEnabled = !_linking;
        MergeMacChangeDevice.IsEnabled = !_linking;
    }

    private void MergeMacPicker_Opened(object? sender, object e)
    {
        RefreshPicker();
        MergeMacPickerSearch.Focus(FocusState.Programmatic);
    }

    private void MergeMacPickerSearch_TextChanged(object sender, TextChangedEventArgs e) => RefreshPicker();

    private void RefreshPicker()
    {
        var items = _merge?.Search(MergeMacPickerSearch.Text) ?? [];
        MergeMacPickerList.Items.Clear();
        var suggested = items.Where(item => item.IsSuggested).ToArray();
        var others = items.Where(item => !item.IsSuggested).ToArray();
        AddGroup("Suggested", suggested);
        AddGroup("Other devices", others);
        MergeMacPickerEmpty.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        void AddGroup(string heading, IReadOnlyList<DeviceLinkChoice> group)
        {
            if (group.Count == 0) return;
            var header = new ListViewItem
            {
                Content = new TextBlock { Text = heading, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                IsEnabled = false, IsTabStop = false
            };
            AutomationProperties.SetName(header, heading);
            AutomationProperties.SetHeadingLevel(header, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level4);
            MergeMacPickerList.Items.Add(header);
            foreach (var choice in group)
            {
                var content = new StackPanel { Spacing = 2, Padding = new Thickness(0, 4, 0, 4) };
                content.Children.Add(new TextBlock
                {
                    Text = choice.Card.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
                    FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji")
                });
                content.Children.Add(new TextBlock { Text = choice.Card.Addresses, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
                if (choice.ShortReason is { } reason)
                    content.Children.Add(new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
                if (choice.Declined)
                    content.Children.Add(new Border
                    {
                        BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 0, 6, 0),
                        HorizontalAlignment = HorizontalAlignment.Left,
                        BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                        Child = new TextBlock { Text = "Declined", FontSize = 12 }
                    });
                var item = new ListViewItem { Content = content, Tag = choice };
                AutomationProperties.SetName(item, choice.Text);
                MergeMacPickerList.Items.Add(item);
            }
        }
    }

    private void MergeMacPickerList_ItemClick(object sender, ItemClickEventArgs e)
    {
        // Items are their own containers; WinUI may report either the container or its content.
        var item = e.ClickedItem as ListViewItem
            ?? MergeMacPickerList.Items.OfType<ListViewItem>().FirstOrDefault(entry => ReferenceEquals(entry.Content, e.ClickedItem));
        if (item?.Tag is not DeviceLinkChoice choice) return;
        MergeMacPicker.Hide();
        MergeMacError.IsOpen = false;
        Select(choice);
        ShowSelectedMatch();
        DispatcherQueue.TryEnqueue(() => MergeMacChangeDevice.Focus(FocusState.Programmatic));
    }

    private void MergeMacDecline_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMatch is not { IsSuggested: true } selected) return;
        MergeMacError.IsOpen = false;
        MergeMacDecline.IsEnabled = false;
        MatchDeclineRequested?.Invoke(this, selected.Mac);
    }

    private void MergeMacMerge_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMatch is not { } selected || _draft is not { CanMerge: true } draft || _linking) return;
        _linking = true;
        MergeMacError.IsOpen = false;
        UpdateMergeState();
        LinkRequested?.Invoke(this, new(selected.Mac, draft.ToChoices()));
    }

    private void MergeMacCancel_Click(object sender, RoutedEventArgs e)
    {
        // Cancel discards the draft; a suggestion stays offered with a fresh draft, a manual choice is cleared.
        MergeMacError.IsOpen = false;
        if (_selectedMatch is { IsSuggested: true } suggestion) Select(suggestion);
        else
        {
            _selectedMatch = null;
            _draft = null;
            BuildMergeTable();
        }
        ShowSelectedMatch();
        MergeMacChangeDevice.Focus(FocusState.Programmatic);
    }

    private void MergeMacUnlink_Click(object sender, RoutedEventArgs e)
    {
        if (_unlinking || sender is not Button { Tag: string mac }) return;
        _unlinkMac = mac;
        MergeMacUnlinkPrompt.Text =
            $"Unlink {LinkedMemberLine.FormatMac(mac)}? It becomes a separate device again, with its latest "
            + "member-specific name, identification, Person, Room and usage category; shared edits stay with the "
            + "remaining device. Its history stays with it.";
        AutomationProperties.SetName(MergeMacUnlinkPrompt, MergeMacUnlinkPrompt.Text);
        MergeMacError.IsOpen = false;
        MergeMacUnlinkConfirmation.Visibility = Visibility.Visible;
        UpdateUnlinkState();
        MergeMacUnlinkConfirm.Focus(FocusState.Programmatic);
    }

    private void MergeMacUnlinkCancel_Click(object sender, RoutedEventArgs e)
    {
        if (_unlinking) return;
        MergeMacError.IsOpen = false;
        ResetUnlinkState();
    }

    private void MergeMacUnlinkConfirm_Click(object sender, RoutedEventArgs e)
    {
        if (_unlinking || _unlinkMac is not { } mac) return;
        _unlinking = true;
        MergeMacError.IsOpen = false;
        UpdateUnlinkState();
        UnlinkRequested?.Invoke(this, mac);
    }

    private void ResetUnlinkState()
    {
        _unlinkMac = null;
        _unlinking = false;
        MergeMacUnlinkConfirmation.Visibility = Visibility.Collapsed;
        UpdateUnlinkState();
    }

    private void UpdateUnlinkState()
    {
        MergeMacUnlinkConfirm.IsEnabled = !_unlinking && _unlinkMac is not null;
        MergeMacUnlinkCancel.IsEnabled = !_unlinking;
        MergeMacUnlinkConfirm.Content = _unlinking ? "Unlinking..." : "Unlink";
        foreach (var button in MergeMacLinkedMembers.Children.OfType<Grid>()
                     .SelectMany(row => row.Children.OfType<Button>()))
            button.IsEnabled = !_unlinking;
    }
}
