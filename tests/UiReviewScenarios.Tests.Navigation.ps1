# Navigation: WebDriver double, page sentinels and scrolling.
    # A stateful WebDriver double checks navigation and page sentinels without launching WinUI.
    $sessionId = "test"
    $script:currentPage = "Overview"
    $script:empty = $false
    $script:hiddenControl = ""
    $script:brokenNavigation = $false
    $script:toolsScrollPercent = 0
    $script:toolsScrollCalls = 0
    $script:offscreenToolsCard = ""
    $script:detailsScrollPercent = 0
    $script:detailsScrollCalls = 0
    $script:detailsScrollable = $true
    $script:offscreenDetailsControl = ""
    $script:personAssignmentsFocused = $false
    function Show-UiReviewPersonAssignments([switch] $Top) {
        $script:personAssignmentsFocused = -not $Top
    }
    function Get-UiReviewToolsScroll([string] $Name) {
        $scroll = [pscustomobject]@{}
        $scroll | Add-Member ScriptMethod SetScrollPercent {
            param($Horizontal, $Vertical)
            if ($Horizontal -ne -1) { throw "Tools scrolling must preserve horizontal position." }
            $script:toolsScrollPercent = $Vertical
            $script:toolsScrollCalls += 1
        }
        return $scroll
    }
    function Get-UiReviewDetailsScroll {
        $scroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticallyScrollable = $script:detailsScrollable } }
        $scroll | Add-Member ScriptMethod SetScrollPercent {
            param($Horizontal, $Vertical)
            if ($Horizontal -ne -1) { throw "Details scrolling must preserve horizontal position." }
            $script:detailsScrollPercent = $Vertical
            $script:detailsScrollCalls += 1
        }
        return $scroll
    }
    function Find-WebDriverElement([string] $Using, [string] $Value) {
        if ($Value -eq "Completed backups, newest first") { throw "The collapsed backups table has no automation peer." }
        if ($Using -eq "xpath") {
            if ($Value -match "^//ListItem\[@Name='(.+)'\]$") {
                if ($Matches[1] -notin @("Overview", "Network", "Devices", "People & rooms", "Tools", "Settings")) {
                    throw "Unexpected navigation item '$($Matches[1])'."
                }
                return "menu-$($Matches[1])"
            }
            if ($Value -eq "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]") { return "online-row" }
            if ($Value -eq "//*[@AutomationId='DeviceHistoryTab']") { return "control-DeviceHistoryTab" }
            if ($Value -eq "//List[@Name='People']/ListItem[.//*[@Name='UI review person']]") { return "person-row" }
            if ($Value -eq "//List[@Name='Rooms']/ListItem[.//*[@Name='UI review room']]") { return "room-row" }
            if ($Value -eq "//Button[@Name='About FingVibe & updates']") { return "control-About FingVibe & updates" }
            if ($Value -eq "//Button[@Name='Speed test']") { return "control-Speed test" }
            if ($Value -eq "//Button[@Name='Network health']") { return "control-Network health" }
            if ($Value -eq "//Button[@Name='Import from Fing']") { return "control-Import from Fing" }
            if ($Value -eq "//Button[@Name='SQL editor']") { return "control-SQL editor" }
            if ($Value -eq "//Button[@Name='Database backups']") { return "control-Database backups" }
            if ($Value -eq "//Button[@Name='View room map']") { return "control-View room map" }
            throw "Unexpected XPath '$Value'."
        }
        return "control-$Value"
    }
    function Invoke-WebDriverElement([string] $ElementId) {
        if ($ElementId -like "menu-*") {
            if (-not $script:brokenNavigation) { $script:currentPage = $ElementId.Substring(5) }
        }
        elseif ($ElementId -eq "online-row") { $script:currentPage = "DeviceDetails" }
        elseif ($ElementId -eq "control-DeviceHistoryTab") { $script:currentPage = "DeviceHistory" }
        elseif ($ElementId -eq "control-Speed test") { $script:currentPage = "SpeedTest" }
        elseif ($ElementId -eq "control-About FingVibe & updates") { $script:currentPage = "About" }
        elseif ($ElementId -eq "control-Network health") { $script:currentPage = "NetworkHealth" }
        elseif ($ElementId -eq "control-Open service status") { $script:currentPage = "ServiceStatus" }
        elseif ($ElementId -eq "control-Import from Fing") { $script:currentPage = "FingImport" }
        elseif ($ElementId -eq "control-SQL editor") { $script:currentPage = "SqlEditor" }
        elseif ($ElementId -eq "control-Database backups") { $script:currentPage = "DatabaseBackups" }
        elseif ($ElementId -eq "control-View room map") { $script:currentPage = "RoomMap" }
        elseif ($ElementId -eq "person-row") { $script:currentPage = "PersonDetails" }
        elseif ($ElementId -eq "room-row") { $script:currentPage = "RoomDetails" }
        else { throw "Unexpected click '$ElementId'." }
    }
    function Invoke-WebDriverRequest([string] $Method, [string] $Endpoint, [hashtable] $Body) {
        if ($Endpoint -notmatch '/element/(.+)/(displayed|selected|clear|value)$') {
            throw "Unexpected request '$Endpoint'."
        }
        $id, $operation = $Matches[1], $Matches[2]
        switch ($operation) {
            "selected" { return @{ value = ($script:currentPage -eq $id.Substring(5)) } }
            "clear" { $script:empty = $false; return @{} }
            "value" { $script:empty = $true; return @{} }
            "displayed" {
                if ($id -like "menu-*") { return @{ value = $true } }
                $visible = switch ($id) {
                    "control-Scan LAN" { $true }
                    "control-Search devices" { $script:currentPage -eq "Devices" }
                    "control-Online" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "online-row" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "person-row" { $script:currentPage -eq "People & rooms" }
                    "room-row" { $script:currentPage -eq "People & rooms" }
                    "control-No devices match the current filter." { $script:currentPage -eq "Devices" -and $script:empty }
                    "control-Back to devices" { $script:currentPage -eq "DeviceDetails" }
                    "control-DeviceHistoryTab" { $script:currentPage -eq "DeviceDetails" }
                    "control-Activity" { $script:currentPage -eq "DeviceHistory" }
                    "control-Rename device" { $script:currentPage -eq "DeviceDetails" }
                    "control-Network overview" { $script:currentPage -eq "DeviceDetails" }
                    "control-Scan additional ports" { $script:currentPage -eq "DeviceDetails" }
                    "control-Room assignment saved." { $script:currentPage -eq "DeviceDetails" }
                    "control-Online devices" { $script:currentPage -eq "Overview" }
                    "control-Public IP address" { $script:currentPage -eq "Network" }
                    "control-Speed test" { $script:currentPage -eq "Tools" }
                    "control-Start Cloudflare speed test" { $script:currentPage -eq "SpeedTest" }
                    "control-About FingVibe & updates" { $script:currentPage -eq "Settings" }
                    "control-Network health" { $script:currentPage -eq "Tools" }
                    "control-Import from Fing" { $script:currentPage -eq "Tools" }
                    "control-SQL editor" { $script:currentPage -eq "Tools" }
                    "control-SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Run SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Cancel SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Database backups" { $script:currentPage -eq "Tools" }
                    "control-View room map" { $script:currentPage -eq "Tools" }
                    "control-Room map" { $script:currentPage -eq "RoomMap" }
                    "control-Back to Rooms" { $script:currentPage -eq "RoomMap" }
                    "control-No room assigned" { $script:currentPage -eq "RoomMap" }
                    "control-Back up now" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Open backup folder" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Completed backups" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Browse Fing export" { $script:currentPage -eq "FingImport" }
                    "control-Analyze again" { $script:currentPage -eq "FingImport" }
                    "control-Monitoring off" { $script:currentPage -eq "NetworkHealth" }
                    "control-Run network diagnostics" { $script:currentPage -eq "NetworkHealth" }
                    "control-Router WAN IPv4 address" { $script:currentPage -eq "NetworkHealth" }
                    "control-Open service status" { $script:currentPage -eq "NetworkHealth" }
                    "control-Back to Network health" { $script:currentPage -eq "ServiceStatus" }
                    "control-Refresh provider reports" { $script:currentPage -eq "ServiceStatus" }
                    "control-Source pending" { $script:currentPage -eq "ServiceStatus" }
                    "control-Back to Tools" { $script:currentPage -in @("NetworkHealth", "FingImport", "SqlEditor", "DatabaseBackups") }
                    "control-Back to Settings" { $script:currentPage -eq "About" }
                    "control-FingVibe LAN Scanner" { $script:currentPage -eq "About" }
                    "control-Search people and rooms" { $script:currentPage -eq "People & rooms" }
                    "control-Back to people and rooms" { $script:currentPage -in @("PersonDetails", "RoomDetails") }
                    "control-Assigned devices" { $script:currentPage -eq "RoomDetails" -or
                        ($script:currentPage -eq "PersonDetails" -and $script:personAssignmentsFocused) }
                    "control-Assign devices" { $script:currentPage -eq "RoomDetails" -or
                        ($script:currentPage -eq "PersonDetails" -and $script:personAssignmentsFocused) }
                    "control-Appearance preferences" { $script:currentPage -eq "Settings" }
                    default { throw "Unexpected control '$id'." }
                }
                $offscreen = ($id -eq $script:offscreenToolsCard -and $script:toolsScrollPercent -lt 70) -or
                    ($id -eq $script:offscreenDetailsControl -and $script:detailsScrollPercent -lt 40)
                return @{ value = ($visible -and $id -ne $script:hiddenControl -and -not $offscreen) }
            }
        }
    }
    foreach ($scenario in $UiReviewScenarios.Keys) {
        Show-UiReviewCaptureScenario $scenario
        $expectedPage = switch ($scenario) {
            "DevicesEmpty" { "Devices" }
            { $_ -in @("People", "Rooms") } { "People & rooms" }
            default { $scenario }
        }
        Assert-Equal $script:currentPage $expectedPage "Navigation: $scenario"
    }
    Show-UiReviewCaptureScenario "Devices"
    Assert-Equal $script:empty $false "Returning from empty results restores the baseline"
    $script:hiddenControl = "control-Completed backups"
    Assert-Throws { Show-UiReviewCaptureScenario "DatabaseBackups" } "*Completed backups*not visible*"
    $script:hiddenControl = ""
    Test-UiReviewNavigation
    $script:hiddenControl = "control-Scan LAN"
    Assert-Throws { Test-UiReviewNavigation } "*Scan LAN*not visible*"
    $script:hiddenControl = ""
    Assert-Equal $script:toolsScrollCalls 0 "Visible Tools cards must not scroll"
    $script:offscreenToolsCard = "control-About FingVibe & updates"
    Show-UiReviewCaptureScenario "About"
    Assert-Equal $script:currentPage "About" "Offscreen About card navigation"
    Assert-Equal $script:toolsScrollPercent 70 "Scroll until the Tools card is visible"
    Assert-Equal $script:toolsScrollCalls 8 "Stop scrolling immediately after visibility"
    $script:offscreenToolsCard = ""
    $script:hiddenControl = "control-About FingVibe & updates"
    $callsBeforeFailure = $script:toolsScrollCalls
    Assert-Throws { Show-UiReviewCaptureScenario "About" } "*not visible*"
    Assert-Equal ($script:toolsScrollCalls - $callsBeforeFailure) 11 "Invisible Tools cards retain a bounded failure"
    $script:hiddenControl = "control-Public IP address"
    Assert-Throws { Test-UiReviewNavigation } "*not visible*"
    Assert-Throws { Show-UiReviewCaptureScenario "Network" } "*not visible*"
    $script:hiddenControl = ""
    $script:hiddenControl = "control-Scan additional ports"
    Show-UiReviewCaptureScenario "DeviceDetails"
    $script:hiddenControl = "control-Network overview"
    Assert-Throws { Show-UiReviewCaptureScenario "DeviceDetails" } "*not visible*"
    $script:hiddenControl = "control-Router WAN IPv4 address"
    Show-UiReviewCaptureScenario "NetworkHealth"
    $script:hiddenControl = "control-Run network diagnostics"
    Assert-Throws { Show-UiReviewCaptureScenario "NetworkHealth" } "*not visible*"
    $script:hiddenControl = ""
    foreach ($scenario in @("PersonDetails", "RoomDetails")) {
        $script:hiddenControl = "control-Assign devices"
        Assert-Throws { Show-UiReviewCaptureScenario $scenario } "*not visible*"
    }
    $script:hiddenControl = ""
    # The assignment feedback lives at the bottom of the tall Assignments card, below the first viewport.
    Show-UiReviewCaptureScenario "DeviceDetails"
    $null = Show-UiReviewDetailsControl -Value "Room assignment saved."
    Assert-Equal $script:detailsScrollCalls 0 "Visible details controls must not scroll"
    $script:offscreenDetailsControl = "control-Room assignment saved."
    $null = Show-UiReviewDetailsControl -Value "Room assignment saved."
    Assert-Equal $script:detailsScrollPercent 40 "Scroll until the assignment feedback is visible"
    Assert-Equal $script:detailsScrollCalls 5 "Stop scrolling immediately after visibility"
    Show-UiReviewDetailsTop
    Assert-Equal $script:detailsScrollPercent 0 "Return to the first viewport before using the pickers"
    $script:hiddenControl = "control-Room assignment saved."
    $callsBeforeFailure = $script:detailsScrollCalls
    Assert-Throws { Show-UiReviewDetailsControl -Value "Room assignment saved." } "*not visible*"
    Assert-Equal ($script:detailsScrollCalls - $callsBeforeFailure) 11 "Unreachable details controls retain a bounded failure"
    $script:detailsScrollable = $false
    $callsBeforeStatic = $script:detailsScrollCalls
    Assert-Throws { Show-UiReviewDetailsControl -Value "Room assignment saved." } "*not visible*"
    Show-UiReviewDetailsTop
    Assert-Equal $script:detailsScrollCalls $callsBeforeStatic "A page that cannot scroll must not be scrolled"
    $script:detailsScrollable = $true
    $script:offscreenDetailsControl = ""
    $script:hiddenControl = ""
    $script:brokenNavigation = $true
    Assert-Throws { Show-UiReviewCaptureScenario "Overview" } "*Navigation did not select*"
