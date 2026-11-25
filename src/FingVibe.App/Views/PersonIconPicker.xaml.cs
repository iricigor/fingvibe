using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace FingVibe.App.Views;

public sealed record PersonIconOption(PeopleRoomsIconChoice Choice, bool IncludeVariants)
{
    public string? Variant => IncludeVariants ? Choice.Variant : null;
    public Visibility VariantVisibility => Variant is null ? Visibility.Collapsed : Visibility.Visible;
    public string AccessibleName => Choice.AccessibleName;
    public string AutomationId => "PersonIconOption-" + Choice.Id;
}

public sealed partial class PersonIconPicker : UserControl
{
    private string _category = "All";
    private bool _initialized;
    public string? SelectedId { get; private set; }

    public PersonIconPicker()
    {
        InitializeComponent();
        foreach (var category in PersonEmojiCatalog.Categories)
        {
            var button = new ToggleButton { Content = category, Tag = category, IsChecked = category == _category };
            AutomationProperties.SetName(button, $"Icon category: {category}");
            button.Click += Category_Click;
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
        var choice = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, SelectedId);
        SelectedIcon.IconId = SelectedId;
        SelectedLabel.Text = PersonEmojiCatalog.IsAvailable(choice, Environment.OSVersion.Version.Build)
            ? choice.AccessibleName : $"{choice.AccessibleName} (unavailable on this Windows version)";
        TablePreview.SetIcon(SelectedId);
        AutomationProperties.SetName(PickerButton, $"Person icon: {choice.AccessibleName}");
        AutomationProperties.SetHelpText(PickerButton,
            "Choose a face or upper-body portrait. Include variants shows additional gender and tone combinations.");
    }

    private void RefreshChoices()
    {
        if (!_initialized) return;
        var available = PeopleRoomsIcons.People.Where(choice =>
            PersonEmojiCatalog.IsAvailable(choice, Environment.OSVersion.Version.Build)).ToArray();
        var choices = PersonEmojiCatalog.Filter(available, IconSearch.Text, _category, IncludeVariants.IsOn);
        var options = choices.Select(choice => new PersonIconOption(choice, IncludeVariants.IsOn)).ToArray();
        IconChoices.ItemsSource = options;
        IconChoices.SelectedItem = options.FirstOrDefault(option =>
            option.Choice.Id == (SelectedId ?? PeopleRoomsIcons.People[0].Id));
        var known = PeopleRoomsIcons.People.Any(choice => choice.Id == SelectedId) || SelectedId is null;
        PickerStatus.Text = !known
            ? "Unavailable saved icon (generic). Its saved ID is retained until you choose another icon."
            : options.Length == 0 ? "No matching icons. Change the search or category."
            : IconChoices.SelectedItem is null ? $"{options.Length} icons. The current choice is retained outside this filter."
            : $"{options.Length} icons. Current: {SelectedLabel.Text}.";
        if (available.Length < PeopleRoomsIcons.People.Count)
            PickerStatus.Text += " Some portraits require newer Windows emoji support; existing selections are retained.";
    }

    private void IconFlyout_Opening(object? sender, object e)
    {
        if (XamlRoot is { } root)
        {
            PickerPanel.Width = Math.Max(240, Math.Min(720, root.Size.Width - 80));
            PickerViewport.MaxHeight = Math.Max(180, root.Size.Height - 96);
            IconChoices.MaxHeight = Math.Max(100, Math.Min(420, root.Size.Height - 340));
        }
        RefreshChoices();
    }

    private void IconFlyout_Closed(object? sender, object e) => PickerButton.Focus(FocusState.Programmatic);
    private void IconSearch_TextChanged(object sender, TextChangedEventArgs e) => RefreshChoices();
    private void IncludeVariants_Toggled(object sender, RoutedEventArgs e) => RefreshChoices();

    private void Category_Click(object sender, RoutedEventArgs e)
    {
        _category = (string)((ToggleButton)sender).Tag;
        foreach (var button in CategoriesPanel.Children.OfType<ToggleButton>())
            button.IsChecked = (string)button.Tag == _category;
        RefreshChoices();
    }

    private void Choose(PersonIconOption option)
    {
        SelectedId = option.Choice.Id;
        UpdateSelection();
        IconFlyout.Hide();
    }

    private void IconChoices_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PersonIconOption option) Choose(option);
    }

    private void IconChoices_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.Item is PersonIconOption option)
        {
            AutomationProperties.SetName(args.ItemContainer, option.AccessibleName);
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
        if (e.Key == VirtualKey.Enter && IconChoices.SelectedItem is PersonIconOption option)
        {
            Choose(option);
            e.Handled = true;
        }
    }
}
