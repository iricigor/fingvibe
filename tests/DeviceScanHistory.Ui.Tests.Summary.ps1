# Summary helpers: Last seen cells and history summary assertions.
function Get-HistoryLastSeenCell([string] $Name, [switch] $Rendered) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceLastSeenText")
    $cell = (Find-HistoryDeviceRow $Name).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $cell) { throw "Devices row '$Name' lacks a Last seen value." }
    if ($Rendered) {
        return $cell.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
    }
    return $cell.Current.Name
}

function Assert-HistoryLastSeenCell([string] $Name, [string] $Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $actual = Get-HistoryLastSeenCell $Name
        if ($actual -like $Expected) { return $actual }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Devices Last seen for '$Name' is '$actual', expected '$Expected'."
}

# Visible text is a compact relative age; a clock earlier than the fixture shows its local time instead.
function Assert-HistoryLastSeenAge([string] $Name, [int] $Index) {
    $rendered = Get-HistoryLastSeenCell $Name -Rendered
    $local = (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
    if ($rendered -cnotmatch '^(< 1 min\. ago|\d+ min\. ago|\d+ h ago|\d+ (day|month|year)s? ago)$' -and $rendered -cne $local) {
        throw "Devices Last seen for '$Name' must render a relative age, not '$rendered'."
    }
}

function Get-HistoryExactTime([int] $Index) {
    return (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm:ss zzz", [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-HistorySummary([string] $Capture, [int] $LastIndex = 4) {
    $lastSeen = @(0, 1, 1, 1, 4)[$LastIndex]
    $since = @(0, 0, 2, 2, 4)[$LastIndex]
    $state = if ($LastIndex -in @(2, 3)) { "offline" } else { "online" }
    $expected = @{
        DeviceHistorySummaryScope = "Current network: ui-review-network | 127.0.0.1/32"
        DeviceHistoryFirstSeen = "First seen: $(Get-FriendlyHistoryTime (Get-HistoryLocalTime 0))"
        DeviceHistoryLastSeen = "Last seen: $(Get-FriendlyHistoryTime (Get-HistoryLocalTime $lastSeen))"
        DeviceHistorySince = "Latest recorded $(if ($state -eq 'online') { 'responding' } else { 'nonresponding' }) run started: $(Get-HistoryTimestamp $since)"
        DeviceHistoryState = "Last recorded state: $(if ($state -eq 'online') { 'Responded' } else { 'Scanned, no response' })"
    }
    if (-not $SummaryOnly) {
        $expected.DeviceHistoryScope = $expected.DeviceHistorySummaryScope
        $expected.DeviceHistoryLatest = "Latest recorded scan: $(Get-HistoryTimestamp $LastIndex). Saved observations do not establish current live presence."
    }
    foreach ($id in $expected.Keys) {
        $actual = (Find-HistoryControl $id).Current.Name
        if ($actual -ne $expected[$id]) { throw "Incorrect summary $id : '$actual', expected '$($expected[$id])'." }
    }
    $expansion = $null
    if (-not $SummaryOnly) {
        $expansion = (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expansion.Collapse()
    }
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        $element = Show-HistorySection $id
        $area = (Find-HistoryControl DeviceDetailsScroll).Current.BoundingRectangle
        $bounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $bounds.Top -lt $area.Top -or $bounds.Bottom -gt $area.Bottom) {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-clipped.png")
            throw "Summary field $id is clipped: bounds=$bounds; viewport=$area."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-summary.png")
    if ($expansion) {
        # The expander lives on the History tab, so re-resolve it after the Overview summary was shown.
        (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    }
}
