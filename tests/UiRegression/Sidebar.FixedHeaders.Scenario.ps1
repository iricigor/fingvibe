# #656: page titles and Back stay fixed below the network bar while only the page body scrolls.
$fixedHeaderPages = @(
    @{ Nav = "Overview"; Title = "Overview"; Scroll = "OverviewPage" },
    @{ Nav = "Network"; Title = "Network"; Scroll = "NetworkPage" },
    @{ Nav = "People & rooms"; Title = "People & rooms"; Scroll = "PeopleRoomsPage" },
    @{ Nav = "Settings"; Title = "Settings"; Scroll = "SettingsPage" },
    @{ Nav = "Tools"; Title = "Tools"; Scroll = "ToolsLanding" },
    @{ Nav = "Tools"; Card = "NetworkHealthCard"; Title = "Network health"; Back = "Back to Tools"; Scroll = "NetworkHealthScroll" }
)

$fixedHeaderOriginalBounds = Get-UiReviewWindowBounds $windowHandle
$setFixedHeaderWindow = {
    param([int] $LogicalWidth, [int] $LogicalHeight)
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if (-not [UiReviewNativeWindow]::SetWindowPos(
            $windowHandle, [IntPtr]::Zero, $area.Left, $area.Top, [int] ($LogicalWidth * $scale),
            [int] ($LogicalHeight * $scale), 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 750
}

$findFixedHeaderTargets = {
    param($Page, $Viewport)
    # The page title is the largest visible text with that name in the body column; navigation labels are excluded.
    $column = $Viewport.Current.BoundingRectangle
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Page.Title),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text))
    $title = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) |
        Where-Object {
            $bounds = $_.Current.BoundingRectangle
            -not $_.Current.IsOffscreen -and $bounds.Height -gt 0 -and
                $bounds.Left -ge $column.Left - $scale -and $bounds.Right -le $column.Right + $scale
        } |
        Sort-Object { $_.Current.BoundingRectangle.Height } -Descending | Select-Object -First 1)
    if ($title.Count -eq 0) { return $null }
    $targets = [ordered]@{ title = $title[0] }
    if ($Page.Back) {
        $back = Find-SidebarElement Name $Page.Back -Optional
        if (-not $back) { return $null }
        $targets.back = $back
    }
    return $targets
}

$testFixedHeaders = {
    param([string] $Variant, [switch] $RequireOverflow)
    foreach ($page in $fixedHeaderPages) {
        # Navigation is hidden in the narrow minimal layout, so select at full width before shrinking.
        & $setFixedHeaderWindow $expandedWidth 720
        Select-SidebarPage $page.Nav $page.Nav
        if ($page.Card) {
            $cardCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $page.Card)
            $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cardCondition).
                GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        & $setFixedHeaderWindow 640 520
        $viewport = Find-SidebarElement AutomationId $page.Scroll
        $targets = Wait-UiRegressionState -Description "fixed '$($page.Title)' header ($Variant)" -Condition {
            & $findFixedHeaderTargets $page $viewport
        }
        $window = $root.Current.BoundingRectangle
        $bar = (@("DetectedNetworkLabel", "NetworkPicker", "ScanFreshnessText", "ScanButton") |
            ForEach-Object { (Find-SidebarElement AutomationId $_).Current.BoundingRectangle.Bottom } |
            Measure-Object -Maximum).Maximum
        $before = @{}
        foreach ($name in $targets.Keys) {
            $bounds = $targets[$name].Current.BoundingRectangle
            $before[$name] = $bounds
            if (-not $window.Contains($bounds) -or $bounds.Top -lt $bar - $scale) {
                Save-SidebarAppearance "fixed-header-failure"
                throw "'$($page.Title)' $name must be fully visible below the network bar ($Variant). Bounds=$bounds; bar bottom=$bar; window=$window."
            }
        }
        $scroll = $viewport.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if (-not $scroll.Current.VerticallyScrollable) {
            if ($RequireOverflow) { throw "'$($page.Title)' must overflow its body in a short window with enlarged text ($Variant)." }
            continue
        }
        # List content can still grow after the resize; keep requesting the bottom until it holds.
        $null = Wait-UiRegressionState -Description "'$($page.Title)' body scrolled to the bottom ($Variant)" -Condition {
            if ($scroll.Current.VerticalScrollPercent -ge 99.5) { return $true }
            $scroll.SetScrollPercent(-1, 100)
            $false
        }
        $after = Wait-UiRegressionState -Description "'$($page.Title)' header after scrolling ($Variant)" -Condition {
            & $findFixedHeaderTargets $page $viewport
        }
        foreach ($name in $before.Keys) {
            $bounds = $after[$name].Current.BoundingRectangle
            if ($after[$name].Current.IsOffscreen -or -not $window.Contains($bounds) -or
                [Math]::Abs($bounds.Top - $before[$name].Top) -gt $scale -or
                [Math]::Abs($bounds.Left - $before[$name].Left) -gt $scale) {
                Save-SidebarAppearance "fixed-header-failure"
                throw "'$($page.Title)' $name must stay visible and stationary while the body scrolls ($Variant). Before=$($before[$name]); after=$bounds."
            }
        }
        if ($page.Back -and $Variant -eq "text-200") { Save-SidebarAppearance "fixed-header-text-scale-200" }
        $scroll.SetScrollPercent(-1, 0)
        if ($page.Back) {
            (Find-SidebarElement Name $page.Back).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
    }
}

& $testFixedHeaders "text-100"
if ($env:GITHUB_ACTIONS -eq 'true') {
    $fixedHeaderSettings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
    $fixedHeaderOriginalScale = $fixedHeaderSettings.TextScaleFactor
    $fixedHeaderKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $fixedHeaderOriginalValue = $fixedHeaderKey.GetValue('TextScaleFactor', $null)
    $fixedHeaderOriginalKind = if ($null -ne $fixedHeaderOriginalValue) { $fixedHeaderKey.GetValueKind('TextScaleFactor') } else { $null }
    $fixedHeaderFailed = $true
    try {
        Stop-SidebarApp
        $fixedHeaderKey.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [SidebarReviewKeyboard]::NotifyTextScaleChanged()
        $null = Wait-UiRegressionState -Description 'fixed-header text scale of 200 percent' -Condition {
            [Math]::Abs($fixedHeaderSettings.TextScaleFactor - 2) -lt 0.01
        }
        Start-SidebarApp
        & $testFixedHeaders "text-200" -RequireOverflow
        $fixedHeaderFailed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $fixedHeaderFailed -Steps @(
            { Stop-SidebarApp },
            {
                if ($null -eq $fixedHeaderOriginalValue) { $fixedHeaderKey.DeleteValue('TextScaleFactor', $false) }
                else { $fixedHeaderKey.SetValue('TextScaleFactor', $fixedHeaderOriginalValue, $fixedHeaderOriginalKind) }
                [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                $null = Wait-UiRegressionState -Description 'restored fixed-header text scale' -Condition {
                    [Math]::Abs($fixedHeaderSettings.TextScaleFactor - $fixedHeaderOriginalScale) -lt 0.01
                }
            },
            { $fixedHeaderKey.Dispose() },
            { Start-SidebarApp })
    }
}
else {
    Write-Host 'Enlarged-text fixed-header checks require a disposable GitHub Actions desktop.'
}
if (-not [UiReviewNativeWindow]::SetWindowPos(
        $windowHandle, [IntPtr]::Zero, $fixedHeaderOriginalBounds.Left, $fixedHeaderOriginalBounds.Top,
        $fixedHeaderOriginalBounds.Width, $fixedHeaderOriginalBounds.Height, 0x0044)) {
    throw [System.ComponentModel.Win32Exception]::new()
}
Set-SidebarWindowWidth $expandedWidth
Write-Host "Fixed page titles and Back stayed visible below the network bar while page bodies scrolled."
