$UiReviewScenarios = [ordered]@{
    Devices = @{ Label = "Devices - online results"; FileName = "fingvibe-ui-review.png"; Page = "DevicesPage" }
    Overview = @{ Label = "Overview - scan summary"; FileName = "fingvibe-overview.png"; Page = "OverviewPage" }
    Network = @{ Label = "Network - network details"; FileName = "fingvibe-network.png"; Page = "NetworkPage" }
    DeviceDetails = @{ Label = "Device details - selected online device"; FileName = "fingvibe-device-details.png"; Page = "DevicePage" }
    People = @{ Label = "People"; FileName = "fingvibe-people.png"; Page = "PeoplePage" }
    PersonDetails = @{ Label = "Person details"; FileName = "fingvibe-person-details.png"; Page = "PersonDetailPage" }
    Rooms = @{ Label = "Rooms"; FileName = "fingvibe-rooms.png"; Page = "RoomsPage" }
    Tools = @{ Label = "Tools"; FileName = "fingvibe-tools.png"; Page = "ToolsPage" }
    SpeedTest = @{ Label = "Speed test"; FileName = "fingvibe-speed-test.png"; Page = "ToolsPage" }
    Troubleshooting = @{ Label = "Network troubleshooting"; FileName = "fingvibe-troubleshooting.png"; Page = "ToolsPage" }
    About = @{ Label = "About FingVibe"; FileName = "fingvibe-about.png"; Page = "ToolsPage" }
    FingImport = @{ Label = "Import from Fing - synthetic analysis"; FileName = "fingvibe-fing-import.png"; Page = "ToolsPage" }
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
                    $document = [System.Xml.XmlDocument]::new()
                    $document.LoadXml((Invoke-UiReviewGit $RepositoryPath @("show", "${revision}:$path")) -join "`n")
                    foreach ($comment in @($document.SelectNodes("//comment()"))) {
                        $null = $comment.ParentNode.RemoveChild($comment)
                    }
                    foreach ($node in $document.SelectNodes("//*[@*[local-name()='Name']]")) {
                        $name = $node.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
                        if ($name -like "*Page" -and $name -notin $UiReviewScenarios.Values.Page) {
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
            elseif ($path -match '^src/FingVibe.App/Views/([^/]+)\.xaml(\.cs)?$') {
                $viewScenarios = @{
                    OverviewPageView = @("Overview")
                    NetworkPageView = @("Network")
                    DevicesPageView = @("Devices", "DevicesEmpty", "Settings")
                    DeviceDetailsPageView = @("DeviceDetails")
                    PeoplePageView = @("People", "PersonDetails", "DeviceDetails")
                    RoomsPageView = @("Rooms", "RoomDetails", "DeviceDetails")
                    PersonDetailsPageView = @("PersonDetails", "People", "DeviceDetails")
                    RoomDetailsPageView = @("RoomDetails", "Rooms", "DeviceDetails")
                    SettingsPageView = @($UiReviewScenarios.Keys)
                }
                $view = $Matches[1]
                if (-not $viewScenarios.ContainsKey($view)) {
                    throw "View '$path' has no selection rule. Extend the scenario catalog, selection, navigation, and tests."
                }
                Add-Scenarios $viewScenarios[$view] "$path changed page layout or behavior."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.DeviceDetails.cs") {
                Add-Scenarios @("DeviceDetails") "$path changed device details behavior."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.NetworkIdentity.cs") {
                Add-Scenarios @("Overview", "Network", "Troubleshooting") "$path changed network identity."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.Results.cs|StatusFilter.*|DeviceColumn.*|ColumnResizeGrip.cs)$') {
                Add-Scenarios @("Devices", "DevicesEmpty", "Settings") "$path changed results, filtering, or table controls."
            }
            elseif ($path -match '^src/FingVibe.App/.+Page\.xaml$' -and
                [System.IO.Path]::GetFileName($path) -notin @("ToolsPage.xaml", "SpeedTestPage.xaml", "AboutPage.xaml", "NetworkTroubleshootingPage.xaml", "FingImportPage.xaml")) {
                throw "View '$path' has no selection rule. Extend the scenario catalog, selection, navigation, and tests."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/AboutPage\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "About") "$path changed About FingVibe."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/FingImportPage\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "FingImport") "$path changed Fing import."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.Inventory.cs") {
                Add-Scenarios @("Devices", "Overview", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails", "FingImport") "$path changed inventory orchestration."
            }
            elseif ($path -match '^src/FingVibe.App/Tools/NetworkTroubleshootingPage\.xaml(\.cs)?$') {
                Add-Scenarios @("Tools", "Troubleshooting") "$path changed network troubleshooting."
            }
            elseif ($path -match '^src/FingVibe.App/(Tools/|Assets/SpeedTest/)') {
                Add-Scenarios @("Tools", "SpeedTest", "Troubleshooting", "About", "FingImport") "$path changed Tools or the speed test."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.PeopleRooms.cs|ManagedPeopleRoomsRows.cs|PeopleRoomsIcons.cs|Views/PeopleRoomsIconPicker.cs)$') {
                Add-Scenarios @("People", "PersonDetails", "Rooms", "RoomDetails", "DeviceDetails") "$path changed people, rooms, or assignments."
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
