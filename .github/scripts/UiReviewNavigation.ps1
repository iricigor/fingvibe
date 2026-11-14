function Assert-VisibleUiReviewElement {
    param([string] $Using = "name", [Parameter(Mandatory)][string] $Value)
    $id = Find-WebDriverElement -Using $Using -Value $Value
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
        if ($response.value) { return $id }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $response.value) {
        throw "Required capture control '$Value' is not visible."
    }
}

function Test-UiReviewNavigation {
    foreach ($scenario in $UiReviewScenarios.Keys) {
        Write-Host "Verifying navigation: $scenario"
        Show-UiReviewCaptureScenario -Scenario $scenario
        $null = Assert-VisibleUiReviewElement -Value "Scan LAN"
    }
}

function Get-UiReviewToolsScroll {
    param([Parameter(Mandatory)][string] $Name)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button))
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element) { throw "Missing Tools card '$Name'." }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    while ($element -and $element -ne $root) {
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$pattern) -and
            $pattern.Current.VerticallyScrollable) {
            return $pattern
        }
        $element = $walker.GetParent($element)
    }
    throw "No vertically scrollable container for Tools card '$Name'."
}

function Show-UiReviewToolsCard {
    param([Parameter(Mandatory)][string] $Name)
    $id = Find-WebDriverElement -Using xpath -Value "//Button[@Name='$Name']"
    $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
    if (-not $response.value) {
        $scroll = Get-UiReviewToolsScroll -Name $Name
        for ($percent = 0; $percent -le 100; $percent += 10) {
            $scroll.SetScrollPercent(-1, $percent)
            Start-Sleep -Milliseconds 100
            $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
            if ($response.value) { break }
        }
    }
    return Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='$Name']"
}

function Get-UiReviewDetailsScroll {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceDetailsScroll")
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element) { throw "Missing the device details scroll viewer." }
    return $element.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
}

function Show-UiReviewDetailsTop {
    $scroll = Get-UiReviewDetailsScroll
    if ($scroll.Current.VerticallyScrollable) {
        $scroll.SetScrollPercent(-1, 0)
        Start-Sleep -Milliseconds 100
    }
}

function Show-UiReviewDetailsControl {
    param([string] $Using = "name", [Parameter(Mandatory)][string] $Value)
    $id = Find-WebDriverElement -Using $Using -Value $Value
    $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
    if (-not $response.value) {
        $scroll = Get-UiReviewDetailsScroll
        if ($scroll.Current.VerticallyScrollable) {
            for ($percent = 0; $percent -le 100; $percent += 10) {
                $scroll.SetScrollPercent(-1, $percent)
                Start-Sleep -Milliseconds 100
                $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
                if ($response.value) { break }
            }
        }
    }
    return Assert-VisibleUiReviewElement -Using $Using -Value $Value
}

function Show-UiReviewPersonAssignments {
    param([switch] $Top)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $page = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "PersonDetailPage"))
    if (-not $page) { throw "Missing Person details viewport." }
    if ($Top) {
        $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        return
    }
    $button = $page.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "AssignPersonDevicesButton"))
    if (-not $button) { throw "Missing Person assignment action." }
    $button.SetFocus()
    $item = $null
    if ($button.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$item)) { $item.ScrollIntoView() }
}

function Show-UiReviewCaptureScenario {
    param([Parameter(Mandatory)][string] $Scenario)
    $menu = switch ($Scenario) {
        "DeviceDetails" { "Devices" }
        "DeviceHistory" { "Devices" }
        "DevicesEmpty" { "Devices" }
        "SpeedTest" { "Tools" }
        "Troubleshooting" { "Tools" }
        "About" { "Tools" }
        "FingImport" { "Tools" }
        "SqlEditor" { "Tools" }
        "DatabaseBackups" { "Tools" }
        "PersonDetails" { "People" }
        "RoomDetails" { "Rooms" }
        default { $Scenario }
    }
    if ($menu -eq "Tools") {
        Show-UiReviewCaptureScenario -Scenario "Overview"
    }
    $menuId = Assert-VisibleUiReviewElement -Using xpath -Value "//ListItem[@Name='$menu']"
    Invoke-WebDriverElement -ElementId $menuId
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $selected = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$menuId/selected"
        if ($selected.value) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $selected.value) { throw "Navigation did not select '$menu'." }

    if ($menu -eq "Devices") {
        $searchId = Assert-VisibleUiReviewElement -Value "Search devices"
        $null = Invoke-WebDriverRequest -Method Post `
            -Endpoint "/session/$sessionId/element/$searchId/clear" -Body @{}
        $null = Assert-VisibleUiReviewElement -Value "Online"
        if ($Scenario -in @("DeviceDetails", "DeviceHistory")) {
            $rowId = Assert-VisibleUiReviewElement -Using xpath `
                -Value "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]"
            Invoke-WebDriverElement -ElementId $rowId
            $null = Assert-VisibleUiReviewElement -Value "Back to devices"
            $null = Find-WebDriverElement -Using name -Value "Rename device"
            $null = Assert-VisibleUiReviewElement -Value "Network overview"
            # Narrow layouts stack identification/assignments below the initial viewport.
            $null = Find-WebDriverElement -Using name -Value "Device identification"
            $null = Find-WebDriverElement -Using name -Value "Scan additional ports"
            if ($Scenario -eq "DeviceHistory") {
                $tabId = Assert-VisibleUiReviewElement -Using xpath -Value "//*[@AutomationId='DeviceHistoryTab']"
                Invoke-WebDriverElement -ElementId $tabId
                $null = Assert-VisibleUiReviewElement -Value "Activity"
            }
        }
        elseif ($Scenario -eq "DevicesEmpty") {
            $null = Invoke-WebDriverRequest -Method Post `
                -Endpoint "/session/$sessionId/element/$searchId/value" `
                -Body @{ value = @("fingvibe-no-matching-host") }
            $null = Assert-VisibleUiReviewElement -Value "No devices match the current filter."
        }
        return
    }

    if ($Scenario -in @("PersonDetails", "RoomDetails")) {
        $listName = $menu
        $fixtureName = if ($Scenario -eq "PersonDetails") { "UI review person" } else { "UI review room" }
        $rowId = Assert-VisibleUiReviewElement -Using xpath `
            -Value "//List[@Name='$listName']/ListItem[.//*[@Name='$fixtureName']]"
        Invoke-WebDriverElement -ElementId $rowId
        $backName = if ($Scenario -eq "PersonDetails") { "Back to people" } else { "Back to rooms" }
        $null = Assert-VisibleUiReviewElement -Value $backName
        if ($Scenario -eq "PersonDetails") { Show-UiReviewPersonAssignments }
        $null = Assert-VisibleUiReviewElement -Value "Assigned devices"
        $null = Assert-VisibleUiReviewElement -Value "Assign devices"
        if ($Scenario -eq "PersonDetails") {
            Show-UiReviewPersonAssignments -Top
            $null = Assert-VisibleUiReviewElement -Value $backName
        }
        return
    }

    $sentinel = switch ($Scenario) {
        "Overview" { "Online devices" }
        "Network" { "Public IP address" }
        "Tools" { "Speed test" }
        "SpeedTest" { "Speed test" }
        "Troubleshooting" { "Network troubleshooting" }
        "About" { "About FingVibe" }
        "FingImport" { "Import from Fing" }
        "SqlEditor" { "SQL editor" }
        "DatabaseBackups" { "Database backups" }
        "People" { "Search people" }
        "Rooms" { "Search rooms" }
        "Settings" { "Window backdrop" }
        default { throw "No navigation is implemented for capture scenario '$Scenario'." }
    }
    if ($menu -eq "Tools") {
        $null = Show-UiReviewToolsCard -Name $sentinel
    }
    else {
        $null = Assert-VisibleUiReviewElement -Value $sentinel
    }

    if ($Scenario -eq "SpeedTest") {
        $cardId = Assert-VisibleUiReviewElement -Value "Speed test"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Start Cloudflare speed test"
    }
    elseif ($Scenario -eq "Troubleshooting") {
        $cardId = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='Network troubleshooting']"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Back to Tools"
        $null = Assert-VisibleUiReviewElement -Value "Router WAN IPv4 address"
        # The run action is below the initial viewport; native tests scroll to and verify it.
        $null = Find-WebDriverElement -Using name -Value "Run network troubleshooting"
    }
    elseif ($Scenario -eq "About") {
        $cardId = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='About FingVibe']"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Back to Tools"
        $null = Assert-VisibleUiReviewElement -Value "FingVibe LAN Scanner"
    }
    elseif ($Scenario -eq "FingImport") {
        $cardId = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='Import from Fing']"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Back to Tools"
        $null = Assert-VisibleUiReviewElement -Value "Browse Fing export"
        $null = Assert-VisibleUiReviewElement -Value "Analyze again"
        $null = Find-WebDriverElement -Using name -Value "Import reviewed Fing changes"
        $null = Find-WebDriverElement -Using name -Value "Fing import preview"
    }
    elseif ($Scenario -eq "SqlEditor") {
        $cardId = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='SQL editor']"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Back to Tools"
        $null = Assert-VisibleUiReviewElement -Value "SQL query"
        $null = Assert-VisibleUiReviewElement -Value "Run SQL query"
        $null = Assert-VisibleUiReviewElement -Value "Cancel SQL query"
        $null = Find-WebDriverElement -Using name -Value "Schema and examples"
    }
    elseif ($Scenario -eq "DatabaseBackups") {
        $cardId = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@Name='Database backups']"
        Invoke-WebDriverElement -ElementId $cardId
        $null = Assert-VisibleUiReviewElement -Value "Back to Tools"
        $null = Assert-VisibleUiReviewElement -Value "Back up now"
        $null = Assert-VisibleUiReviewElement -Value "Open backup folder"
        $null = Find-WebDriverElement -Using name -Value "Completed backups, newest first"
    }
}
