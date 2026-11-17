# Paging phase: completed-observation pages, navigation and page errors.
    $phase = Step-UiRegressionPhase $phase "history/paging" $ScreenshotDirectory
    $pagedHistory = @(0..204 | ForEach-Object {
        @{ completedAt = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($_)).ToString("o")
           networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = ($_ % 4 -lt 2) }
    })
    $data.devices.'020000000001'.scanHistory = $pagedHistory + $decoyHistory
    $normal.lastSeen = "2026-11-01T12:03:24+00:00"
    $normal.lastChecked = $normal.lastSeen
    $normal.present = $true
    @{ version = 3; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding UTF8
    Remove-Item -LiteralPath $database
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    $reachable = @{}
    Assert-HistoryScrollMovement
    foreach ($pageIndex in 0..2) {
        $null = Wait-HistoryPage ($pageIndex + 1)
        $pageRows = @(Assert-HistoryPage $pageIndex -Traverse)
        foreach ($label in $pageRows) {
            if ($reachable.ContainsKey($label)) { throw "Observation duplicated across history pages: $label." }
            $reachable[$label] = $true
        }
        $list = Show-HistorySection DeviceScanHistoryList
        $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-page-$($pageIndex + 1).png")
        $pageRows | ConvertTo-Json | Set-Content (Join-Path $ScreenshotDirectory "history-page-$($pageIndex + 1).json")
        if ($pageIndex -lt 2) {
            Move-HistoryPage DeviceHistoryOlder ($pageIndex + 2) -Keyboard
        }
    }
    if ($reachable.Count -ne 205) { throw "All 205 retained observations must remain reachable." }
    if ((Find-HistoryControl DeviceHistoryOlder).Current.IsEnabled) { throw "Older navigation must stop at the oldest page." }
    foreach ($pageIndex in @(1, 0)) {
        Move-HistoryPage DeviceHistoryNewer ($pageIndex + 1)
        $null = Assert-HistoryPage $pageIndex
    }
    if ((Find-HistoryControl DeviceHistoryNewer).Current.IsEnabled) { throw "Newer navigation must stop at the newest page." }
    $beforeError = @(Assert-HistoryPage 0)
    $savedDatabase = [IO.File]::ReadAllBytes($database)
    Set-Content -LiteralPath $database -Value "invalid observation page fixture"
    Move-HistoryPage DeviceHistoryOlder 2 -State Error
    if ((Find-HistoryControl DeviceHistoryPageStatus).Current.Name -notlike "Scan history page could not be loaded:*") {
        throw "Page errors must be explicit without replacing valid rows."
    }
    $retained = @((Show-HistorySection DeviceScanHistoryList).FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem)) | ForEach-Object { $_.Current.Name })
    if (($retained -join "|") -cne ($beforeError -join "|")) { throw "A failed page load replaced the last valid page." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-page-error.png")
    [IO.File]::WriteAllBytes($database, $savedDatabase)
    Move-HistoryPage DeviceHistoryOlder 2
    $null = Assert-HistoryPage 1
    Test-HistoryTabs
    Move-HistoryPage DeviceHistoryOlder 3
    Open-HistoryDetails "History imported"
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "0 completed scan observations") {
        throw "Selection changes must not retain the previous device's page."
    }
    Open-HistoryDetails "History normal"
    $null = Wait-HistoryPage 1
    $null = Assert-HistoryPage 0
    if ((Find-HistoryControl DeviceHistoryNewer).Current.IsEnabled) { throw "Newer navigation must stop at the newest page." }
    Stop-HistoryApp
