function Wait-SidebarText([string] $Id, [string] $Pattern, [int] $Seconds = 30) {
    try {
        Wait-UiRegressionState -TimeoutMilliseconds ($Seconds * 1000) -Description "'$Id' matching '$Pattern'" -Condition {
            $element = Find-SidebarElement AutomationId $Id -Optional
            if ($element -and $element.Current.Name -like $Pattern) { return $element }
            return $null
        }
    }
    catch {
        Save-ScheduledScanFailure "scheduled-scans-wait-failure"
        throw
    }
}

function Save-ScheduledScanFailure([string] $Name) {
    try { Save-SidebarAppearance $Name }
    catch { Write-Warning "Could not capture '$Name': $($_.Exception.Message)" }
}

function Assert-ScheduledScanSettings([bool] $IsEnabled, [int] $IntervalMinutes) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $saved = $null
        try { $saved = Get-Content -LiteralPath $periodicScanPath -Raw | ConvertFrom-Json }
        catch [System.IO.IOException], [System.Management.Automation.ItemNotFoundException] { }
        if ($saved -and $saved.isEnabled -eq $IsEnabled -and $saved.intervalMinutes -eq $IntervalMinutes) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected saved scheduled scans enabled=$IsEnabled every $IntervalMinutes minutes; got $($saved | ConvertTo-Json -Compress)."
}

function Show-ScheduledScansCard {
    $page = Find-SidebarElement AutomationId SettingsPage
    $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 100) }
        Start-Sleep -Milliseconds 300
        $pageBounds = $page.Current.BoundingRectangle
        $ready = $true
        foreach ($id in @("ScheduledScansHeading", "ScheduledScansSwitch", "ScanIntervalPicker",
            "ScheduledScanStatus", "ScheduledScanEvidenceNote")) {
            $element = Find-SidebarElement AutomationId $id -Optional
            if (-not $element) { $ready = $false; break }
            $bounds = $element.Current.BoundingRectangle
            if ($bounds.Left -lt $pageBounds.Left -or $bounds.Right -gt $pageBounds.Right + 1 -or
                $bounds.Top -lt $pageBounds.Top -or $bounds.Bottom -gt $pageBounds.Bottom + 1) {
                $ready = $false
                break
            }
        }
        if ($ready) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    Save-ScheduledScanFailure "scheduled-scans-clipped"
    throw "Scheduled scan control '$id' did not become fully visible in Settings."
}

function Hide-ScheduledScansCard {
    $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Start-Sleep -Milliseconds 200
}

function Switch-ScheduledScansWithKeyboard([bool] $Expected) {
    Focus-SidebarWindow
    # Cancelling from the header can scroll Settings, so bring the card back into view before using the keyboard.
    Show-ScheduledScansCard
    $switch = Find-SidebarElement AutomationId ScheduledScansSwitch
    $switch.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x20)
    $toggle = $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $expectedState = if ($Expected) { [System.Windows.Automation.ToggleState]::On } else { [System.Windows.Automation.ToggleState]::Off }
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ($toggle.Current.ToggleState -ne $expectedState) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Scheduled scans must toggle with Space." }
        Start-Sleep -Milliseconds 50
    }
}

function Assert-ScheduledScansSelection([string] $State, [string] $Interval) {
    $toggle = (Find-SidebarElement AutomationId ScheduledScansSwitch).GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern)
    $picker = (Find-SidebarElement AutomationId ScanIntervalPicker).GetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern)
    if ($toggle.Current.ToggleState -ne $State -or $picker.Current.GetSelection()[0].Current.Name -ne $Interval) {
        throw "Expected scheduled scans $State every $Interval."
    }
}

function Test-ScheduledScans {
    # Windows PowerShell reads this BOM-less script as ANSI, so build the separator explicitly.
    $dot = [char] 0x00B7
    $highContrast = $null
    $captureTopmost = $false
    try {
        Stop-SidebarApp
        $null = New-Item -ItemType Directory -Path $periodicScanDirectory -Force
        $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $periodicScanPath
        # Each minute takes a third of a second, so 15 minutes is 5 seconds and 1 hour is 20 seconds.
        $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE = "180"
        $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $periodicScanDirectory "latest-scan.json"
        $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $periodicScanDirectory "device-inventory.sqlite"
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Settings "Window backdrop"
        Show-ScheduledScansCard
        Assert-ScheduledScansSelection Off "1 hour"
        if ((Find-SidebarElement AutomationId ScheduledScansSwitch).Current.Name -ne "Scheduled scans" -or
            (Find-SidebarElement AutomationId ScanIntervalPicker).Current.Name -ne "Scheduled scan interval") {
            throw "Scheduled scan controls must expose descriptive accessible names."
        }
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        if ((Find-SidebarElement AutomationId ScheduledScanEvidenceNote).Current.Name -notlike
            "Each scheduled scan samples which devices answer at that moment.*not proof that a device was offline*") {
            throw "Scheduled scans must be explained as sampled evidence, not continuous uptime."
        }
        if ((Find-SidebarElement AutomationId ScanFreshnessText).Current.Name -like "*Scheduled*") {
            throw "The header must not mention scheduling while it is off."
        }
        if (Test-Path -LiteralPath $periodicScanPath) { throw "Loading default scheduled-scan settings must not save them." }

        foreach ($width in @($expandedWidth, 640, 480)) {
            Set-SidebarWindowWidth $width
            Show-ScheduledScansCard
            $switch = (Find-SidebarElement AutomationId ScheduledScansSwitch).Current.BoundingRectangle
            $picker = (Find-SidebarElement AutomationId ScanIntervalPicker).Current.BoundingRectangle
            $status = (Find-SidebarElement AutomationId ScheduledScanStatus).Current.BoundingRectangle
            $note = (Find-SidebarElement AutomationId ScheduledScanEvidenceNote).Current.BoundingRectangle
            $overlap = [System.Windows.Rect]::Intersect($switch, $picker)
            if (-not $overlap.IsEmpty -and $overlap.Width -gt 0 -and $overlap.Height -gt 0) {
                throw "Scheduled scan controls overlap at $width."
            }
            if ($width -ge 640 -and ($switch.Right -gt $picker.Left -or $picker.Top -ge $switch.Bottom)) {
                throw "Scheduled scan controls must share a row at $width."
            }
            if ($width -lt 640 -and $switch.Bottom -gt $picker.Top) {
                throw "Scheduled scan controls must stack at narrow widths."
            }
            if ([Math]::Max($switch.Bottom, $picker.Bottom) -gt $status.Top -or $status.Bottom -gt $note.Top) {
                throw "Scheduled scan status and evidence note must follow the controls at $width."
            }
            if ($width -ge 640) { Save-SidebarAppearance "scheduled-scans-off-$width" }
        }
        Set-SidebarWindowWidth $expandedWidth
        Show-ScheduledScansCard

        Switch-ScheduledScansWithKeyboard $true
        Assert-ScheduledScanSettings $true 60
        $null = Wait-SidebarText ScheduledScanStatus "First scheduled scan around *."
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 1 hour while app is open"

        # The hold keeps scheduled scans in progress until they are cancelled or disabled.
        [IO.File]::WriteAllText($scanHoldPath, "Hold scheduled scans for cancellation checks.")
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "15 minutes"
        Assert-ScheduledScanSettings $true 15
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 15 minutes while app is open"
        $null = Wait-SidebarText ScanStatusText "Scheduled scan $dot Scanning ICMP:*"
        $null = Wait-SidebarText ScheduledScanStatus "Scheduled scan in progress."
        Show-ScheduledScansCard
        Save-SidebarAppearance "scheduled-scans-running"
        Select-SidebarPage Overview "Online devices"
        $null = Find-SidebarElement AutomationId ScanProgressBar
        $null = Find-SidebarElement AutomationId CancelButton
        Select-SidebarPage Settings "Window backdrop"
        (Find-SidebarElement AutomationId CancelButton).GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Wait-SidebarText ScanStatusText "Scheduled scan of 127.0.0.1/32 cancelled*"
        $null = Find-SidebarElement Name "Window backdrop"
        Show-ScheduledScansCard
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan was cancelled; committed checkpoints are retained as incomplete. Next around *."
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 15 minutes while app is open"

        $null = Wait-SidebarText ScanStatusText "Scheduled scan $dot Scanning ICMP:*"
        Switch-ScheduledScansWithKeyboard $false
        $null = Wait-SidebarText ScanStatusText "Scheduled scan of 127.0.0.1/32 stopped*"
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        Assert-ScheduledScanSettings $false 15
        if ((Find-SidebarElement AutomationId ScanFreshnessText).Current.Name -like "*Scheduled*") {
            throw "Disabling scheduled scans must remove the header schedule."
        }
        if (Test-Path -LiteralPath $env:FINGVIBE_UI_REVIEW_SNAPSHOT) {
            throw "Cancelled or stopped scheduled scans must not save results."
        }

        Remove-Item -LiteralPath $scanHoldPath
        Switch-ScheduledScansWithKeyboard $true
        Assert-ScheduledScanSettings $true 15
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan completed. Next around *."
        $null = Wait-SidebarText ScanFreshnessText "*127.0.0.1/32 $dot Scheduled every 15 minutes while app is open"
        if (-not (Test-Path -LiteralPath $env:FINGVIBE_UI_REVIEW_SNAPSHOT)) {
            throw "A completed scheduled scan must save its results."
        }
        # A longer interval keeps the completed state stable while every theme is captured.
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "4 hours"
        Assert-ScheduledScanSettings $true 240
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan completed. Next around *."
        foreach ($theme in $UiReviewAppearanceThemes) {
            Hide-ScheduledScansCard
            Set-UiReviewTheme -Root $root -Theme $theme
            Show-ScheduledScansCard
            Save-SidebarAppearance "scheduled-scans-$theme"
        }
        if ($env:GITHUB_ACTIONS -eq "true") {
            $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
            if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw "High contrast did not activate." }
            Start-Sleep -Seconds 2
            # Contrast changes can raise the runner's console over the foreground app.
            if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0053)) {
                throw [System.ComponentModel.Win32Exception]::new()
            }
            $captureTopmost = $true
            Show-ScheduledScansCard
            Save-SidebarAppearance "scheduled-scans-high-contrast"
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
            $highContrast = $null
            Start-Sleep -Seconds 2
            if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
                throw [System.ComponentModel.Win32Exception]::new()
            }
            $captureTopmost = $false
        }

        # Restarting restores the saved choice and waits a full interval before the first scan.
        Hide-ScheduledScansCard
        Set-UiReviewTheme -Root $root -Theme "Standard Dark"
        Show-ScheduledScansCard
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "2 hours"
        Assert-ScheduledScanSettings $true 120
        Stop-SidebarApp
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Settings "Window backdrop"
        Show-ScheduledScansCard
        Assert-ScheduledScansSelection On "2 hours"
        $null = Wait-SidebarText ScheduledScanStatus "First scheduled scan around *."
        $null = Wait-SidebarText ScanFreshnessText "*127.0.0.1/32 $dot Scheduled every 2 hours while app is open"
        (Find-SidebarElement AutomationId ScheduledScansSwitch).GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        Assert-ScheduledScanSettings $false 120
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        Hide-ScheduledScansCard
        Write-Host "Scheduled scan defaults, keyboard toggle, interval, cancellation, disabling, completion, persistence, responsive layout, and themes passed."
    }
    finally {
        if ($null -ne $highContrast) {
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
            Start-Sleep -Seconds 2
        }
        if ($captureTopmost -and $process -and -not $process.HasExited -and
            -not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
    }
}
