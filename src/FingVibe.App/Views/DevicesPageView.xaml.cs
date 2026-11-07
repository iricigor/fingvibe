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
    private readonly DeviceLastSeenAgeRefresh _lastSeenAges;
    private IEnumerable<ScanResultRow> _results = [];

    public DevicesPageView()
    {
        InitializeComponent();
        InitializeCellPreviews();
        _lastSeenAges = new(() => _results, RefreshLastSeenAgesOnUi);
        Loaded += (_, _) => UpdateLastSeenAgeRefresh();
        Unloaded += (_, _) => _lastSeenAges.SetActive(false);
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => UpdateLastSeenAgeRefresh());
        _statuses = new(InventoryStatusFilter, "Status", OnFiltersChanged);
        _types = new(TypeFilter, "Device type", OnFiltersChanged);
        _operatingSystems = new(OperatingSystemFilter, "Operating system", OnFiltersChanged);
        _vendors = new(VendorFilter, "Vendor", OnFiltersChanged, StringComparer.OrdinalIgnoreCase);
        _people = new(PersonFilter, "Person", OnFiltersChanged);
        _rooms = new(RoomFilter, "Room", OnFiltersChanged);
        _statuses.SetChoices([
            (InventoryDeviceStatus.Online, "Online"), (InventoryDeviceStatus.Offline, "Offline"),
            (InventoryDeviceStatus.Unknown, "Unknown"), (InventoryDeviceStatus.FingOnly, "Fing Only")]);
        _types.SetChoices(Enum.GetValues<DeviceType>().Select(value => (value, value.Label())));
        _operatingSystems.SetChoices(Enum.GetValues<DeviceOperatingSystem>().Select(value => (value, value.Label())));
        _people.SetChoices([(null, "Unassigned")]);
        _rooms.SetChoices([(null, "Unassigned")]);
        _filtersReady = true;
        OnFiltersChanged();
    }

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event EventHandler? FiltersChanged;
    public event EventHandler<string>? SortRequested;
    public event EventHandler<ScanResultRow>? DeviceRequested;

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
        try { _statuses.SelectOnly(statuses); }
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
        Rooms = _rooms.Selected
    };

    internal void SetVendorFilters(IEnumerable<string> vendors) =>
        _vendors.SetChoices(vendors.Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase).Select(value => (value, value)));

    internal void SetResults(IEnumerable<ScanResultRow> results)
    {
        DismissCellPreview();
        if (_results is INotifyCollectionChanged previous) previous.CollectionChanged -= Results_CollectionChanged;
        _results = results;
        if (results is INotifyCollectionChanged current) current.CollectionChanged += Results_CollectionChanged;
        ResultsList.ItemsSource = results;
        _lastSeenAges.RefreshIfActive(results);
    }

    private void Results_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs args)
    {
        if (args.NewItems is { } added) _lastSeenAges.RefreshIfActive(added.OfType<ScanResultRow>());
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

    internal void ShowSort(ResultSortColumn column, bool ascending)
    {
        string Glyph(ResultSortColumn candidate) =>
            column == candidate ? (ascending ? "\u2191" : "\u2193") : string.Empty;

        NameSortGlyph.Text = Glyph(ResultSortColumn.Name);
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

    private void ResultsList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (_previewAnchor is { } anchor && FindAncestor<ListViewItem>(anchor) == args.ItemContainer)
            DismissCellPreview();
        if (args.Item is ScanResultRow row)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(args.ItemContainer, FullRowValues(row));
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

    private void ResultSearchBox_TextChanged(object sender, TextChangedEventArgs e) => OnFiltersChanged();
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
        PortsFilter.Content = new TextBlock
        {
            Text = OpenPortsOnly ? "Ports | With open ports" : "Ports",
            TextTrimming = TextTrimming.CharacterEllipsis
        };
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

    private sealed class MultiSelectFilter<T>
    {
        private readonly DropDownButton _button;
        private readonly string _category;
        private readonly Action _changed;
        private readonly HashSet<T> _selected;
        private List<(T Value, string Label)> _choices = [];
        private readonly List<(T Value, CheckBox CheckBox)> _checks = [];

        internal MultiSelectFilter(DropDownButton button, string category, Action changed,
            IEqualityComparer<T>? comparer = null)
        {
            _button = button;
            _category = category;
            _changed = changed;
            _selected = new(comparer);
            UpdateLabel();
        }

        internal IReadOnlySet<T> Selected => _selected;

        internal void SetChoices(IEnumerable<(T Value, string Label)> values)
        {
            var choices = values.ToList();
            // Retain selected values during inventory/assignment refreshes instead of silently clearing restrictions.
            choices.AddRange(_choices.Where(choice => _selected.Contains(choice.Value)
                && !choices.Any(value => _selected.Comparer.Equals(value.Value, choice.Value))));
            if (_choices.SequenceEqual(choices)) return;
            _choices = choices;
            _checks.Clear();
            var panel = new StackPanel();
            AutomationProperties.SetAutomationId(panel, _button.Name + "Choices");
            AutomationProperties.SetName(panel, _category + " choices");
            AutomationProperties.SetAccessibilityView(panel, AccessibilityView.Content);
            foreach (var (value, label) in choices)
            {
                var check = new CheckBox
                {
                    Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap },
                    IsChecked = _selected.Contains(value),
                    HorizontalAlignment = HorizontalAlignment.Stretch
                };
                AutomationProperties.SetName(check, label);
                check.Checked += (_, _) => SetSelected(value, true);
                check.Unchecked += (_, _) => SetSelected(value, false);
                panel.Children.Add(check);
                _checks.Add((value, check));
            }
            _button.Flyout = new Flyout
            {
                Content = new ScrollViewer
                {
                    MaxHeight = 320,
                    MaxWidth = 280,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Content = panel
                }
            };
            UpdateLabel();
        }

        private void SetSelected(T value, bool selected)
        {
            if (!(selected ? _selected.Add(value) : _selected.Remove(value))) return;
            UpdateLabel();
            _changed();
        }

        internal void Toggle(T value)
        {
            SetSelected(value, !_selected.Contains(value));
            SyncChecks();
        }

        internal void SelectOnly(IEnumerable<T> values)
        {
            _selected.Clear();
            _selected.UnionWith(values);
            SyncChecks();
        }

        internal void Clear()
        {
            _selected.Clear();
            SyncChecks();
        }

        private void SyncChecks()
        {
            foreach (var (value, check) in _checks) check.IsChecked = _selected.Contains(value);
            UpdateLabel();
        }

        private void UpdateLabel()
        {
            var labels = _choices.Where(choice => _selected.Contains(choice.Value)).Select(choice => choice.Label);
            var summary = _selected.Count == 0 ? "All" : string.Join(", ", labels);
            var text = _selected.Count == 0 ? _category : $"{_category} | {summary}";
            _button.Content = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis };
            AutomationProperties.SetName(_button, $"{_category}: {summary}");
            ToolTipService.SetToolTip(_button, $"{_category}: {summary}");
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

}
