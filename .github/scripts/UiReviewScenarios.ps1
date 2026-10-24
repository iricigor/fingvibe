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
                }
                if ($documents[0].OuterXml -cne $documents[1].OuterXml) {
                    Add-Scenarios @($UiReviewScenarios.Keys) "$path changed shared navigation or layout."
                }
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.DeviceDetails.cs") {
                Add-Scenarios @("DeviceDetails") "$path changed device details behavior."
            }
            elseif ($path -eq "src/FingVibe.App/MainWindow.NetworkIdentity.cs") {
                Add-Scenarios @("Overview", "Network") "$path changed network identity."
            }
            elseif ($path -match '^src/FingVibe.App/(MainWindow.Results.cs|StatusFilter.*|DeviceColumn.*|ColumnResizeGrip.cs)$') {
                Add-Scenarios @("Devices", "DevicesEmpty", "Settings") "$path changed results, filtering, or table controls."
            }
            elseif ($path -match '^src/|^\.github/(scripts/.*UiReview.*\.ps1|workflows/ui-ux-review\.yml|agents/ui-ux-reviewer\.agent\.md)$') {
                Add-Scenarios @($UiReviewScenarios.Keys) "$path may affect multiple views; capture all supported scenarios."
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
