# Summary-cases, provenance, restart/appearance, scan-outcome and load-failure phases.
    $phase = Step-UiRegressionPhase $phase "history/summary-cases" $ScreenshotDirectory
    foreach ($index in 0..4) {
        $lastSeen = @(0, 1, 1, 1, 4)[$index]
        $present = $index -notin @(2, 3)
        $time = "2026-11-01T12:0${index}:00+00:00"
        $normal.lastSeen = "2026-11-01T12:0${lastSeen}:00+00:00"
        $normal.lastChecked = $time
        $normal.present = $present
        $old.lastSeen = "2026-11-01T12:00:00+00:00"
        $old.lastChecked = $time
        $old.present = $index -eq 0
        $current.firstSeen = "2026-11-01T12:01:00+00:00"
        $current.lastSeen = "2026-11-01T12:0$([Math]::Max(1, $lastSeen)):00+00:00"
        $current.lastChecked = "2026-11-01T12:0$([Math]::Max(1, $index)):00+00:00"
        $current.present = $present -and $index -gt 0
        $slot = $data.virtualDevices[0]
        $slot.lastActiveMac = if ($index -eq 0) { "D0C907000001" } else { "D0C907000002" }
        $slot.lastChecked = $time
        $slot.present = $present
        $slot.history = @(@{ mac = "D0C907000001"; observation = $old; inferred = $true })
        if ($index -gt 0) { $slot.history += @{ mac = "D0C907000002"; observation = $current; inferred = $true } }
        $slot.scanHistory = @($history[0..$index])
        $data.devices.'020000000001'.scanHistory = @($history[0..$index]) + $decoyHistory
        @{ version = 3; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding UTF8
        if (Test-Path -LiteralPath $database) { Remove-Item -LiteralPath $database }
        Start-HistoryApp
        foreach ($kind in @("normal", "virtual")) {
            if (-not $ObservationsOnly) {
                $null = Assert-HistoryLastSeenCell "History $kind" "Last seen: $(Get-HistoryExactTime $lastSeen)"
                Assert-HistoryLastSeenAge "History $kind" $lastSeen
            }
            Open-HistoryDetails "History $kind"
            if (-not $ObservationsOnly) { Assert-HistorySummary "history-$kind-$index" $index }
            if (-not $SummaryOnly) { Assert-HistoryRows "history-$kind-$index" $index }
        }
        Stop-HistoryApp
    }
    $phase = Step-UiRegressionPhase $phase "history/provenance-and-scope" $ScreenshotDirectory
    $original = Get-Content -LiteralPath $inventory -Raw
    $originalDatabase = Get-InventoryFingerprint $database
    Start-HistoryApp
    $null = Assert-HistoryLastSeenCell "History legacy" `
        "Last seen: $(Get-HistoryExactTime 4) (historical aggregate; individual scan unavailable)"
    Assert-HistoryLastSeenAge "History legacy" 4
    $null = Assert-HistoryLastSeenCell "History unmatched" `
        "Last seen: Unavailable - no matching local presence evidence for the current network/subnet."
    if ((Get-HistoryLastSeenCell "History unmatched" -Rendered) -cne "Unavailable") { throw "Missing evidence must stay Unavailable." }
    $null = Assert-HistoryLastSeenCell "History imported" `
        "Last seen: Never - not observed by a local scan.*not mean the device was never present on any network."
    if ((Get-HistoryLastSeenCell "History imported" -Rendered) -cne "Never") { throw "Imported-only devices must render Never." }
    Open-HistoryDetails "History legacy"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Historical aggregate*") {
            throw "Legacy timestamps must retain their aggregate provenance."
        }
    }
    if ((Find-HistoryControl DeviceHistorySince).Current.Name -notlike "*Unavailable*") { throw "Legacy aggregates fabricated since." }
    $null = Show-HistorySection DeviceHistoryFirstSeen
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-legacy-summary.png")
    Open-HistoryDetails "History unmatched"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Unavailable*") { throw "Other-network/subnet evidence leaked into $id." }
    }
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "0 completed scan observations") { throw "Other-scope history leaked." }
    Open-HistoryDetails "History imported"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Unavailable*") { throw "Imported-only history fabricated $id." }
    }
    if (-not $SummaryOnly) {
        $empty = Show-HistorySection DeviceScanHistoryEmpty
        if ($empty.Current.Name -ne "No local scan history. Imported Fing data is not a local scan observation.") {
            throw "Imported-only history needs an explanatory empty state."
        }
    }
    else { $null = Show-HistorySection DeviceHistoryFirstSeen }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-imported.png")
    Stop-HistoryApp
    $phase = Step-UiRegressionPhase $phase "history/restart-and-appearance" $ScreenshotDirectory
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    Assert-HistorySummary "history-restarted"
    if (-not $SummaryOnly) { Assert-HistoryRows "history-restarted" }
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        $settings = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $settings) { throw "Settings navigation was not found." }
        $settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Expand-UiReviewSettingsSection -Root $script:root -Section AppearanceSection
        Wait-HistoryState {
            $picker = Find-HistoryControl ModePicker -Optional
            $picker -and -not $picker.Current.IsOffscreen
        } "appearance settings"
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-HistoryDetails "History normal"
        $label = $theme.Replace(" ", "-").ToLowerInvariant()
        if (-not $SummaryOnly) { Assert-HistoryTableRendering "history-table-$label" }
        else { Assert-HistorySummary "history-$label" }
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, 640, $bounds.Height, 0x0044)) { throw "Cannot resize history review window." }
        Start-Sleep -Milliseconds 500
        if (-not $SummaryOnly) {
            Assert-HistoryTableRendering "history-table-$label-narrow"
            (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
        }
        else { Assert-HistorySummary "history-$label-narrow" }
        $null = Show-HistorySection DeviceHistoryFirstSeen
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-summary-$label-narrow.png")
        $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height, 0x0044)
        Start-Sleep -Milliseconds 500
    }
    if (-not $SummaryOnly) {
        $contrast = [HistoryReviewContrast]::Get()
        [HistoryReviewContrast]::Set($contrast -bor 1)
        Start-Sleep -Seconds 2
        if (([HistoryReviewContrast]::Get() -band 1) -eq 0) { throw "High contrast did not activate." }
        Open-HistoryDetails "History normal"
        Assert-HistoryRows "history-high-contrast"
        [HistoryReviewContrast]::Set($contrast)
        $contrast = $null
    }
    $phase = Step-UiRegressionPhase $phase "history/scan-outcomes" $ScreenshotDirectory
    if (-not $ObservationsOnly) {
    Open-HistoryDetails "History virtual"
    Assert-HistorySummary "history-virtual-restarted"
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $original) { throw "Restoration must not write new scan entries." }
    if ((Get-InventoryFingerprint $database) -cne $originalDatabase) { throw "Restoration changed SQLite history." }
    foreach ($count in @(8, 9)) {
        Invoke-HistoryScan
        Wait-HistoryScan
        if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM scan_history WHERE kind='mac' AND id='020000000001'") -ne $count) {
            throw "Each successful repeated scan must persist one new observation."
        }
        if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM scan_history WHERE kind='virtual'") -ne $count - 2) { throw "Same-network scan did not record virtual absence." }
    }
    $normalPresent = Get-InventorySqliteValue $database "SELECT present FROM scan_history WHERE kind='mac' AND id='020000000001' ORDER BY sequence DESC LIMIT 1"
    $expectedNormal = if ("$normalPresent" -eq "1") { "Last seen: Online - responded in the displayed scan (*)" } else { "Last seen: $(Get-HistoryExactTime 4)" }
    $beforeLastSeen = @{
        "History normal" = Assert-HistoryLastSeenCell "History normal" $expectedNormal
        "History virtual" = Assert-HistoryLastSeenCell "History virtual" "Last seen: $(Get-HistoryExactTime 4)"
    }
    if ("$normalPresent" -eq "1") {
        if ($beforeLastSeen["History normal"] -notmatch '^Last seen: Online - responded in the displayed scan \((.+)\)$') {
            throw "The completed response must expose its exact Last seen timestamp."
        }
        # A new scan removes fresh-response presentation, not the retained timestamp or Online status.
        $beforeLastSeen["History normal"] = "Last seen: $($Matches[1])"
    }
    $beforeStop = Get-InventoryFingerprint $database
    Open-HistoryDetails "History normal"
    $beforeSummary = @{}
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince", "DeviceHistoryLatest")) {
        $beforeSummary[$id] = (Find-HistoryControl $id).Current.Name
    }
    Set-Content -LiteralPath $hold -Value "hold for cancellation"
    Invoke-HistoryScan
    Wait-HistoryState { Find-HistoryControl "Cancel scan" -ByName -Optional } "cancel action"
    (Find-HistoryControl "Cancel scan" -ByName).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryScan
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "Cancelled scan changed durable history." }
    Open-HistoryDetails "History normal"
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "7 completed scan observations") {
        throw "Cancelled scan changed displayed history."
    }
    foreach ($id in $beforeSummary.Keys) {
        if ((Find-HistoryControl $id).Current.Name -ne $beforeSummary[$id]) { throw "Cancelled scan changed $id." }
    }
    foreach ($name in $beforeLastSeen.Keys) {
        if ((Get-HistoryLastSeenCell $name) -cne $beforeLastSeen[$name]) { throw "Cancelled scan changed Last seen for $name." }
    }
    @{ completed = -1; total = 1 } | ConvertTo-Json | Set-Content -LiteralPath "$hold.progress"
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*UI-review progress fixture is invalid*") {
        throw "Failed scan must display its error."
    }
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "Failed scan changed durable history." }
    Open-HistoryDetails "History normal"
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "7 completed scan observations") {
        throw "Failed scan changed displayed history."
    }
    foreach ($id in $beforeSummary.Keys) {
        if ((Find-HistoryControl $id).Current.Name -ne $beforeSummary[$id]) { throw "Failed scan changed $id." }
    }
    foreach ($name in $beforeLastSeen.Keys) {
        if ((Get-HistoryLastSeenCell $name) -cne $beforeLastSeen[$name]) { throw "Failed scan changed Last seen for $name." }
    }
    Remove-Item -LiteralPath $hold, "$hold.progress"
    $lock = [System.IO.FileStream]::new("$inventory.lock", [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*Scan checkpoint could not be saved*") {
        throw "Failed history persistence must be visibly reported."
    }
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "A failed save changed durable history." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-save-error.png")
    $lock.Dispose()
    $lock = $null
    Set-Content -LiteralPath $database -Value "invalid inventory fixture"
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*Scan checkpoint could not be saved*") {
        throw "Invalid saved history encountered while saving must be visibly reported."
    }
    if ((Get-Content -LiteralPath $database -Raw).Trim() -ne "invalid inventory fixture") {
        throw "Saving must not overwrite invalid history."
    }
    Stop-HistoryApp
    $phase = Step-UiRegressionPhase $phase "history/load-failure" $ScreenshotDirectory
    Start-HistoryApp
    Wait-HistoryState {
        $status = Find-HistoryControl ScanStatusText -Optional
        $status -and $status.Current.Name -like "*Saved inventory could not be loaded. Changes are disabled*"
    } "visible inventory load failure"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-load-error.png")
    if ((Get-Content -LiteralPath $database -Raw).Trim() -ne "invalid inventory fixture") {
        throw "Invalid saved history must not be overwritten."
    }
    Stop-HistoryApp
    }
    else { Stop-HistoryApp }
