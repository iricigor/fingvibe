using System.Collections.Specialized;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Input;

namespace FingVibe.App.Views;

public sealed partial class DevicesPageView : UserControl
{
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private bool _updatingFilters;
    private bool _updatingStatusChips;
    private bool _filtersReady;
    private readonly MultiSelectFilter<InventoryDeviceStatus> _statuses;
    private readonly MultiSelectFilter<DeviceType> _types;
    private readonly MultiSelectFilter<DeviceOperatingSystem> _operatingSystems;
    private readonly MultiSelectFilter<string> _vendors;
    private readonly MultiSelectFilter<Guid?> _people;
    private readonly MultiSelectFilter<Guid?> _rooms;
    private readonly MultiSelectFilter<DeviceUsageCategory> _usageCategories;
    private readonly DeviceLastSeenAgeRefresh _lastSeenAges;
    private readonly HashSet<string> _expandedMacRows = new(StringComparer.Ordinal);
    private IEnumerable<ScanResultRow> _results = [];

    public DevicesPageView()
    {
        InitializeComponent();
        InitializeCellPreviews();
        _lastSeenAges = new(() => _results, RefreshLastSeenAgesOnUi);
        Loaded += (_, _) => UpdateLastSeenAgeRefresh();
        Unloaded += (_, _) => _lastSeenAges.SetActive(false);
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => UpdateLastSeenAgeRefresh());
        // Status has only four values, so it offers no Any known choice; the other categories keep theirs.
        _statuses = new(this, InventoryStatusFilter, "Status", OnFiltersChanged, InventoryDeviceStatus.Unknown);
        _types = new(this, TypeFilter, "Device type", OnFiltersChanged,
            DeviceType.Unknown, "Any known type", "Any known", "Any known device type, excluding Unknown.", displayCategory: "Type");
        _operatingSystems = new(this, OperatingSystemFilter, "Operating system", OnFiltersChanged,
            DeviceOperatingSystem.Unknown, "Any known OS", "Any known", "Any known operating system, excluding Unknown.", displayCategory: "OS");
        _vendors = new(this, VendorFilter, "Vendor", OnFiltersChanged,
            DeviceVendorPresentation.Unknown, "Any identified vendor", "Any identified",
            "Any identified vendor, excluding Unknown and Randomized MAC.",
            StringComparer.OrdinalIgnoreCase, DeviceVendorPresentation.IsKnown);
        _people = new(this, PersonFilter, "Person", OnFiltersChanged, null,
            "Any assigned person", "Any assigned", "Any assigned person, excluding Unassigned.");
        _rooms = new(this, RoomFilter, "Room", OnFiltersChanged, null,
            "Any assigned room", "Any assigned", "Any assigned room, excluding Unassigned.");
        _usageCategories = new(this, UsageCategoryFilter, "Usage category", OnFiltersChanged,
            DeviceUsageCategory.Unclassified, "Any classified usage", "Any classified",
            "Any classified usage category, excluding Unclassified.", displayCategory: "Usage");
        _usageCategories.SetChoices(Enum.GetValues<DeviceUsageCategory>().Select(value => (value, value.ToString())));
        _statuses.SetChoices([
            (InventoryDeviceStatus.Online, "Online"), (InventoryDeviceStatus.Offline, "Offline"),
            (InventoryDeviceStatus.Unknown, "Unknown"), (InventoryDeviceStatus.FingOnly, "Fing Only")],
            value => (DataTemplate)Resources[$"Status{value}FilterIndicator"]);
        _types.SetChoices(Enum.GetValues<DeviceType>().Select(value => (value, value.Label())));
        _operatingSystems.SetChoices(Enum.GetValues<DeviceOperatingSystem>().Select(value => (value, value.Label())));
        SetVendorFilters([]);
        _people.SetChoices([(null, "Unassigned")]);
        _rooms.SetChoices([(null, "Unassigned")]);
        _filtersReady = true;
        OnFiltersChanged();
    }

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event EventHandler? FiltersChanged;
    public event EventHandler<string>? SortRequested;
    public event EventHandler<ScanResultRow>? DeviceRequested;
    public event EventHandler<ScanResultRow>? MatchSuggestionRequested;
    public event EventHandler<ScanResultRow>? ServiceDiscoveryRequested;

    internal string SearchText { get => ResultSearchBox.Text; set => ResultSearchBox.Text = value; }
    internal bool OpenPortsOnly { get => OpenPortsFilter.IsChecked == true; set => OpenPortsFilter.IsChecked = value; }
    internal InventoryDeviceStatus? StatusFilter
    {
        set
        {
            _statuses.SelectOnly(value is { } status ? [status] : []);
            OnFiltersChanged();
        }
    }
    internal IReadOnlySet<InventoryDeviceStatus> StatusFilters => _statuses.Selected;

    internal void RestoreStatusFilters(IEnumerable<InventoryDeviceStatus> statuses)
    {
        _updatingFilters = true;
        try
        {
            _statuses.SelectOnly(statuses);
        }
        finally { _updatingFilters = false; }
        OnFiltersChanged();
    }

    internal ScanResultRow? SelectedResult
    {
        get => ResultsList.SelectedItem as ScanResultRow;
        set => ResultsList.SelectedItem = value;
    }
    internal DeviceResultFilter CreateFilter() => new(false, OpenPortsOnly, SearchText)
    {
        Statuses = _statuses.Selected,
        Types = _types.Selected,
        OperatingSystems = _operatingSystems.Selected,
        Vendors = _vendors.Selected,
        People = _people.Selected,
        Rooms = _rooms.Selected,
        UsageCategories = _usageCategories.Selected,
        AnyKnownType = _types.AnyKnown,
        AnyKnownOperatingSystem = _operatingSystems.AnyKnown,
        AnyKnownVendor = _vendors.AnyKnown,
        AnyAssignedPerson = _people.AnyKnown,
        AnyAssignedRoom = _rooms.AnyKnown,
        AnyClassifiedUsage = _usageCategories.AnyKnown
    };

    internal void SetVendorFilters(IEnumerable<string> vendors) =>
        _vendors.SetChoices(vendors.Select(DeviceVendorPresentation.FilterValue)
            .Concat([DeviceVendorPresentation.Unknown, DeviceVendorPresentation.Randomized])
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value == DeviceVendorPresentation.Unknown ? 0 : 1)
            .ThenBy(value => DeviceVendorPresentation.DisplayText(value), StringComparer.OrdinalIgnoreCase)
            .Select(value => (value, DeviceVendorPresentation.DisplayText(value))));

    internal void SetResults(IEnumerable<ScanResultRow> results)
    {
        DismissCellPreview();
        if (_results is INotifyCollectionChanged previous) previous.CollectionChanged -= Results_CollectionChanged;
        _results = results;
        foreach (var row in results)
            row.SetMacExpansionState(_expandedMacRows.Contains(row.IdentityKey), SearchText);
        if (results is INotifyCollectionChanged current) current.CollectionChanged += Results_CollectionChanged;
        ResultsList.ItemsSource = results;
        _lastSeenAges.RefreshIfActive(results);
    }

    private void DeviceMatchButton_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Button button && ToolTipService.GetToolTip(button) is ToolTip tooltip)
        {
            tooltip.PlacementTarget = button;
            tooltip.IsOpen = true;
        }
    }

    private void DeviceMatchButton_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not Button button || ToolTipService.GetToolTip(button) is not ToolTip tooltip)
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            await Task.Delay(500);
            if (!button.IsPointerOver && tooltip.IsOpen)
            {
                tooltip.IsOpen = false;
            }
        });
    }

    private void Results_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs args)
    {
        if (args.NewItems is not { } added) return;
        var rows = added.OfType<ScanResultRow>().ToArray();
        foreach (var row in rows)
            row.SetMacExpansionState(_expandedMacRows.Contains(row.IdentityKey), SearchText);
        _lastSeenAges.RefreshIfActive(rows);
    }

    private void UpdateLastSeenAgeRefresh() => _lastSeenAges.SetActive(IsLoaded && Visibility == Visibility.Visible);

    private void RefreshLastSeenAgesOnUi(Action refresh) => DispatcherQueue.TryEnqueue(() =>
    {
        // A changed hovered value would leave its emphasis range stale, so close that preview instead.
        var hovered = _hoverText is { Name: "DeviceLastSeenText" } text ? text.Text : null;
        refresh();
        if (hovered is not null && _hoverText?.Text != hovered) DismissCellPreview();
    });

    internal void FocusResults() => ResultsList.Focus(FocusState.Programmatic);

    internal void ShowScanProgress(string? progress, string? detail)
    {
        ScanProgressText.Text = progress ?? string.Empty;
        ScanProgressText.Visibility = progress is null ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(ScanProgressText, detail);
        AutomationProperties.SetHelpText(ScanProgressText, detail ?? string.Empty);
    }

    internal void SetInteractionsEnabled(bool enabled)
    {
        ResultsList.IsItemClickEnabled = enabled;
        ResultsList.SelectionMode = enabled ? ListViewSelectionMode.Single : ListViewSelectionMode.None;
    }

    internal void ShowSummary(string count, string emptyMessage, bool isEmpty)
    {
        ResultCountText.Text = count;
        EmptyResultsText.Text = emptyMessage;
        EmptyResultsText.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    internal void ShowInventorySummary(int online, int offline, int unknown, int fingOnly)
    {
        OnlineCountText.Text = $"{online:N0} Online";
        OfflineCountText.Text = $"{offline:N0} Offline";
        UnknownCountText.Text = $"{unknown:N0} Unknown";
        FingOnlyCountText.Text = $"{fingOnly:N0} Fing Only";
        AutomationProperties.SetName(OnlineChip, OnlineCountText.Text);
        AutomationProperties.SetName(OfflineChip, OfflineCountText.Text);
        AutomationProperties.SetName(UnknownChip, UnknownCountText.Text);
        AutomationProperties.SetName(FingOnlyChip, FingOnlyCountText.Text);
        AutomationProperties.SetName(InventoryCountsText,
            $"{OnlineCountText.Text} · {OfflineCountText.Text} · {UnknownCountText.Text} · {FingOnlyCountText.Text}");
    }

    internal void ShowLastScan(ScanSnapshot? snapshot) =>
        LastScanText.Text = "Scan duration " + (snapshot?.Duration is { } duration
            ? $"{duration.TotalSeconds:N1}s" : snapshot is null ? "—" : "not recorded");

    internal void ShowSort(ResultSortColumn column, bool ascending, bool ignoreNameEmoji = false)
    {
        string Glyph(ResultSortColumn candidate) =>
            column == candidate ? (ascending ? "\u2191" : "\u2193") : string.Empty;

        var nameActive = column == ResultSortColumn.Name;
        NameSortGlyph.Text = Glyph(ResultSortColumn.Name);
        NameEmojiMarker.Visibility = nameActive && ignoreNameEmoji ? Visibility.Visible : Visibility.Collapsed;
        // The Aa marker is not self-explanatory, so the tooltip and accessible state spell out the active mode.
        var nameState = nameActive
            ? $"Name {(ascending ? "ascending" : "descending")}{(ignoreNameEmoji ? ", ignoring emojis" : string.Empty)}"
            : "Sort by name";
        ToolTipService.SetToolTip(NameSortButton, nameState);
        AutomationProperties.SetHelpText(NameSortButton, nameActive ? nameState : string.Empty);
        VendorSortGlyph.Text = Glyph(ResultSortColumn.Vendor);
        OpenPortsSortGlyph.Text = Glyph(ResultSortColumn.OpenPorts);
        PersonSortGlyph.Text = MergedPersonSortGlyph.Text = Glyph(ResultSortColumn.Person);
        RoomSortGlyph.Text = MergedRoomSortGlyph.Text = RoomOnlySortGlyph.Text = Glyph(ResultSortColumn.Room);
        AddressSortGlyph.Text = Glyph(ResultSortColumn.Address);
        StatusSortGlyph.Text = Glyph(ResultSortColumn.Status);
        ResponseSortGlyph.Text = SeparateResponseSortGlyph.Text = Glyph(ResultSortColumn.Response);
        MacAddressSortGlyph.Text = MergedMacAddressSortGlyph.Text = Glyph(ResultSortColumn.MacAddress);
        OperatingSystemSortGlyph.Text = MergedOperatingSystemSortGlyph.Text = Glyph(ResultSortColumn.OperatingSystem);
        DeviceTypeSortGlyph.Text = SeparateDeviceTypeSortGlyph.Text = Glyph(ResultSortColumn.DeviceType);
        LastSeenSortGlyph.Text = Glyph(ResultSortColumn.LastSeen);
        UsageCategorySortGlyph.Text = Glyph(ResultSortColumn.UsageCategory);
    }

    internal void SetPeopleRoomFilters(IEnumerable<(Guid Id, string Label)> people,
        IEnumerable<(Guid Id, string Label)> rooms)
    {
        _people.SetChoices(new (Guid?, string)[] { (null, "Unassigned") }
            .Concat(people.Select(value => ((Guid?)value.Id, value.Label))));
        _rooms.SetChoices(new (Guid?, string)[] { (null, "Unassigned") }
            .Concat(rooms.Select(value => ((Guid?)value.Id, value.Label))));
    }

    private void DeviceFilters_SizeChanged(object sender, SizeChangedEventArgs e)
        => UpdatePrimaryFilterLayout(e.NewSize.Width);

    private void UpdatePrimaryFilterLayout(double width)
    {
        const double spacing = 8;
        const double minimumSearchWidth = 180;
        var textScale = _uiSettings.TextScaleFactor;
        var availableWidth = Math.Max(0, width);
        FilterExpander.Width = 64 * textScale;
        ClearFiltersLink.Width = 36 * textScale;
        var primaryWidth = Math.Max(0, availableWidth - FilterExpander.Width - spacing - 2
            - (ClearFiltersLink.Visibility == Visibility.Visible ? ClearFiltersLink.Width : 0));
        var statusWidth = Math.Min(210 * textScale, primaryWidth);
        InventoryStatusFilter.Width = statusWidth;
        var stackedSearch = primaryWidth < minimumSearchWidth + statusWidth + spacing;
        DeviceSearchFilters.RowSpacing = stackedSearch ? spacing : 0;
        Grid.SetRow(InventoryStatusFilter, stackedSearch ? 1 : 0);
        Grid.SetColumn(InventoryStatusFilter, stackedSearch ? 0 : 1);
        Grid.SetColumnSpan(InventoryStatusFilter, stackedSearch ? 2 : 1);
        Grid.SetColumnSpan(ResultSearchBox, stackedSearch ? 2 : 1);
    }

    private void DeviceSummary_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var scale = _uiSettings.TextScaleFactor;
        var inline = e.NewSize.Width >= 850 * scale;
        var narrow = e.NewSize.Width < 600 * scale;
        LayoutStatusCounts(narrow
            ? Math.Clamp((int)((e.NewSize.Width + 8) / (105 * scale + 8)), 1, 4)
            : 4);
        InventoryCountsText.MaxWidth = Math.Max(0, e.NewSize.Width);
        Grid.SetColumnSpan(InventoryCountsText, inline ? 1 : narrow ? 3 : 2);
        Grid.SetRow(ResultCountText, inline ? 0 : 1);
        Grid.SetColumn(ResultCountText, inline ? 1 : 0);
        Grid.SetColumnSpan(ResultCountText, inline ? 1 : 3);
        Grid.SetRow(LastScanText, narrow ? 2 : 0);
        Grid.SetColumn(LastScanText, narrow ? 0 : 2);
        Grid.SetColumnSpan(LastScanText, narrow ? 3 : 1);
    }

    private void LayoutStatusCounts(int columns)
    {
        ToggleButton[] chips = [OnlineChip, OfflineChip, UnknownChip, FingOnlyChip];
        var rows = (chips.Length + columns - 1) / columns;
        if (InventoryCountsText.RowDefinitions.Count != rows)
        {
            InventoryCountsText.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
                InventoryCountsText.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }
        if (InventoryCountsText.ColumnDefinitions.Count != columns)
        {
            InventoryCountsText.ColumnDefinitions.Clear();
            for (var column = 0; column < columns; column++)
                InventoryCountsText.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        for (var index = 0; index < chips.Length; index++)
        {
            Grid.SetRow(chips[index], index / columns);
            Grid.SetColumn(chips[index], index % columns);
        }
    }

    internal void RefreshRowDescriptions()
    {
        if (ResultsList.ItemsPanelRoot is not { } panel) return;
        foreach (var container in panel.Children.OfType<ListViewItem>())
            if (ResultsList.ItemFromContainer(container) is ScanResultRow row)
                UpdateRowAutomation(container, row);
    }

    private void ResultsList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (_previewAnchor is { } anchor && FindAncestor<ListViewItem>(anchor) == args.ItemContainer)
            DismissCellPreview();
        if (args.Item is ScanResultRow row)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(args.ItemContainer, FullRowValues(row));
            row.SetMacExpansionState(_expandedMacRows.Contains(row.IdentityKey), SearchText);
            if (args.ItemContainer is ListViewItem container) UpdateRowAutomation(container, row);
            row.IsPointerOver = false;
            row.IsSelected = ReferenceEquals(ResultsList.SelectedItem, row);
            args.ItemContainer.RemoveHandler(PointerEnteredEvent, new PointerEventHandler(ResultRow_PointerEntered));
            args.ItemContainer.RemoveHandler(PointerExitedEvent, new PointerEventHandler(ResultRow_PointerExited));
            if (!args.InRecycleQueue)
            {
                args.ItemContainer.AddHandler(PointerEnteredEvent, new PointerEventHandler(ResultRow_PointerEntered), true);
                args.ItemContainer.AddHandler(PointerExitedEvent, new PointerEventHandler(ResultRow_PointerExited), true);
            }
        }
    }

    private void ResultsList_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        foreach (var row in args.RemovedItems.OfType<ScanResultRow>())
        {
            row.IsSelected = false;
        }
        foreach (var row in args.AddedItems.OfType<ScanResultRow>())
        {
            row.IsSelected = true;
        }
    }

    private void ResultRow_PointerEntered(object sender, PointerRoutedEventArgs args)
    {
        if (sender is ListViewItem container && ResultsList.ItemFromContainer(container) is ScanResultRow row)
        {
            row.IsPointerOver = true;
        }
    }

    private void ResultRow_PointerExited(object sender, PointerRoutedEventArgs args)
    {
        if (sender is ListViewItem container && ResultsList.ItemFromContainer(container) is ScanResultRow row)
        {
            row.IsPointerOver = false;
        }
    }

    private void ResultSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        foreach (var row in _results) row.SetMacExpansionSearch(SearchText);
        OnFiltersChanged();
        RefreshRowDescriptions();
    }
    private void OpenPortsFilter_Changed(object sender, RoutedEventArgs e) => OnFiltersChanged();

    private void OnFiltersChanged()
    {
        if (_updatingFilters || !_filtersReady) return;
        _updatingStatusChips = true;
        try
        {
            OnlineChip.IsChecked = _statuses.Selected.Contains(InventoryDeviceStatus.Online);
            OfflineChip.IsChecked = _statuses.Selected.Contains(InventoryDeviceStatus.Offline);
            FingOnlyChip.IsChecked = _statuses.Selected.Contains(InventoryDeviceStatus.FingOnly);
            UnknownChip.IsChecked = _statuses.Selected.Contains(InventoryDeviceStatus.Unknown);
        }
        finally { _updatingStatusChips = false; }
        var filter = CreateFilter();
        var count = filter.ActiveSecondaryCategoryCount;
        ActiveFilterCount.Text = count.ToString(System.Globalization.CultureInfo.CurrentCulture);
        ActiveFilterCount.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var expanded = FilterExpander.IsChecked == true;
        AutomationProperties.SetName(FilterExpander,
            $"{(expanded ? "Hide" : "Show")} additional device filters; {count} active categories");
        AutomationProperties.SetHelpText(FilterExpander, expanded ? "Expanded" : "Collapsed");
        PortsFilter.Content = CreateFilterLabel(PortsFilter, OpenPortsOnly ? "Ports | With open ports" : "Ports", OpenPortsOnly);
        AutomationProperties.SetName(PortsFilter, OpenPortsOnly ? "Ports: With open ports" : "Ports: All");
        ToolTipService.SetToolTip(PortsFilter, OpenPortsOnly ? "Ports: With open ports" : "Ports: All");
        ClearFiltersLink.Visibility = filter.HasRestrictions ? Visibility.Visible : Visibility.Collapsed;
        FilterExpander.CornerRadius = filter.HasRestrictions ? new CornerRadius(3, 0, 0, 3) : new CornerRadius(3);
        UpdatePrimaryFilterLayout(DeviceFilters.ActualWidth);
        FiltersChanged?.Invoke(this, EventArgs.Empty);
    }

    private void StatusChip_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingStatusChips) return;
        if (sender is ToggleButton { Tag: string index })
        {
            var status = (InventoryDeviceStatus)(int.Parse(index, System.Globalization.CultureInfo.InvariantCulture) - 1);
            _statuses.Toggle(status);
            OnFiltersChanged();
        }
    }

    private void FilterExpander_Changed(object sender, RoutedEventArgs e)
    {
        if (!_filtersReady) return;
        DeviceFilterOptions.Visibility = FilterExpander.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        OnFiltersChanged();
    }

    internal void ClearFilters()
    {
        _updatingFilters = true;
        try
        {
            SearchText = string.Empty;
            _statuses.Clear();
            _types.Clear();
            _operatingSystems.Clear();
            _vendors.Clear();
            _people.Clear();
            _rooms.Clear();
            _usageCategories.Clear();
            OpenPortsOnly = false;
        }
        finally { _updatingFilters = false; }
        OnFiltersChanged();
    }

    private void ClearFilters_Click(object sender, RoutedEventArgs e)
    {
        ClearFilters();
        ResultSearchBox.Focus(FocusState.Programmatic);
    }

    private FrameworkElement CreateFilterLabel(DropDownButton button, string text, bool active,
        IReadOnlyList<DataTemplate>? indicators = null)
    {
        var label = new TextBlock
        {
            Text = text,
            Style = (Style)Resources[active ? "ActiveFilterLabelStyle" : "InactiveFilterLabelStyle"]
        };
        AutomationProperties.SetAutomationId(label, button.Name + "Label");
        if (indicators is not { Count: > 0 }) return label;

        // The closed filter repeats the popup's status dots: one per selected status, never a single
        // dot standing in for several.
        var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(dots, AccessibilityView.Raw);
        foreach (var indicator in indicators) dots.Children.Add((FrameworkElement)indicator.LoadContent());
        var content = new Grid { ColumnSpacing = 8 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(dots);
        Grid.SetColumn(label, 1);
        content.Children.Add(label);
        return content;
    }

    private sealed class MultiSelectFilter<T>
    {
        // Longer choice lists (Type, and Vendor/Person/Room as they grow) get a search box; short lists stay
        // scannable without one.
        private const int SearchThreshold = 8;
        private readonly DevicesPageView _view;
        private readonly DropDownButton _button;
        private readonly string _category;
        private readonly string _displayCategory;
        private readonly Action _changed;
        private readonly DeviceFilterSelection<T> _selection;
        private readonly string? _anyLabel;
        private readonly string? _anySummary;
        private readonly string? _anyDescription;
        private readonly List<(T Value, CheckBox CheckBox)> _checks = [];
        private CheckBox? _anyCheck;
        private Func<T, DataTemplate>? _indicatorTemplate;
        private DataTemplate? _anyIndicatorTemplate;
        private bool _syncing;

        // Without anyLabel the filter offers only its individual choices.
        internal MultiSelectFilter(DevicesPageView view, DropDownButton button, string category, Action changed,
            T missingValue, string? anyLabel = null, string? anySummary = null, string? anyDescription = null,
            IEqualityComparer<T>? comparer = null, Func<T, bool>? isKnown = null, string? displayCategory = null)
        {
            _view = view;
            _button = button;
            _category = category;
            _displayCategory = displayCategory ?? category;
            _changed = changed;
            _selection = new(missingValue, comparer, isKnown);
            _anyLabel = anyLabel;
            _anySummary = anySummary;
            _anyDescription = anyDescription;
            UpdateLabel();
        }

        internal IReadOnlySet<T> Selected => _selection.Selected;
        internal bool AnyKnown => _selection.AnyKnown;

        internal void SetChoices(IEnumerable<(T Value, string Label)> values,
            Func<T, DataTemplate>? indicatorTemplate = null, DataTemplate? anyIndicatorTemplate = null)
        {
            if (!_selection.SetChoices(values)) return;
            _indicatorTemplate = indicatorTemplate;
            _anyIndicatorTemplate = anyIndicatorTemplate;
            _checks.Clear();
            _anyCheck = null;
            var searchable = new List<(string Label, FrameworkElement Element)>();
            var panel = new StackPanel();
            AutomationProperties.SetAutomationId(panel, _button.Name + "Choices");
            AutomationProperties.SetName(panel, _category + " choices");
            AutomationProperties.SetAccessibilityView(panel, AccessibilityView.Content);
            foreach (var (value, label) in _selection.Choices)
            {
                var check = new CheckBox
                {
                    Content = CreateChoiceContent(label, indicatorTemplate?.Invoke(value)),
                    IsChecked = Selected.Contains(value),
                    HorizontalAlignment = HorizontalAlignment.Stretch
                };
                AutomationProperties.SetName(check, label);
                check.Checked += (_, _) => SetSelected(value, true);
                check.Unchecked += (_, _) => SetSelected(value, false);
                panel.Children.Add(check);
                _checks.Add((value, check));
                searchable.Add((label, check));
                if (_anyLabel is not null && _selection.IsMissing(value) && _selection.ShowAnyChoice)
                {
                    var any = new CheckBox
                    {
                        Content = anyIndicatorTemplate is null ? _anyLabel : CreateChoiceContent(_anyLabel, anyIndicatorTemplate),
                        IsChecked = AnyKnown,
                        HorizontalAlignment = HorizontalAlignment.Stretch
                    };
                    AutomationProperties.SetAutomationId(any, _button.Name + "Any");
                    AutomationProperties.SetName(any, _anyLabel);
                    AutomationProperties.SetHelpText(any, _anyDescription);
                    ToolTipService.SetToolTip(any, _anyDescription);
                    any.Checked += (_, _) => SetAnyKnown(true);
                    any.Unchecked += (_, _) => SetAnyKnown(false);
                    panel.Children.Add(any);
                    _anyCheck = any;
                    searchable.Add((_anyLabel, any));
                }
            }
            var choices = new ScrollViewer
            {
                MaxHeight = 320,
                MaxWidth = 280,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = panel
            };
            var flyout = new Flyout { Content = choices };
            if (_selection.Choices.Count > SearchThreshold)
            {
                flyout.Content = CreateSearchableContent(choices, searchable, out var resetSearch);
                // Each opening starts from the full list; hidden choices keep their checked state.
                flyout.Opening += (_, _) => resetSearch();
            }
            _button.Flyout = flyout;
            UpdateLabel();
        }

        private FrameworkElement CreateSearchableContent(ScrollViewer choices,
            IReadOnlyList<(string Label, FrameworkElement Element)> searchable, out Action reset)
        {
            var noun = _category.ToLowerInvariant();
            var searchBox = new TextBox { PlaceholderText = $"Search {noun}", Margin = new Thickness(0, 0, 0, 8) };
            AutomationProperties.SetAutomationId(searchBox, _button.Name + "Search");
            AutomationProperties.SetName(searchBox, $"Search {noun} choices");
            var noMatches = new TextBlock
            {
                Text = $"No {noun} matches this search.",
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, 0, 0, 8)
            };
            AutomationProperties.SetAutomationId(noMatches, _button.Name + "NoMatches");
            AutomationProperties.SetLiveSetting(noMatches, AutomationLiveSetting.Polite);
            void Apply(string query)
            {
                var term = query.Trim();
                var shown = 0;
                foreach (var (label, element) in searchable)
                {
                    var match = term.Length == 0 || label.Contains(term, StringComparison.CurrentCultureIgnoreCase);
                    element.Visibility = match ? Visibility.Visible : Visibility.Collapsed;
                    if (match) shown++;
                }
                noMatches.Visibility = shown == 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            searchBox.TextChanged += (_, _) => Apply(searchBox.Text);
            // The flyout content is not loaded yet when it opens, so TextChanged cannot be relied on to reset it.
            reset = () =>
            {
                searchBox.Text = string.Empty;
                Apply(string.Empty);
            };
            var content = new StackPanel { MaxWidth = 280 };
            content.Children.Add(searchBox);
            content.Children.Add(noMatches);
            content.Children.Add(choices);
            return content;
        }

        private static FrameworkElement CreateChoiceContent(string label, DataTemplate? indicatorTemplate)
        {
            var text = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap };
            if (indicatorTemplate is null) return text;
            var content = new Grid { ColumnSpacing = 8 };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.Children.Add((FrameworkElement)indicatorTemplate.LoadContent());
            Grid.SetColumn(text, 1);
            content.Children.Add(text);
            return content;
        }

        private void SetSelected(T value, bool selected)
        {
            if (_syncing || !_selection.SetSelected(value, selected)) return;
            SyncChecks();
            _changed();
        }

        private void SetAnyKnown(bool selected)
        {
            if (_syncing || !_selection.SetAnyKnown(selected)) return;
            SyncChecks();
            _changed();
        }

        internal void Toggle(T value)
        {
            _selection.SetSelected(value, !Selected.Contains(value));
            SyncChecks();
        }

        internal void SelectOnly(IEnumerable<T> values)
        {
            _selection.SelectOnly(values);
            SyncChecks();
        }

        internal void Clear()
        {
            _selection.Clear();
            SyncChecks();
        }

        private void SyncChecks()
        {
            _syncing = true;
            try
            {
                foreach (var (value, check) in _checks) check.IsChecked = Selected.Contains(value);
                if (_anyCheck is not null) _anyCheck.IsChecked = AnyKnown;
            }
            finally { _syncing = false; }
            UpdateLabel();
        }

        private void UpdateLabel()
        {
            var labels = _selection.Choices.Where(choice => Selected.Contains(choice.Value)).Select(choice => choice.Label);
            var summary = AnyKnown ? _anySummary : Selected.Count == 0 ? "All" : string.Join(", ", labels);
            var text = _selection.HasRestriction ? $"{_displayCategory} | {summary}" : _displayCategory;
            _button.Content = _view.CreateFilterLabel(_button, text, _selection.HasRestriction, SelectedIndicators());
            AutomationProperties.SetName(_button, $"{_category}: {summary}");
            AutomationProperties.SetHelpText(_button, AnyKnown ? _anyDescription ?? string.Empty : string.Empty);
            ToolTipService.SetToolTip(_button, AnyKnown ? $"{_category}: {_anyDescription}" : $"{_category}: {summary}");
        }

        private IReadOnlyList<DataTemplate> SelectedIndicators()
        {
            if (AnyKnown) return _anyIndicatorTemplate is null ? [] : [_anyIndicatorTemplate];
            if (_indicatorTemplate is null) return [];
            return _selection.Choices.Where(choice => Selected.Contains(choice.Value))
                .Select(choice => _indicatorTemplate(choice.Value)).ToArray();
        }
    }

    private void SortHeader_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string column })
        {
            SortRequested?.Invoke(this, column);
        }
    }

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ScanResultRow row)
        {
            DeviceRequested?.Invoke(this, row);
        }
    }

    private void ResultsList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Left) ||
            FocusManager.GetFocusedElement(XamlRoot) is not DependencyObject focused ||
            FindAncestor<ListViewItem>(focused) is not { } container ||
            ResultsList.ItemFromContainer(container) is not ScanResultRow row ||
            !row.CanToggleMacAddresses)
        {
            return;
        }

        SetMacRowExpanded(row, e.Key == Windows.System.VirtualKey.Right);
        UpdateRowAutomation(container, row);
        container.Focus(FocusState.Programmatic);
        e.Handled = true;
    }

    private void DeviceMacExpansionButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ScanResultRow row } element)
        {
            SetMacRowExpanded(row, !row.AreMacAddressesExpanded);
            if (FindAncestor<ListViewItem>(element) is { } container)
                UpdateRowAutomation(container, row);
        }
    }

    private void SetMacRowExpanded(ScanResultRow row, bool expanded)
    {
        if (!row.HasEarlierMacAddresses) return;
        if (expanded) _expandedMacRows.Add(row.IdentityKey);
        else _expandedMacRows.Remove(row.IdentityKey);
        row.SetMacExpansionState(expanded, SearchText);
    }

    private static void UpdateRowAutomation(ListViewItem container, ScanResultRow row)
    {
        AutomationProperties.SetHelpText(container, FullRowValues(row));
        AutomationProperties.SetItemStatus(container, row.MacExpansionState);
    }

    private void DeviceMatchButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ScanResultRow row })
            MatchSuggestionRequested?.Invoke(this, row);
    }

    private void ServiceDiscoveryButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ScanResultRow row })
            ServiceDiscoveryRequested?.Invoke(this, row);
    }

}
