$UiReviewScenarios = [ordered]@{
    Devices = @{ Label = "Devices - online results"; FileName = "fingvibe-ui-review.png"; Page = "DevicesPage" }
    Overview = @{ Label = "Overview - scan summary"; FileName = "fingvibe-overview.png"; Page = "OverviewPage" }
    Network = @{ Label = "Network - network details"; FileName = "fingvibe-network.png"; Page = "NetworkPage" }
    DeviceDetails = @{ Label = "Device details - selected online device"; FileName = "fingvibe-device-details.png"; Page = "DevicePage" }
    DeviceHistory = @{ Label = "Device details - History tab"; FileName = "fingvibe-device-history.png"; Page = "DevicePage" }
    People = @{ Label = "People"; FileName = "fingvibe-people.png"; Page = "PeopleRoomsPage" }
    PersonDetails = @{ Label = "Person details"; FileName = "fingvibe-person-details.png"; Page = "PersonDetailPage" }
    Rooms = @{ Label = "Rooms"; FileName = "fingvibe-rooms.png"; Page = "PeopleRoomsPage" }
    RoomMap = @{ Label = "Room map - saved rooms and devices"; FileName = "fingvibe-room-map.png"; Page = "RoomMapPage" }
    Tools = @{ Label = "Tools"; FileName = "fingvibe-tools.png"; Page = "ToolsPage" }
    SpeedTest = @{ Label = "Speed test"; FileName = "fingvibe-speed-test.png"; Page = "ToolsPage" }
    NetworkHealth = @{ Label = "Network health"; FileName = "fingvibe-network-health.png"; Page = "ToolsPage" }
    ServiceStatus = @{ Label = "Service status - controlled provider reports"; FileName = "fingvibe-service-status.png"; Page = "ToolsPage" }
    About = @{ Label = "About FingVibe"; FileName = "fingvibe-about.png"; Page = "SettingsPage" }
    FingImport = @{ Label = "Import from Fing - synthetic analysis"; FileName = "fingvibe-fing-import.png"; Page = "ToolsPage" }
    SqlEditor = @{ Label = "SQL editor - read-only query and schema"; FileName = "fingvibe-sql-editor.png"; Page = "ToolsPage" }
    DatabaseBackups = @{ Label = "Database backups - local protection"; FileName = "fingvibe-database-backups.png"; Page = "ToolsPage" }
    RoomDetails = @{ Label = "Room details"; FileName = "fingvibe-room-details.png"; Page = "RoomDetailPage" }
    Settings = @{ Label = "Settings - appearance and columns"; FileName = "fingvibe-settings.png"; Page = "SettingsPage" }
    DevicesEmpty = @{ Label = "Devices - no matching hosts"; FileName = "fingvibe-devices-empty.png"; Page = "DevicesPage" }
}

function Invoke-UiReviewGit {
    param([string] $RepositoryPath, [string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    return $output
}

function Get-UiReviewCapturePlan {
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [string] $BaseRevision,
        [string] $HeadRevision = "HEAD",
        [string[]] $AdditionalScenarios = @()
    )

    $reasons = @{}
    $reasons.Devices = [System.Collections.Generic.List[string]]::new()
    $reasons.Devices.Add("Baseline after Scan LAN and filter smoke tests.")

    function Add-Scenarios([string[]] $Names, [string] $Reason) {
        foreach ($name in $Names) {
            if (-not $UiReviewScenarios.Contains($name)) {
                throw "Unknown UI capture scenario '$name'. Supported: $($UiReviewScenarios.Keys -join ', ')."
            }
            if (-not $reasons.ContainsKey($name)) {
                $reasons[$name] = [System.Collections.Generic.List[string]]::new()
            }
            if (-not $reasons[$name].Contains($Reason)) { $reasons[$name].Add($Reason) }
        }
    }

    if ($BaseRevision) {
        $mergeBase = Invoke-UiReviewGit $RepositoryPath @("merge-base", $BaseRevision, $HeadRevision)
        $paths = Invoke-UiReviewGit $RepositoryPath @("diff", "--name-only", "--no-renames", "$mergeBase", $HeadRevision, "--")
        foreach ($path in $paths) {
            if ($path -eq "src/FingVibe.App/MainWindow.xaml") {
                $documents = @()
                foreach ($revision in @($mergeBase, $HeadRevision)) {
                    $isHead = $documents.Count -eq 1
                    $document = [System.Xml.XmlDocument]::new()
                    $document.LoadXml((Invoke-UiReviewGit $RepositoryPath @("show", "${revision}:$path")) -join "`n")
                    foreach ($comment in @($document.SelectNodes("//comment()"))) {
                        $null = $comment.ParentNode.RemoveChild($comment)
                    }
                    foreach ($node in $document.SelectNodes("//*[@*[local-name()='Name']]")) {
                        $name = $node.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
                        # Pages removed by the change need no capture; the remaining base node selects the shared layout.
                        if ($isHead -and $name -like "*Page" -and $name -notin $UiReviewScenarios.Values.Page) {
                            throw "Page '$name' has no capture scenario. Extend the scenario catalog, selection, navigation, and tests."
                        }
                    }
                    $documents += $document
                }
                foreach ($scenario in $UiReviewScenarios.Keys) {
                    $page = $UiReviewScenarios[$scenario].Page
                    $query = "//*[@*[local-name()='Name' and namespace-uri()='http://schemas.microsoft.com/winfx/2006/xaml']='$page']"
                    $before = $documents[0].SelectSingleNode($query)
                    $after = $documents[1].SelectSingleNode($query)
                    if ($before.OuterXml -cne $after.OuterXml) {
                        Add-Scenarios @($scenario) "$path changed $page."
                    }
                }
                foreach ($document in $documents) {
                    foreach ($page in ($UiReviewScenarios.Values.Page | Select-Object -Unique)) {
                        $node = $document.SelectSingleNode("//*[@*[local-name()='Name']='$page']")
                        if ($node) { $null = $node.ParentNode.RemoveChild($node) }
                    }
                    foreach ($node in @($document.SelectNodes("//*[local-name()='NavigationView.MenuItems' or local-name()='NavigationView.FooterMenuItems' or local-name()='NavigationView.PaneHeader' or local-name()='NavigationView.PaneFooter']"))) {
                        $null = $node.ParentNode.RemoveChild($node)
                    }
                    foreach ($node in $document.SelectNodes("//*[not(node())]")) {
                        $node.IsEmpty = $true
                    }
                }
                if ($documents[0].OuterXml -cne $documents[1].OuterXml) {
                    Add-Scenarios @($UiReviewScenarios.Keys) "$path changed shared window layout."
                }
            }
            elseif ($path -in @('src/FingVibe.App/PageHeaderSizing.cs', 'tests/PageHeaders.Ui.Helpers.ps1')) {
                Add-Scenarios @("DeviceDetails", "DeviceHistory", "SpeedTest", "NetworkHealth",
                    "About", "FingImport", "SqlEditor", "DatabaseBackups", "Settings") "$path changed Back headers."
            }
            elseif ($path -match '^src/FingVibe.App/Views/([^/]+)\.xaml(\.cs)?$') {
                $viewScenarios = @{
                    OverviewPageView = @("Overview")
                    NetworkPageView = @("Network", "NetworkHealth")
                    DevicesPageView = @("Devices", "DevicesEmpty", "Settings")
                    DeviceDetailsPageView = @("DeviceDetails", "DeviceHistory")
                    PeopleRoomsPageView = @("People", "Rooms", "PersonDetails", "RoomDetails", "DeviceDetails", "RoomMap")
                    PersonDetailsPageView = @("PersonDetails", "People", "DeviceDetails")
                    RoomDetailsPageView = @("RoomDetails", "Rooms", "DeviceDetails")
                    RoomMapPageView = @("RoomMap", "DeviceDetails", "RoomDetails")
                    SettingsPageView = @($UiReviewScenarios.Keys)
                }
                $view = $Matches[1]
                if (-not $viewScenarios.ContainsKey($view)) {
                    throw "View '$path' has no selection rule. Extend the scenario catalog, selection, navigation, and tests."
                }
                Add-Scenarios $viewScenarios[$view] "$path changed page layout or behavior."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.UsageCategories.cs|UsageCategoryPresentation.cs|Views/DeviceDetailsPageView.Usage.cs)$' -or
                $path -eq 'src/FingVibe.Core/Models/DeviceUsageCategory.cs' -or $path -eq 'tests/UsageCategory.Ui.Tests.ps1') {
                Add-Scenarios @("Devices", "DeviceDetails", "Settings") "$path changed usage classification or editing."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.LinkedDevices.cs|LinkedDevicePresentation.cs)$' -or
                $path -eq 'src/FingVibe.Core/Models/LinkedDevice.cs' -or $path -eq 'tests/DeviceLinking.Ui.Tests.ps1') {
                Add-Scenarios @("Devices", "DeviceDetails") "$path changed linking device records."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.DeviceDetails.cs|DeviceDetailsPresentation.cs|Views/Device(DetailValue|ScanHistoryItem).cs)$') {
                Add-Scenarios @("DeviceDetails", "DeviceHistory") "$path changed device details behavior."
            }
            elseif ($path -match '^src/FingVibe.App/(Views/ActivityGridRenderer.cs|DeviceActivityPresentation.cs|DeviceActivityReviewHold.cs)$' -or
                $path -eq 'src/FingVibe.Core/Models/DeviceActivity.cs' -or $path -eq 'tests/ActivityGrid.Ui.Helpers.ps1') {
                Add-Scenarios @("Network", "DeviceHistory", "PersonDetails") "$path changed shared activity grid behavior."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.EquipmentActivity.cs|EquipmentActivityPresentation.cs|Views/PersonDetailsPageView.Activity.cs)$' -or
                $path -eq 'src/FingVibe.Core/Models/EquipmentActivity.cs' -or $path -eq 'tests/EquipmentActivity.Ui.Tests.ps1') {
                Add-Scenarios @("PersonDetails") "$path changed equipment evidence, assignments or its grid."
            }
            elseif ($path -eq 'src/FingVibe.App/NetworkActivityPresentation.cs' -or
                $path -eq 'src/FingVibe.Core/Models/NetworkActivity.cs' -or $path -eq 'tests/NetworkActivity.Fixture.ps1') {
                Add-Scenarios @("Network", "PersonDetails") "$path changed shared network/equipment counts or fixtures."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.NetworkActivity.cs|Views/NetworkPageView.Activity.cs)$' -or
                $path -eq 'tests/NetworkActivity.Ui.Tests.ps1') {
                Add-Scenarios @("Network") "$path changed Network activity evidence, filters or its grid."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.DeviceActivity.cs|Views/DeviceDetailsPageView.Activity.cs)$' -or
                $path -match '^tests/DeviceActivity\.(Ui.Tests|Fixture)\.ps1$') {
                Add-Scenarios @("DeviceHistory") "$path changed device activity evidence or its grid."
            }
            # Shared contracts select every current consumer surface so details-* jobs dispatch their native checks.
            elseif ($path -eq 'src/FingVibe.App/AsyncSurfaceSession.cs') {
                Add-Scenarios @("DeviceDetails", "DeviceHistory", "Network", "PersonDetails", "Tools", "NetworkHealth", "DatabaseBackups") `
                    "$path changed the shared asynchronous surface lifecycle (device history/activity, discovery activation, network and equipment activity, Network health diagnostics, backups)."
            }
            elseif ($path -eq 'src/FingVibe.App/ScanResultRow.cs') {
                Add-Scenarios @("Devices", "DevicesEmpty", "Settings", "Overview", "Network", "DeviceDetails", "DeviceHistory",
                    "People", "PersonDetails", "Rooms", "RoomDetails", "RoomMap") `
                    "$path changed the shared device row (results, overview, details, discovery, people/rooms, equipment and network activity)."
            }
            elseif ($path -eq 'src/FingVibe.Core/Models/RoomMapLayout.cs' -or
                $path -match '^src/FingVibe.App/(MainWindow.RoomMap|Views/RoomMapPageView)\.cs$') {
                $roomMapScenarios = @("RoomMap")
                if ($path -match '^src/FingVibe.App/') {
                    $roomMapScenarios += @("DeviceDetails", "RoomDetails")
                }
                Add-Scenarios $roomMapScenarios "$path changed Room map projection, layout, routing, rendering or return navigation."
            }
            elseif ($path -eq 'src/FingVibe.Core/Storage/DeviceInventoryStore.Analytics.cs') {
                Add-Scenarios @("DeviceDetails", "DeviceHistory", "Network", "PersonDetails", "Settings") `
                    "$path changed shared analytics evidence (device, network and equipment activity, usage classification)."
            }
            elseif ($path -match '^src/FingVibe.Core/(Models/(DeviceInventory|PrivateVirtualDevice|DeviceHistorySummary|DeviceHistoryQuery|DeviceDiscovery|AppendedScanHistory).cs|Storage/(DeviceInventoryStore(\.(Json|History))?|SqliteScanHistory).cs)$' -or
                $path -match '^src/FingVibe.App/MainWindow.(Snapshots|DiscoveryNotifications|Scan).cs$' -or
                $path -match '^src/FingVibe.App/(DiscoveryPopup.xaml(\.cs)?|DiscoveryNotification(Presentation|Store).cs|WindowsDiscoveryNotifications.cs|Assets/DiscoveryCaution.png)$' -or
                $path -match '^tests/(Device(ScanHistory|Discovery).Ui.Tests|DeviceScanHistory.Ui.Tests.[A-Za-z]+|Inventory.Sqlite.Helpers).ps1$') {
                Add-Scenarios @("DeviceDetails", "DeviceHistory") "$path changed persisted device scan history."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.NetworkIdentity.cs") {
                Add-Scenarios @("Overview", "Network", "NetworkHealth", "DeviceDetails", "PersonDetails", "RoomMap") "$path changed network identity."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.Results.cs|DeviceResult(Filter|Sort).cs|StatusFilter.*|DeviceColumn.*|ColumnResizeGrip.cs)$') {
                Add-Scenarios @("Devices", "DevicesEmpty", "Settings") "$path changed results, filtering, or table controls."
            }
            elseif ($path -match '^src/FingVibe.App/.+Page\.xaml$' -and
                [System.IO.Path]::GetFileName($path) -notin @("ToolsPage.xaml", "SpeedTestPage.xaml", "AboutPage.xaml", "NetworkHealthPage.xaml", "NetworkTroubleshootingPage.xaml", "ServiceStatusPage.xaml", "FingImportPage.xaml", "SqlEditorPage.xaml", "DatabaseBackupsPage.xaml")) {
                throw "View '$path' has no selection rule. Extend the scenario catalog, selection, navigation, and tests."
            }
            elseif ($path -match '^src/FingVibe.App/(Tools/AboutPage(\.Updates\.cs|\.xaml(\.cs)?)|MainWindow\.Updates\.cs|Updates/.+\.cs)$' -or
                $path -match '^src/FingVibe.Core/Updates/' -or $path -eq 'tests/ReleaseUpdates.Ui.Tests.ps1') {
                Add-Scenarios @("Settings", "About") "$path changed About FingVibe."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/FingImportPage\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "FingImport") "$path changed Fing import."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/SqlEditorPage\.xaml(\.cs)?$' -or
                $path -match '^src/FingVibe.Core/Storage/Inventory(QueryService|ReportingSchema).cs$' -or
                $path -eq 'tests/SqlEditor.Ui.Tests.ps1') {
                Add-Scenarios @("Tools", "SqlEditor") "$path changed SQL reporting."
            }
            elseif ($path -match '^src/FingVibe.App/(Tools/DatabaseBackupsPage\.xaml(\.cs)?|MainWindow.Backups.cs|InventoryBackupScheduler.cs)$' -or
                $path -eq 'src/FingVibe.Core/Storage/InventoryBackupStore.cs' -or
                $path -eq 'tests/DatabaseBackups.Ui.Tests.ps1') {
                Add-Scenarios @("Tools", "DatabaseBackups") "$path changed database backup behavior."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.Inventory.cs") {
                Add-Scenarios @("Devices", "Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails", "FingImport", "SqlEditor", "RoomMap") "$path changed inventory orchestration."
            }
            # NetworkTroubleshootingPage is the pre-rename path; --no-renames diffs report it as deleted.
            elseif ($path -match '^src/FingVibe.App/Tools/Network(Health|Troubleshooting)Page\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "NetworkHealth", "RoomMap") "$path changed Network health."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/ServiceStatusPage\.xaml(\.cs)?$' -or
                $path -match '^src/FingVibe.Core/Networking/ServiceStatus[A-Za-z]*\.cs$') {
                Add-Scenarios @("Tools", "NetworkHealth", "ServiceStatus") "$path changed Service status."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/ToolsPage\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "SpeedTest", "NetworkHealth", "About", "FingImport", "SqlEditor", "DatabaseBackups", "RoomMap") "$path changed the Tools landing page."
            }
            elseif ($path -match '^src/FingVibe.App/(Tools/|Assets/SpeedTest/)') {
                Add-Scenarios @("Tools", "SpeedTest", "NetworkHealth", "About", "FingImport", "SqlEditor", "DatabaseBackups") "$path changed Tools or the speed test."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.PeopleRooms.cs|ManagedPeopleRoomsRows.cs|PeopleRooms(Presentation|Icons).cs|Views/PeopleRooms(Dialogs|IconPicker).cs)$') {
                Add-Scenarios @("People", "PersonDetails", "Rooms", "RoomDetails", "DeviceDetails", "RoomMap") "$path changed people, rooms, or assignments."
            }
            elseif ($path -eq 'src/FingVibe.App/ServiceDiscoveryPresentation.cs' -or
                $path -match '^src/FingVibe.Core/(Models/ServiceAdvertisement|Networking/(MdnsDeviceDiscoveryService|SsdpDiscoveryService|AdvertisedEndpointVerifier|ScanResultEnricher|LanScannerService))\.cs$' -or
                $path -eq 'tests/UiRegression/Devices.ServiceDiscovery.Scenario.ps1') {
                Add-Scenarios @("Devices", "DeviceDetails") "$path changed service-discovery evidence or its presentation."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.Overview.cs|OverviewScanContext.cs)$') {
                Add-Scenarios @("Overview") "$path changed the scan summary."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.DeviceClassification.cs") {
                Add-Scenarios @("DeviceDetails") "$path changed device identification controls."
            }
            elseif ($path -match '^src/FingVibe.App/(App.xaml|AppearancePalette.cs|MainWindow.Appearance.cs)$') {
                Add-Scenarios @($UiReviewScenarios.Keys) "$path changed shared theme or appearance."
            }
            elseif ($path -match '^src/|^\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md)') {
                Add-Scenarios @("Devices") "$path uses the Devices baseline; navigation smoke tests still cover every supported scenario."
            }
        }
    }
    foreach ($scenario in $AdditionalScenarios) {
        Add-Scenarios @($scenario) "Explicitly requested capture scenario."
    }
    foreach ($scenario in $UiReviewScenarios.Keys) {
        if ($reasons.ContainsKey($scenario)) {
            [pscustomobject]@{
                Scenario = $scenario
                Label = $UiReviewScenarios[$scenario].Label
                FileName = $UiReviewScenarios[$scenario].FileName
                Reasons = @($reasons[$scenario].ToArray())
            }
        }
    }
}

function Read-UiReviewCapturePlan {
    param([Parameter(Mandatory)][string] $Path)
    $plan = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    if ($plan.Count -eq 0 -or $plan.Scenario -notcontains "Devices") {
        throw "The capture plan must include the Devices baseline."
    }
    $seen = @{}
    foreach ($capture in $plan) {
        if (-not $UiReviewScenarios.Contains([string] $capture.Scenario) -or $seen.ContainsKey($capture.Scenario)) {
            throw "Unknown or duplicate capture scenario '$($capture.Scenario)'."
        }
        $definition = $UiReviewScenarios[$capture.Scenario]
        if ($capture.FileName -cne $definition.FileName -or $capture.Label -cne $definition.Label -or
            @($capture.Reasons).Count -eq 0 -or [string]::IsNullOrWhiteSpace(($capture.Reasons -join ""))) {
            throw "Invalid capture definition for '$($capture.Scenario)'."
        }
        $seen[$capture.Scenario] = $true
    }
    return $plan
}
