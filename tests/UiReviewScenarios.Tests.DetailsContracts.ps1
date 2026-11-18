# Page contracts: Device details layout and history test wiring.
& {
    [xml] $page = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml") -Raw
    $namespaces = [System.Xml.XmlNamespaceManager]::new($page.NameTable)
    $namespaces.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")
    $history = $page.SelectSingleNode("//*[@x:Name='DeviceScanHistoryExpander']", $namespaces)
    Assert-Equal $history.IsExpanded "True" "Completed observations starts expanded"
    Assert-Equal $history.Header "Completed Scan Observations" "Completed observations header"
    Assert-Equal $history.GetAttribute("Visibility") "" "Completed observations uses visible layout"
    if (-not $history.SelectSingleNode(".//*[local-name()='ScrollViewer' and @x:Name='DeviceScanHistoryList']/*[local-name()='ItemsControl' and @x:Name='DeviceScanHistoryRows']", $namespaces)) {
        throw "The bounded observation page must keep stable, non-recycled rows."
    }
    Assert-Equal $history.SelectSingleNode(".//*[@x:Name='DeviceScanHistoryList']", $namespaces).IsTabStop "True" "The observation viewport must be reachable by keyboard focus"
    $activity = $page.SelectSingleNode("//*[@x:Name='DeviceActivityCard']", $namespaces)
    Assert-Equal $activity.GetAttribute("Visibility") "" "Restored Activity uses normal visible layout"
    foreach ($id in @("DeviceScanHistoryTable", "DeviceScanHistoryEmpty",
        "DeviceHistoryNewer", "DeviceHistoryOlder", "DeviceHistoryPageStatus")) {
        if (-not $history.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be inside completed observations." }
    }
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistoryState", "DeviceHistorySince",
        "DeviceHistoryScope", "DeviceHistoryLatest")) {
        if (-not $page.SelectSingleNode("//*[@x:Name='$id']", $namespaces)) { throw "Retained summary lacks $id." }
        if ($history.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must remain outside collapsed observations." }
    }
    # The history entry and its dot-sourced modules, in load order.
    $historyFiles = @("DeviceScanHistory.Ui.Tests.ps1", "DeviceScanHistory.Ui.Tests.Shared.ps1", "DeviceScanHistory.Ui.Tests.Summary.ps1",
        "DeviceScanHistory.Ui.Tests.Observations.ps1", "DeviceScanHistory.Ui.Tests.FixturePhase.ps1",
        "DeviceScanHistory.Ui.Tests.StatePhases.ps1", "DeviceScanHistory.Ui.Tests.PagingPhase.ps1")
    $historyUi = ($historyFiles | ForEach-Object { Get-Content (Join-Path $PSScriptRoot $_) -Raw }) -join "`n"
    $tabs = $page.SelectSingleNode("//*[@x:Name='DetailsTabs']", $namespaces)
    Assert-Equal $tabs.LocalName "SelectorBar" "Device Details uses local section tabs"
    Assert-Equal (@($tabs.ChildNodes | ForEach-Object { $_.Text }) -join "|") "Overview|History" "Device Details tab order"
    Assert-Equal $tabs.FirstChild.IsSelected "True" "Overview is the initial tab"
    $overviewPanel = $page.SelectSingleNode("//*[@x:Name='OverviewPanel']", $namespaces)
    $historyPanel = $page.SelectSingleNode("//*[@x:Name='HistoryPanel']", $namespaces)
    Assert-Equal $historyPanel.Visibility "Collapsed" "History starts hidden"
    foreach ($id in @("DetailsColumns", "IdentificationCard", "PortsServicesCard", "DeviceHistorySummaryCard",
        "DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistoryState", "DeviceHistorySince", "DeviceViewHistory")) {
        if (-not $overviewPanel.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be on the Overview tab." }
    }
    foreach ($id in @("DeviceActivityCard", "DeviceHistoryScope", "DeviceHistoryLatest", "DeviceScanHistoryExpander", "VirtualDeviceHistoryCard")) {
        if (-not $historyPanel.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be on the History tab." }
    }
    $header = $page.SelectSingleNode("//*[@x:Name='HeaderGrid']", $namespaces)
    if (-not $header.SelectSingleNode(".//*[@x:Name='DetailsTabs']", $namespaces) -or
        -not $header.SelectSingleNode(".//*[@x:Name='DeviceNameValue']", $namespaces) -or
        -not $header.SelectSingleNode(".//*[@x:Name='DeviceBackButton']", $namespaces)) {
        throw "Back, segmented tabs and identity must share the responsive details header."
    }
    $deviceBack = $header.SelectSingleNode(".//*[@x:Name='DeviceBackButton']", $namespaces)
    Assert-Equal $deviceBack.GetAttribute("AutomationProperties.AutomationId") "DeviceBackButton" "Device Details Back is stable for Room map return"
    $columns = $page.SelectSingleNode("//*[@x:Name='DetailsColumns']", $namespaces)
    foreach ($id in @("NetworkOverviewCard", "AssignmentsCard", "DeviceHistorySummaryCard", "UsageCategoryCard")) {
        if (-not $columns.SelectSingleNode("./*[@x:Name='$id']", $namespaces)) {
            throw "$id must share the two-row aligned summary grid."
        }
    }
    $detailsCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml.cs") -Raw
    $roomDetailsCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\RoomDetailsPageView.xaml.cs") -Raw
    if ($detailsCode -notmatch 'SetBackDestination\(bool roomMap\)' -or
        $detailsCode -notmatch 'Back to Room map' -or
        $roomDetailsCode -notmatch 'SetBackDestination\(bool roomMap\)' -or
        $roomDetailsCode -notmatch 'Back to Room map') {
        throw "Device and Room Details must expose source-aware Back labels and accessible names for Room map returns."
    }
    if ($detailsCode -notmatch '(?s)internal void ShowDevice\(.*?DetailsTabs\.SelectedItem = OverviewTab;') {
        throw "Opening a device must reset Device Details to Overview."
    }
    if ($historyUi -notmatch 'Test-HistoryTabs' -or $historyUi -notmatch 'DeviceOverviewTab') {
        throw "Native history checks must cover tab switching, retained drafts and the initial Overview tab."
    }
    if ($historyUi -notmatch '\$env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"') {
        throw "History fixtures must select their own network independently of preceding suites."
    }
    $summaryAssertion = [regex]::Match((Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Summary.ps1") -Raw),
        '(?s)function Assert-HistorySummary.*').Value
    if ($summaryAssertion -notmatch 'Show-HistorySection \$id' -or
        $summaryAssertion -match 'DeviceHistorySummaryCard') {
        throw "Summary checks must position disclosed text peers individually, not a Border without an automation peer."
    }
    $code = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml.cs") -Raw
    foreach ($pattern in @(
        'internal static bool CompletedObservationsEnabled => true;',
        '(?m)^        InitializeActivity\(\);',
        '(?s)if \(CompletedObservationsEnabled\)\s*\{\s*ApplyHistoryPage\(DeviceHistoryQuery.ReadPage',
        '(?s)HistoryPage_Click.*?\{\s*if \(!CompletedObservationsEnabled\) return;'
    )) {
        if ($code -notmatch $pattern) { throw "Missing reversible history lifecycle guard: $pattern" }
    }
    $itemCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceScanHistoryItem.cs") -Raw
    if ($itemCode -notmatch 'AutomationControlType.DataItem' -or $itemCode -notmatch 'IScrollItemProvider' -or
        $itemCode -notmatch 'owner.StartBringIntoView') {
        throw "Passive observation rows must retain accessible data-item and bring-into-view support."
    }
    $activityCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.Activity.cs") -Raw
    if ($activityCode -match 'HistoryDetailsEnabled|CompletedObservationsEnabled' -or
        $code -match 'DeviceActivityCard.Visibility') {
        throw "Activity must remain independent of completed observations."
    }
    foreach ($historyFile in $historyFiles) {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $historyFile), [ref]$null, [ref]$errors)
        if ($errors) { throw ($errors.Message -join "; ") }
    }
    $imported = $page.SelectSingleNode("//*[@x:Name='DeviceImportedMetadata']", $namespaces)
    Assert-Equal $imported.IsExpanded "False" "Imported metadata starts collapsed"
    Assert-Equal $imported.PreviousSibling.Header "How this device was identified" "Imported data immediately follows identification evidence"
    if ($imported.ParentNode.ParentNode.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") -ne "IdentificationCard") {
        throw "Imported metadata must belong to Device identification."
    }
}
