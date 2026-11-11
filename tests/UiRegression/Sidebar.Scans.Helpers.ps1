function Wait-DeviceScan {
    $null = Wait-UiRegressionState -TimeoutMilliseconds 30000 -PollMilliseconds 50 -Description 'device scan completion' -Condition {
        $button = Find-SidebarElement AutomationId ScanButton -Optional
        $button -and $button.Current.IsEnabled
    }
}

function Test-SharedScanContext([string] $Sentinel, [switch] $Cancel,
    [ValidateSet('Name', 'AutomationId')][string] $SentinelProperty = 'Name') {
    $null = Find-SidebarElement $SentinelProperty $Sentinel
    $network = (Find-SidebarElement AutomationId NetworkPicker).GetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
    if (Test-Path -LiteralPath $scanHoldPath) { throw 'A prior scan hold was not released.' }
    [IO.File]::WriteAllText($scanHoldPath, 'Observe the current page before completing the shared scan.')
    try {
        Focus-SidebarWindow
        (Find-SidebarElement AutomationId ScanButton).SetFocus()
        [SidebarReviewKeyboard]::Tap(0x20)
        $cancelButton = Wait-UiRegressionState -Description 'keyboard scan cancellation action' -Condition {
            $button = Find-SidebarElement AutomationId CancelButton -Optional
            if ($button -and $button.Current.IsEnabled -and $button.Current.HasKeyboardFocus) { return $button }
        }
        $null = Find-SidebarElement $SentinelProperty $Sentinel
        if (-not $cancelButton.Current.IsEnabled -or -not $cancelButton.Current.HasKeyboardFocus -or
            (Find-SidebarElement AutomationId NetworkPicker).Current.IsEnabled -or
            (Find-SidebarElement AutomationId ScanButton -Optional)) {
            throw 'A shared scan must preserve its page, lock its LAN and transfer keyboard focus to Cancel scan.'
        }
        $null = Find-SidebarElement AutomationId ScanProgressBar
        if ($Cancel) {
            [SidebarReviewKeyboard]::Tap(0x20)
        }
        else {
            Remove-Item -LiteralPath $scanHoldPath
        }
        Wait-DeviceScan
        $null = Find-SidebarElement $SentinelProperty $Sentinel
        $selected = (Find-SidebarElement AutomationId NetworkPicker).GetCurrentPattern(
            [System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
        if ($selected -ne $network -or -not (Find-SidebarElement AutomationId ScanButton).Current.HasKeyboardFocus -or
            (Find-SidebarElement AutomationId CancelButton -Optional)) {
            throw 'Ending a shared scan must retain the selected LAN and page and restore Scan LAN focus.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
    }
}

function Test-DeviceRefresh {
    $snapshotPath = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
    if (-not $snapshotPath) { throw 'Device refresh checks require an isolated review snapshot.' }
    $snapshot = if (Test-Path -LiteralPath $snapshotPath) { [IO.File]::ReadAllBytes($snapshotPath) } else { $null }
    try {
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Overview "Online devices"
        $scan = Find-SidebarElement AutomationId ScanButton
        $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        $null = Find-SidebarElement Name "Online devices"
        Select-SidebarPage Devices "Search devices"
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device") {
            throw "The loopback scan must display exactly one device."
        }
        foreach ($page in @(
            @("Devices", "Search devices"),
            @("Overview", "Online devices"),
            @("Network", "Public IP address"),
            @("People", "Search people"),
            @("Rooms", "Search rooms"),
            @("Tools", "Speed test"),
            @("Settings", "Window backdrop")
        )) {
            Select-SidebarPage $page[0] $page[1]
            Assert-SharedNetworkHeader
            if ($page[0] -eq 'Network') {
                # The heading can scroll offscreen without leaving the Network page.
                Test-SharedScanContext NetworkPage -SentinelProperty AutomationId
            }
            else {
                Test-SharedScanContext $page[1]
            }
            if ((Find-SidebarElement AutomationId ScanStatusText -Optional) -or
                (Find-SidebarElement AutomationId ScanProgressBar -Optional)) {
                throw "Successful completion must leave no scan message or progress on $($page[0])."
            }
            if ($page[0] -eq "Devices" -and
                (Find-SidebarElement AutomationId LastScanText).Current.Name -notmatch '^Scan duration \d') {
                throw "Devices must retain the completed scan duration."
            }
            if ($page[0] -eq "Overview" -and
                (Find-SidebarElement AutomationId OnlineDevicesText).Current.Name -ne "1") {
                throw "Overview must retain its online-device count after successful completion."
            }
        }
        Select-SidebarPage Devices "Search devices"
        $row = (Find-SidebarElement AutomationId ResultsList).FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        if (-not $row) { throw 'The scan fixture has no device to open.' }
        $row.SetFocus()
        [SidebarReviewKeyboard]::Tap(0x0D)
        (Find-SidebarElement Name "Rename device").GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        (Find-SidebarElement AutomationId DeviceNameInput).GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).SetValue("Unsaved scan draft")
        Test-SharedScanContext "Back to devices" -Cancel
        Test-SharedScanContext "Back to devices"
        if ((Find-SidebarElement AutomationId DeviceNameInput).GetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "Unsaved scan draft") {
            throw 'Scanning from Device Details must retain the selected device and unsaved name.'
        }
        (Find-SidebarElement Name "Back to devices").GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $search = (Find-SidebarElement AutomationId ResultSearchBox).GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern)
        $search.SetValue("fingvibe-no-matching-device")
        Start-Sleep -Milliseconds 200
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 0 of 1 devices") {
            throw "Filtered device counts must include the unfiltered total."
        }
        $search.SetValue("")
        [IO.File]::WriteAllText($scanHoldPath, "Hold the refresh until retained results have been observed.")
        (Find-SidebarElement AutomationId ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        if (Find-SidebarElement AutomationId ScanButton -Optional) { throw "Scan LAN must be replaced, not left disabled, during refresh." }
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*Displaying retained results*") {
            throw "Refresh must retain the displayed devices and explain their status."
        }
        Select-SidebarPage Overview "Online devices"
        if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "Scanning ICMP:*") {
            throw "Live scan progress must remain visible after navigation."
        }
        (Find-SidebarElement Name "Cancel scan").GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        $null = Find-SidebarElement Name "Online devices"
        Select-SidebarPage Devices "Search devices"
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*cancelled*") {
            throw "Cancellation must preserve the displayed devices and report its outcome."
        }
        Remove-Item -LiteralPath $scanHoldPath
        [IO.File]::WriteAllText($scanHoldPath + ".progress", '{"Completed":2,"Total":1}')
        [IO.File]::WriteAllText($scanHoldPath, "Exercise explicit scan failure.")
        Select-SidebarPage Settings "Window backdrop"
        (Find-SidebarElement AutomationId ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        $null = Find-SidebarElement Name "Window backdrop"
        if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*Unable to scan*") {
            throw "A failed scan must retain its error instead of clearing the scan message."
        }
        Remove-Item -LiteralPath $scanHoldPath, ($scanHoldPath + ".progress")
        Select-SidebarPage Devices "Search devices"
        Remove-Item -LiteralPath $snapshotPath
        $null = New-Item -ItemType Directory -Path $snapshotPath
        try {
            (Find-SidebarElement AutomationId ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Wait-DeviceScan
            Select-SidebarPage Overview "Online devices"
            if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*latest-scan cache could not be updated*") {
                throw "A successful scan must preserve persistence errors across navigation."
            }
            Select-SidebarPage Devices "Search devices"
        }
        finally { Remove-Item -LiteralPath $snapshotPath }
        $filterExpander = (Find-SidebarElement AutomationId FilterExpander).GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        $filterExpander.Toggle()
        Start-Sleep -Milliseconds 250
        $expanderElement = Find-SidebarElement AutomationId FilterExpander
        if ($expanderElement.Current.HelpText -ne "Expanded") {
            throw "The funnel must expose its expanded state."
        }
        foreach ($width in @($expandedWidth, 1000, 640)) {
            Set-SidebarWindowWidth $width
            $filters = @("ResultSearchBox", "InventoryStatusFilter", "FilterExpander", "TypeFilter",
                "OperatingSystemFilter", "VendorFilter", "PersonFilter", "RoomFilter", "PortsFilter") |
                ForEach-Object { Find-SidebarElement AutomationId $_ }
            for ($index = 0; $index -lt $filters.Count; $index++) {
                $bounds = $filters[$index].Current.BoundingRectangle
                if ($bounds.Width -le 0) {
                    $filters | ForEach-Object { Write-Host "$($_.Current.AutomationId): $($_.Current.BoundingRectangle)" }
                    Save-SidebarAppearance "filters-layout-failure"
                    throw "Filter '$($filters[$index].Current.AutomationId)' has no visible width at $width."
                }
                for ($other = 0; $other -lt $index; $other++) {
                    $intersection = [System.Windows.Rect]::Intersect($bounds, $filters[$other].Current.BoundingRectangle)
                    if (-not $intersection.IsEmpty -and $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                        throw "Device filters overlap at $width logical pixels."
                    }
                }
            }
        }
        $filterExpander.Toggle()
        Write-Host "Device success/navigation, refresh/cancellation, scan/save errors, filtered counts, and responsive filter bounds passed."
    }
    finally {
        try {
            if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
            if ($scan) { Wait-DeviceScan }
        }
        finally {
            if ($null -ne $snapshot) { [IO.File]::WriteAllBytes($snapshotPath, $snapshot) }
            elseif (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath }
        }
    }
}

function Test-UnavailableScanTarget {
    $previous = $env:FINGVIBE_UI_REVIEW_NO_NETWORK
    $previousSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
    $failed = $true
    try {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_NO_NETWORK = '1'
        $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixtureDirectory 'no-network-snapshot.json'
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Network "No active IPv4 network"
        foreach ($page in @(
            @("Devices", "Search devices"), @("Overview", "Online devices"),
            @("Network", "No active IPv4 network"), @("People", "Search people"),
            @("Rooms", "Search rooms"), @("Tools", "Speed test"), @("Settings", "Window backdrop")
        )) {
            Select-SidebarPage $page[0] $page[1]
            $scan = Find-SidebarElement AutomationId ScanButton
            if ($scan.Current.IsEnabled -or $scan.Current.Name -ne 'Scan LAN' -or
                (Find-SidebarElement AutomationId ScanFreshnessText).Current.Name -notlike '*Connect to a LAN to scan*' -or
                (Find-SidebarElement AutomationId CancelButton -Optional)) {
                throw "Without a selected LAN, $($page[0]) must retain the disabled shared action and unavailable feedback."
            }
        }
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
            { Stop-SidebarApp },
            {
                $env:FINGVIBE_UI_REVIEW_NO_NETWORK = $previous
                $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $previousSnapshot
            },
            { Start-SidebarApp; Set-SidebarWindowWidth $expandedWidth; Wait-DeviceScan })
    }
}

function Test-ScanPresentation {
    $highContrast = $null
    $animations = $null
    $captureTopmost = $false
    try {
        foreach ($theme in $UiReviewAppearanceThemes) {
            Set-SidebarWindowWidth $expandedWidth
            Select-SidebarPage Settings "Window backdrop"
            Set-UiReviewTheme -Root $root -Theme $theme
            Select-SidebarPage Devices "Search devices"
            $cases = @(@($expandedWidth, 5), @($expandedWidth, 90), @(640, 90), @(480, 90))
            if ($env:GITHUB_ACTIONS -eq "true" -and $theme -eq "Standard Dark") {
                $cases += @(@(640, 90, "NoAnimation"), @(640, 90, "HighContrast"))
            }
            foreach ($case in $cases) {
                if ($case[2] -eq "NoAnimation") {
                    $animations = [SidebarReviewKeyboard]::GetAnimations()
                    [SidebarReviewKeyboard]::SetAnimations($false)
                    if ([SidebarReviewKeyboard]::GetAnimations()) { throw "Reduced animation did not activate." }
                    Start-Sleep -Seconds 2
                }
                elseif ($case[2] -eq "HighContrast") {
                    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
                    if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) {
                        throw "High contrast did not activate."
                    }
                    Start-Sleep -Seconds 2
                }
                Set-SidebarWindowWidth $case[0]
                $scan = Find-SidebarElement AutomationId ScanButton
                if ($case[0] -ge 640 -and $case[1] -eq 90) {
                    Save-SidebarAppearance "scan-action-$theme-$($case[0])-$($case[2])"
                }
                [IO.File]::WriteAllText($scanHoldPath + ".progress",
                    ('{"Completed":' + $case[1] + ',"Total":100}'))
                [IO.File]::WriteAllText($scanHoldPath, "Hold synthetic progress for native geometry/pixel assertions.")
                $scan.SetFocus()
                Start-Sleep -Milliseconds 100
                $idleBounds = $scan.Current.BoundingRectangle
                $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $cancel = Find-SidebarElement AutomationId CancelButton
                Start-Sleep -Milliseconds 400
                if ($cancel.Current.Name -ne "Cancel scan" -or -not $cancel.Current.IsEnabled -or
                    (Find-SidebarElement AutomationId ScanButton -Optional)) {
                    throw "Exactly one usable scan action must be visible while scanning."
                }
                $cancelBounds = $cancel.Current.BoundingRectangle
                if ([Math]::Abs($idleBounds.Left - $cancelBounds.Left) -gt $scale -or
                    [Math]::Abs($idleBounds.Top - $cancelBounds.Top) -gt $scale -or
                    [Math]::Abs($idleBounds.Width - $cancelBounds.Width) -gt $scale) {
                    throw "Scan LAN and Cancel scan must share one fixed position and width. Idle=$idleBounds; active=$cancelBounds; theme=$theme; case=$case."
                }
                $bar = Find-SidebarElement AutomationId ScanProgressBar
                $value = $bar.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current
                if ($value.Value -ne $case[1] -or $value.Maximum -ne 100) {
                    throw "The native progress indicator must preserve the fixture's exact measured fraction."
                }
                $pickerBounds = (Find-SidebarElement AutomationId NetworkPicker).Current.BoundingRectangle
                $statusBounds = (Find-SidebarElement AutomationId ScanStatusText).Current.BoundingRectangle
                $barBounds = $bar.Current.BoundingRectangle
                $windowBounds = Get-UiReviewWindowBounds $windowHandle
                foreach ($bounds in @($pickerBounds, $statusBounds, $barBounds, $cancelBounds)) {
                    if (-not $root.Current.BoundingRectangle.Contains($bounds)) {
                        throw "Scan context, action and progress must not clip at $($case[0]) DIPs."
                    }
                }

                if ($statusBounds.Top -lt $pickerBounds.Bottom -or $barBounds.Top -lt $statusBounds.Bottom) {
                    throw "Scan text and progress must stay together below the network selector."
                }
                if ($case[0] -ge 640) {
                    $path = Join-Path $ScreenshotDirectory "scan-$theme-$($case[0])-$($case[1])-$($case[2]).png"
                    if ($env:GITHUB_ACTIONS -eq "true") {
                        # Contrast changes can raise the runner's console over the foreground app.
                        if (-not [UiReviewNativeWindow]::SetWindowPos(
                                $windowHandle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0053)) {
                            throw [System.ComponentModel.Win32Exception]::new()
                        }
                        $captureTopmost = $true
                        Start-Sleep -Milliseconds 250
                    }
                    Focus-SidebarWindow
                    Save-UiReviewWindowScreenshot $windowHandle $path
                    $bitmap = [System.Drawing.Bitmap]::new($path)
                    try {
                        $left = $barBounds.Left - $windowBounds.Left
                        $top = $barBounds.Top - $windowBounds.Top
                        $filledX = [int]($left + $barBounds.Width * $case[1] / 200)
                        $emptyX = [int]($left + $barBounds.Width * 0.98)
                        $thickPixels = 0
                        for ($y = [int][Math]::Ceiling($top); $y -lt [Math]::Floor($top + $barBounds.Height); $y++) {
                            $fill = $bitmap.GetPixel($filledX, $y)
                            $empty = $bitmap.GetPixel($emptyX, $y)
                            $difference = [Math]::Abs([int]$fill.R - $empty.R) +
                                [Math]::Abs([int]$fill.G - $empty.G) + [Math]::Abs([int]$fill.B - $empty.B)
                            if ($difference -gt 40) { $thickPixels++ }
                        }
                        if ($thickPixels -lt 7 * $scale) {
                            throw "The completed segment must actually paint at least 7 of its 8 DIPs, not just occupy a taller container."
                        }
                        if ($case[2]) {
                            Start-Sleep -Milliseconds 650
                            $staticPath = Join-Path $ScreenshotDirectory "scan-static-$($case[2]).png"
                            Save-UiReviewWindowScreenshot $windowHandle $staticPath
                            $static = [System.Drawing.Bitmap]::new($staticPath)
                            try {
                                for ($x = [int]($left + 2 * $scale); $x -lt $left + $barBounds.Width - 2 * $scale; $x++) {
                                    for ($y = [int][Math]::Ceiling($top); $y -lt [Math]::Floor($top + $barBounds.Height); $y++) {
                                        if ($bitmap.GetPixel($x, $y).ToArgb() -ne $static.GetPixel($x, $y).ToArgb()) {
                                            throw "Progress must be static with $($case[2]), not just visually dimmed."
                                        }
                                    }
                                }
                            }
                            finally { $static.Dispose() }
                        }
                    }
                    finally { $bitmap.Dispose() }
                    if ($captureTopmost) {
                        if (-not [UiReviewNativeWindow]::SetWindowPos(
                                $windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
                            throw [System.ComponentModel.Win32Exception]::new()
                        }
                        $captureTopmost = $false
                    }
                }
                else {
                    Write-Host "480-DIP scan geometry/value/focus assertions enabled; capture helper requires at least 640 physical pixels."
                }
                $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Wait-DeviceScan
                $restored = Find-SidebarElement AutomationId ScanButton
                if (-not $restored.Current.HasKeyboardFocus -or
                    (Find-SidebarElement AutomationId ScanProgressBar -Optional) -or
                    (Find-SidebarElement AutomationId CancelButton -Optional)) {
                    throw "Cancellation must restore keyboard focus and clear active progress/action presentation."
                }
                Remove-Item -LiteralPath $scanHoldPath, ($scanHoldPath + ".progress")
                if ($null -ne $highContrast) {
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
                    $highContrast = $null
                    Start-Sleep -Seconds 2
                }
                if ($null -ne $animations) {
                    [SidebarReviewKeyboard]::SetAnimations($animations)
                    $animations = $null
                }
            }
        }
        Write-Host "Single-position action, actual filled thickness, low/90% progress, cancellation/focus and narrow layouts passed in every theme."
    }
    finally {
        if ($null -ne $highContrast) { [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast) }
        if ($null -ne $animations) { [SidebarReviewKeyboard]::SetAnimations($animations) }
        if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
        if (Test-Path -LiteralPath ($scanHoldPath + ".progress")) { Remove-Item -LiteralPath ($scanHoldPath + ".progress") }
        if ($captureTopmost -and -not [UiReviewNativeWindow]::SetWindowPos(
                $windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        Wait-DeviceScan
    }
}

function Assert-ScaledScanAction([double] $NormalTextHeight, [double] $ScaleFactor, [int] $Width) {
    $scan = Find-SidebarElement AutomationId ScanButton
    $text = $scan.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text))
    $bounds = $scan.Current.BoundingRectangle
    $textBounds = if ($text) { $text.Current.BoundingRectangle } else { [System.Windows.Rect]::Empty }
    # Button padding/minimum height do not scale; text line metrics can round by one pixel.
    if ($scan.Current.Name -ne 'Scan LAN' -or -not $scan.Current.IsEnabled -or
        -not $root.Current.BoundingRectangle.Contains($bounds) -or
        -not $text -or $text.Current.IsOffscreen -or $text.Current.Name -ne 'Scan LAN' -or
        $textBounds.IsEmpty -or $textBounds.Width -le 0 -or $textBounds.Height -le 0 -or
        -not $bounds.Contains($textBounds) -or
        $textBounds.Height -lt [Math]::Floor($NormalTextHeight * $ScaleFactor) - 1) {
        Save-SidebarAppearance "scan-action-text-scale-failure-$Width"
        throw "The scaled Scan LAN label must grow without clipping at $Width DIPs. Baseline text height=$NormalTextHeight; scale ratio=$ScaleFactor; text=$textBounds; action=$bounds; window=$($root.Current.BoundingRectangle)."
    }
}

function Test-ScanTextScaling {
    if ($env:GITHUB_ACTIONS -ne 'true') {
        Write-Host 'System text-scale checks require a disposable GitHub Actions desktop.'
        return
    }
    Set-SidebarWindowWidth $expandedWidth
    Select-SidebarPage Overview "Online devices"
    Set-SidebarWindowWidth 640
    $normalScan = Find-SidebarElement AutomationId ScanButton
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $normalText = Find-UiRegressionElement -Container { $normalScan } -Condition $textCondition -Description 'unscaled Scan LAN label'
    $normalTextHeight = $normalText.Current.BoundingRectangle.Height
    $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
    $originalScale = $settings.TextScaleFactor
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $originalValue = $key.GetValue('TextScaleFactor', $null)
    $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
    $failed = $true
    try {
        Stop-SidebarApp
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [SidebarReviewKeyboard]::NotifyTextScaleChanged()
        $null = Wait-UiRegressionState -Description 'effective Windows text scale of 200 percent' -Condition {
            [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
        }
        Start-SidebarApp
        Wait-DeviceScan
        foreach ($width in @(640, 480)) {
            Set-SidebarWindowWidth $width
            Assert-ScaledScanAction -NormalTextHeight $normalTextHeight -ScaleFactor (2 / $originalScale) -Width $width
            Test-SharedScanContext OverviewPage -SentinelProperty AutomationId -Cancel
            if ($width -eq 640) { Save-SidebarAppearance 'scan-action-text-scale-200' }
        }
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
            { Stop-SidebarApp },
            {
                if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                $null = Wait-UiRegressionState -Description 'restored Windows text scale' -Condition {
                    [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01
                }
            },
            { $key.Dispose() },
            { Start-SidebarApp; Set-SidebarWindowWidth $expandedWidth; Wait-DeviceScan })
    }
}
