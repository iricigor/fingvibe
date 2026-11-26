using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace FingVibe.App.Views;

public sealed record RoomIconOption(PeopleRoomsIconChoice Choice)
{
    public Visibility SuggestionVisibility => Choice.SuggestedRoom is null ? Visibility.Collapsed : Visibility.Visible;
    public string AutomationId => "RoomIconOption-" + Choice.Id;
}

public sealed partial class RoomIconPicker : UserControl
{
    private string _category = "All";
    private bool _initialized;
    private XamlRoot? _flyoutRoot;
    public string? SelectedId { get; private set; }

    public RoomIconPicker()
    {
        InitializeComponent();
        TablePreview.UseRoom();
        foreach (var category in RoomIconCatalog.Categories)
        {
            var button = new ToggleButton { Content = category, Tag = category, IsChecked = category == _category };
            AutomationProperties.SetName(button, $"Room icon category: {category}");
            AutomationProperties.SetAutomationId(button, "RoomIconCategory-" + category);
            button.Checked += Category_Checked;
            button.Unchecked += Category_Unchecked;
            CategoriesPanel.Children.Add(button);
        }
        _initialized = true;
    }

    internal void Initialize(string? savedId, string shortName)
    {
        SelectedId = savedId;
        TablePreview.SetShortName(shortName);
        UpdateSelection();
    }

    internal void SetShortName(string shortName) => TablePreview.SetShortName(shortName);

    private void UpdateSelection()
    {
        var choice = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, SelectedId);
        SelectedIcon.IconId = SelectedId;
        var known = SelectedId is null || PeopleRoomsIcons.Rooms.Any(item => item.Id == SelectedId);
        SelectedLabel.Text = known ? choice.Label : "Unavailable saved icon (generic)";
        SelectedSuggestion.Text = known ? choice.SuggestedRoom ?? string.Empty : string.Empty;
        SelectedSuggestion.Visibility = string.IsNullOrEmpty(SelectedSuggestion.Text) ? Visibility.Collapsed : Visibility.Visible;
        TablePreview.SetIcon(SelectedId);
        AutomationProperties.SetName(PickerButton, $"Room icon: {(known ? choice.AccessibleName : SelectedLabel.Text)}");
        AutomationProperties.SetHelpText(PickerButton, "Choose an icon. Suggested rooms never change your room name.");
    }

    private void RefreshChoices()
    {
        if (!_initialized) return;
        var options = PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, IconSearch.Text, _category)
            .Select(choice => new RoomIconOption(choice)).ToArray();
        IconChoices.ItemsSource = options;
        IconChoices.SelectedItem = options.FirstOrDefault(option =>
            option.Choice.Id == (SelectedId ?? PeopleRoomsIcons.Rooms[0].Id));
        var known = SelectedId is null || PeopleRoomsIcons.Rooms.Any(choice => choice.Id == SelectedId);
        PickerStatus.Text = !known
            ? "Unavailable saved icon (generic). Its saved ID is retained until you choose another icon."
            : options.Length == 0 ? "No matching icons. Change the search or category."
            : IconChoices.SelectedItem is null ? $"{options.Length} icons. The current choice is retained outside this filter."
            : $"{options.Length} icons. Current: {SelectedLabel.Text}.";
    }

    private void IconFlyout_Opening(object? sender, object e)
    {
        _flyoutRoot = XamlRoot;
        if (_flyoutRoot is { } root) root.Changed += FlyoutRoot_Changed;
        UpdateFlyoutSize();
        RefreshChoices();
    }

    private void FlyoutRoot_Changed(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateFlyoutSize();

    private void UpdateFlyoutSize()
    {
        if (_flyoutRoot is { } root)
        {
            PickerPanel.Width = Math.Max(240, Math.Min(720, root.Size.Width - 80));
            PickerViewport.MaxHeight = Math.Max(180, root.Size.Height - 96);
            IconChoices.MaxHeight = Math.Max(100, Math.Min(420, root.Size.Height - 340));
        }
    }

    private void IconFlyout_Closed(object? sender, object e)
    {
        if (_flyoutRoot is { } root) root.Changed -= FlyoutRoot_Changed;
        _flyoutRoot = null;
        PickerButton.Focus(FocusState.Programmatic);
    }

    private void IconSearch_TextChanged(object sender, TextChangedEventArgs e) => RefreshChoices();

    private void Category_Checked(object sender, RoutedEventArgs e)
    {
        var category = (string)((ToggleButton)sender).Tag;
        if (_category == category) return;
        _category = category;
        foreach (var button in CategoriesPanel.Children.OfType<ToggleButton>())
            button.IsChecked = (string)button.Tag == _category;
        RefreshChoices();
    }

    private void Category_Unchecked(object sender, RoutedEventArgs e)
    {
        var button = (ToggleButton)sender;
        if ((string)button.Tag == _category) button.IsChecked = true;
    }

    private void Choose(RoomIconOption option)
    {
        SelectedId = option.Choice.Id;
        UpdateSelection();
        IconFlyout.Hide();
    }

    private void IconChoices_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is RoomIconOption option) Choose(option);
    }

    private void IconChoices_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.Item is RoomIconOption option)
        {
            AutomationProperties.SetName(args.ItemContainer, option.Choice.AccessibleName);
            AutomationProperties.SetAutomationId(args.ItemContainer, option.AutomationId);
        }
        else
        {
            args.ItemContainer.ClearValue(AutomationProperties.NameProperty);
            args.ItemContainer.ClearValue(AutomationProperties.AutomationIdProperty);
        }
    }

    private void IconChoices_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && IconChoices.SelectedItem is RoomIconOption option)
        {
            Choose(option);
            e.Handled = true;
        }
    }
}
