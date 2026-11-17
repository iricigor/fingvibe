# Completed-observation helpers: paging, rows, table rendering and sections.
function Wait-HistoryPage([int] $Page, [int] $After = 0, [string] $State = "Ready") {
    Wait-UiRegressionSurfaceState -GetElement { Find-HistoryControl DeviceScanHistoryExpander -Optional } `
        -Description "Completed observations" -Selection "Page $Page" -State $State -After $After
}

function Move-HistoryPage([string] $Id, [int] $Page, [switch] $Keyboard, [string] $State = "Ready") {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-HistoryControl DeviceScanHistoryExpander } `
        -Description "Completed observations").Request
    $button = Show-HistorySection $Id
    if ($Keyboard) {
        $button.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait(" ")
    }
    else { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $null = Wait-HistoryPage $Page $before $State
}

function Assert-HistoryPage([int] $PageIndex, [switch] $Traverse) {
    $start = 100 * $PageIndex
    $count = [Math]::Min(100, 205 - $start)
    if ((Find-HistoryControl DeviceHistoryPageStatus).Current.Name -notlike "Showing $($start + 1)-$($start + $count) of 205.*" -or
        (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "205 completed scan observations") {
        throw "Incorrect scoped count/range on observation page $PageIndex."
    }
    $list = Show-HistorySection DeviceScanHistoryList
    $pageViewport = Find-HistoryControl DeviceDetailsScroll
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($items.Count -ne $count) { throw "Expected $count bounded rows, got $($items.Count)." }
    $rowHeight = ($items | ForEach-Object { $_.Current.BoundingRectangle.Height } | Measure-Object -Maximum).Maximum
    if ($rowHeight -le 0) { throw "The observation page has no rendered row geometry." }
    $labels = @()
    for ($index = 0; $index -lt $count; $index++) {
        $second = 204 - $start - $index
        $time = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($second)).ToLocalTime()
        $state = if ($second % 4 -lt 2) { "present" } else { "absent" }
        $expected = "$($time.ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $state"
        $item = $items[$index]
        if ($item.Current.Name -cne $expected) { throw "Wrong row/order/state on page ${PageIndex}: '$($item.Current.Name)', expected '$expected'." }
        if ($Traverse) {
            $item.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()
            $null = Wait-UiRegressionState -Description "physically visible observation '$expected'" -Condition {
                if ($item.Current.BoundingRectangle.Height -ge $rowHeight - 1 -and
                    (Test-UiRegressionElementWithin $item $list $script:root) -and
                    (Test-UiRegressionElementWithin $item $pageViewport $script:root)) { return $true }
            }
        }
        $labels += $expected
    }
    return $labels
}

function Assert-HistoryScrollMovement {
    $list = Show-HistorySection DeviceScanHistoryList
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem))
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if (-not $scroll.Current.VerticallyScrollable) { throw "The 100-row page must be scrollable." }
    $scroll.SetScrollPercent(-1, 0)
    $firstVisible = {
        for ($index = 0; $index -lt $items.Count; $index++) {
            $bounds = $items[$index].Current.BoundingRectangle
            $viewport = $list.Current.BoundingRectangle
            if (-not $bounds.IsEmpty -and $bounds.Height -gt 0 -and $bounds.Width -gt 0 -and
                -not $items[$index].Current.IsOffscreen -and
                $bounds.Top -ge $viewport.Top -and $bounds.Bottom -le $viewport.Bottom) {
                return [pscustomobject]@{
                    Index = $index; Label = $items[$index].Current.Name
                    Top = $bounds.Top; Bottom = $bounds.Bottom
                }
            }
        }
    }
    $before = Wait-UiRegressionState -Condition $firstVisible -Description "first visible history row"
    foreach ($amount in @("LargeIncrement", "LargeIncrement", "LargeIncrement", "SmallDecrement", "LargeIncrement")) {
        Write-Host "History $amount before: row $($before.Index), bounds $($before.Top)-$($before.Bottom), scroll $($scroll.Current.VerticalScrollPercent)%."
        $scroll.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount,
            [System.Windows.Automation.ScrollAmount]::$amount)
        $after = Wait-UiRegressionState -Description "$amount to move actual visible rows without snap-back" -Condition {
            $current = & $firstVisible
            if ($current -and $(if ($amount -eq "SmallDecrement") {
                    $current.Index -lt $before.Index -or ($current.Index -eq $before.Index -and
                        ($current.Top -gt $before.Top -or $current.Bottom -gt $before.Bottom))
                }
                else {
                    $current.Index -gt $before.Index -or ($current.Index -eq $before.Index -and
                        ($current.Top -lt $before.Top -or $current.Bottom -lt $before.Bottom))
                })) { return $current }
        }
        Write-Host "History $amount moved row $($before.Index) at $($before.Top)-$($before.Bottom) '$($before.Label)' -> $($after.Index) at $($after.Top)-$($after.Bottom) '$($after.Label)'."
        $before = $after
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-scroll-movement.png")
    $scroll.SetScrollPercent(-1, 0)
}

function Show-HistorySection([string] $Id, [int] $TopMargin = 35, [string[]] $AdditionalIds = @()) {
    $ids = @($Id) + $AdditionalIds
    $call = Start-UiRegressionCall positioning
    try {
        $target = Find-HistoryControl $Id
        $scrollItem = $null
        if ($AdditionalIds.Count -eq 0 -and ($target.Current.IsKeyboardFocusable -or
            $target.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem))) {
            if ($target.Current.IsKeyboardFocusable) { $target.SetFocus() }
            if ($scrollItem -or $target.TryGetCurrentPattern(
                [System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem)) { $scrollItem.ScrollIntoView() }
            $script:historySectionBounds = $null
            return Wait-UiRegressionState -Description "visible history section '$Id'" -Condition {
                $current = Find-HistoryControl $Id -Optional
                if (-not (Test-UiRegressionElementWithin $current (Find-HistoryControl DeviceDetailsScroll) $script:root)) {
                    $null = Show-UiRegressionScrollTargets -Description "Scan-history section '$Id'" -TopMargin $TopMargin -BottomMargin 10 `
                        -GetViewport { Find-HistoryControl DeviceDetailsScroll } -GetWindow { $script:root } `
                        -GetTargets { Find-HistoryControl $Id }
                    $script:historySectionBounds = $null
                    return
                }
                # Expander and tab layout can still be moving; require the same position on consecutive polls.
                $bounds = $current.Current.BoundingRectangle
                $stable = $bounds -eq $script:historySectionBounds
                $script:historySectionBounds = $bounds
                if ($stable) { return $current }
            }
        }
        Show-UiRegressionScrollTargets -Description "Scan-history section '$Id'" -TopMargin $TopMargin -BottomMargin 10 `
            -GetViewport { Find-HistoryControl DeviceDetailsScroll } -GetWindow { $script:root } `
            -GetTargets { $ids | ForEach-Object { Find-HistoryControl $_ } }
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-HistoryRows([string] $Capture, [int] $LastIndex = 4) {
    $count = $LastIndex + 1
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "$count completed scan observations") {
        throw "Expected $count individual completed scans; got '$((Find-HistoryControl DeviceScanHistoryCount).Current.Name)' in '$((Find-HistoryControl DeviceHistoryScope).Current.Name)'."
    }
    $list = Show-HistorySection DeviceScanHistoryList
    $positioned = "list $($list.Current.BoundingRectangle) in page $((Find-HistoryControl DeviceDetailsScroll).Current.BoundingRectangle)"
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $seen = @{}
    $itemCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    foreach ($percent in @(0, 50, 100)) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 100
        $times = @()
        foreach ($item in $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)) {
            if (-not (Test-UiRegressionElementWithin $item $list $script:root)) {
                # Bounds are clipped to the visible area; rows below the page edge bring themselves into view.
                $rowScroll = $null
                if (-not $item.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $rowScroll)) { continue }
                $rowScroll.ScrollIntoView()
                Start-Sleep -Milliseconds 150
                if (-not (Test-UiRegressionElementWithin $item $list $script:root)) { continue }
            }
            $texts = @($item.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition) |
                ForEach-Object { $_.Current.Name })
            if ($texts.Count -eq 0) { continue }
            if ($texts.Count -ne 2) { throw "Each scan row must expose friendly When and Result: $texts." }
            $matching = @(0..$LastIndex | Where-Object { $item.Current.Name.StartsWith((Get-HistoryExactTime $_) + ";") })
            if ($matching.Count -ne 1) { throw "Unexpected exact scan timestamp '$($item.Current.Name)'." }
            $time = (Get-HistoryLocalTime $matching[0]).ToString("yyyy-MM-dd HH:mm:ss")
            $state = if ($matching[0] -in @(2, 3)) { "Absent" } else { "Present" }
            $result = if ($state -eq "Present") { "Responded" } else { "Scanned, no response" }
            if ($texts[1] -ne $result -or $texts[0] -ne (Get-FriendlyHistoryTime (Get-HistoryLocalTime $matching[0]))) {
                throw "Incorrect scan observation: $texts."
            }
            $label = "$((Get-HistoryLocalTime $matching[0]).ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $($state.ToLowerInvariant())"
            if ($item.Current.Name -ne $label) {
                throw "Scan row lacks an accessible full timestamp with UTC offset and observed state."
            }
            $seen[$time] = $true
            $times += $time
        }
        if (($times -join "|") -ne (($times | Sort-Object -Descending) -join "|")) {
            throw "Scan rows are not newest first: $times."
        }
    }
    if ($seen.Count -ne $count) {
        throw "Not all $count scans are reachable in the native history list; saw $($seen.Keys -join ', '). Positioned $positioned; finally list $($list.Current.BoundingRectangle)."
    }
    foreach ($index in 0..$LastIndex) {
        if (-not $seen.ContainsKey((Get-HistoryLocalTime $index).ToString("yyyy-MM-dd HH:mm:ss"))) {
            throw "Scan $index is missing from history."
        }
    }
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture.png")
}

function Assert-HistoryTableRendering([string] $Capture) {
    $list = Show-HistorySection DeviceScanHistoryList 85
    $headers = @("When (local)", "Result") | ForEach-Object { Find-HistoryControl $_ -ByName }
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem))
    $path = Join-Path $ScreenshotDirectory "$Capture.png"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle $path
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $bitmap = [System.Drawing.Bitmap]::FromFile($path)
    try {
        $stripeColors = @()
        $states = @{}
        # Bounds are clipped to the visible area; only rows at full height have their whole status dot rendered.
        $fullHeight = ($items | ForEach-Object { $_.Current.BoundingRectangle.Height } | Measure-Object -Maximum).Maximum
        foreach ($item in $items) {
            if ($item.Current.IsOffscreen -or $item.Current.BoundingRectangle.Height -lt $fullHeight - 1) { continue }
            $texts = $item.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text))
            if ($texts.Count -ne 2) { throw "Rendered table row must expose two columns." }
            for ($column = 0; $column -lt 2; $column++) {
                $bounds = $texts[$column].Current.BoundingRectangle
                $header = $headers[$column].Current.BoundingRectangle
                $expectedLeft = $header.Left + $(if ($column -eq 1) { 18 * [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96 } else { 0 })
                if ([Math]::Abs($bounds.Left - $expectedLeft) -gt 3 -or $bounds.Right -gt $header.Right + 3) {
                    throw "Column $column is misaligned/clipped relative to its header: $bounds / $header."
                }
            }
            $row = $item.Current.BoundingRectangle
            $stripeColors += $bitmap.GetPixel([int]($row.Left - $window.Left + 3), [int]($row.Top - $window.Top + 3)).ToArgb()
            $status = $texts[1].Current.BoundingRectangle
            $green = 0
            $red = 0
            for ($x = [int]($status.Left - $window.Left - 20); $x -lt $status.Left - $window.Left; $x++) {
                for ($y = [int]($status.Top - $window.Top); $y -lt $status.Bottom - $window.Top; $y++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ($pixel.G -gt $pixel.R + 20 -and $pixel.G -gt $pixel.B + 10) { $green++ }
                    if ($pixel.R -gt $pixel.G + 20 -and $pixel.R -gt $pixel.B + 10) { $red++ }
                }
            }
            $state = $texts[1].Current.Name
            if (($state -eq "Responded" -and $green -lt 20) -or ($state -eq "Scanned, no response" -and $red -lt 20)) {
                throw "$state row lacks its rendered green/red status dot."
            }
            $states[$state] = $true
        }
        if (($stripeColors | Select-Object -Unique).Count -lt 2) { throw "History rows lack visible zebra stripes." }
        if ($states.Count -ne 2) { throw "Rendering evidence must include both present and absent rows." }
    }
    finally { $bitmap.Dispose() }
}
