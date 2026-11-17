# Page contracts: device history sections, paging and row lookup.
& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Observations.ps1") -Raw
    $position = [regex]::Match($historyUi, '(?s)function Show-HistorySection.*?(?=function Assert-HistoryRows)').Value
    # Substitute only the desktop pattern token; execute the production positioning body.
    . ([scriptblock]::Create($position.Replace('[System.Windows.Automation.ScrollPattern]::Pattern', '0')))
    $script:positions = [System.Collections.Generic.List[int]]::new()
    $script:secondBottom = 320
    $script:controls = @{}
    $script:scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 50.0
    } }
    $script:scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $script:positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        $offset = $Percent * 3
        $script:controls.First.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = 100 - $offset; Bottom = 120 - $offset; Width = 100; Height = 20; IsEmpty = $false
        }
        $script:controls.Since.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = $script:secondBottom - 30 - $offset
            Bottom = $script:secondBottom - $offset; Width = 100; Height = 30; IsEmpty = $false
        }
    }
    $viewport = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 300; Top = 0; Bottom = 300; Width = 300; Height = 300; IsEmpty = $false
        }
    } }
    $script:root = $viewport
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $script:scroll }
    foreach ($id in @("First", "Since")) {
        $script:controls[$id] = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = $null
        } }
    }
    function Find-HistoryControl($Id) {
        if ($Id -eq "DeviceDetailsScroll") { return $viewport }
        return $script:controls[$Id]
    }
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    $null = Show-HistorySection First -AdditionalIds Since
    Assert-Equal $script:positions @(10) "Positioning must directly reveal Since even when the first field already fits"
    $script:secondBottom = 900
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    Assert-Throws { Show-HistorySection First -AdditionalIds Since } "*cannot fit together inside its viewport*"
    Assert-Equal $script:positions.Count 0 "An oversized grouped summary fails without an exhaustive viewport sweep"

    $script:focusCalls = [Collections.Generic.List[string]]::new()
    $script:controls.Focusable = [pscustomobject]@{ Current = [pscustomobject]@{
        IsKeyboardFocusable = $true; IsOffscreen = $true; BoundingRectangle = $null
    } }
    $script:controls.Focusable | Add-Member ScriptMethod SetFocus {
        $script:focusCalls.Add("focus")
    }
    $script:bring = [pscustomobject]@{}
    $script:bring | Add-Member ScriptMethod ScrollIntoView {
        $script:focusCalls.Add("bring")
        $script:controls.Focusable.Current.IsOffscreen = $false
        $script:controls.Focusable.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = 100; Bottom = 120; Width = 100; Height = 20; IsEmpty = $false
        }
    }
    $script:controls.Focusable | Add-Member ScriptMethod TryGetCurrentPattern {
        param($Pattern, $Result)
        $Result.Value = $script:bring
        return $true
    }
    $script:positions.Clear()
    $null = Show-HistorySection Focusable
    $null = Show-HistorySection Focusable
    Assert-Equal $script:focusCalls @("focus", "bring", "focus", "bring") "Focus precedes bring-into-view even for a previously focused section"
    Assert-Equal $script:positions.Count 0 "Supported section positioning must not fight focus with percentage scrolling"

    $script:secondBottom = 320
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    $script:controls.Since.Current | Add-Member NoteProperty IsKeyboardFocusable $true
    $script:controls.Since | Add-Member ScriptMethod SetFocus { $script:focusCalls.Add("nested focus") }
    $script:controls.Since | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Result) return $false }
    $nested = Show-HistorySection Since
    Assert-Equal $script:focusCalls[-1] "nested focus" "Nested scroll viewers must still receive focus first"
    Assert-Equal $script:positions.Count 1 "Focus that leaves a nested scroll viewer clipped must position the outer viewport once"
    Assert-Equal $nested.Current.BoundingRectangle.Top 35 "A clipped nested viewer must be revealed from its top edge"
    Assert-Equal (Test-UiRegressionElementWithin $nested $viewport $script:root) $true "The complete nested viewer must be visible"
}

& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Observations.ps1") -Raw
    . ([scriptblock]::Create([regex]::Match($historyUi, '(?s)function Assert-HistoryPage.*?(?=function Show-HistorySection)').Value))
    $script:pageIndex = 0
    $script:fakeItems = @()
    $script:reached = [Collections.Generic.List[string]]::new()
    $script:fakeList = [pscustomobject]@{}
    $script:fakeList | Add-Member ScriptMethod FindAll { param($Scope, $Condition) return $script:fakeItems }
    function Show-HistorySection($Id) { return $script:fakeList }
    function Find-HistoryControl($Id) {
        $name = switch ($Id) {
            DeviceHistoryPageStatus { "Showing $(100 * $script:pageIndex + 1)-$([Math]::Min(100 * ($script:pageIndex + 1), 205)) of 205." }
            DeviceScanHistoryCount { "205 completed scan observations" }
        }
        [pscustomobject]@{ Current = [pscustomobject]@{ Name = $name } }
    }
    function Test-UiRegressionElementWithin($Element, $Viewport, $Window) { $Element.Visible }
    foreach ($script:pageIndex in 0..2) {
        $count = [Math]::Min(100, 205 - 100 * $script:pageIndex)
        $script:fakeItems = @(0..($count - 1) | ForEach-Object {
            $second = 204 - 100 * $script:pageIndex - $_
            $time = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($second)).ToLocalTime()
            $state = if ($second % 4 -lt 2) { "present" } else { "absent" }
            $item = [pscustomobject]@{
                Current = [pscustomobject]@{
                    Name = "$($time.ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $state"
                    BoundingRectangle = [pscustomobject]@{ Height = 36 }
                }
                Visible = $false
            }
            $item | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $this }
            $item | Add-Member ScriptMethod ScrollIntoView {
                $this.Visible = $true
                $script:reached.Add($this.Current.Name)
            }
            $item
        })
        Assert-Equal @(Assert-HistoryPage $script:pageIndex -Traverse).Count $count "Validate every exact bounded row"
        $script:fakeItems[0].Current.Name = "wrong timestamp; Observed absent"
        Assert-Throws { Assert-HistoryPage $script:pageIndex } "*Wrong row/order/state*"
    }
    Assert-Equal $script:reached.Count 205 "Every observation needs a physical reachability assertion"
    Assert-Equal @($script:reached | Select-Object -Unique).Count 205 "No cross-page duplicate may satisfy traversal"
    $script:fakeItems[0].Current.Name = $script:reached[200]
    $script:fakeItems[0].Current.BoundingRectangle.Height = 12
    function Wait-UiRegressionState($Condition, $Description) {
        $result = & $Condition
        if (-not $result) { throw "Row is not fully physically visible: $Description" }
        return $result
    }
    Assert-Throws { Assert-HistoryPage 2 -Traverse } "*not fully physically visible*"
    $script:fakeItems = @()
    Assert-Throws { Assert-HistoryPage 2 } "*Expected 5 bounded rows*"
}

& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Shared.ps1") -Raw
    $findRow = [regex]::Match($historyUi, '(?s)function Find-HistoryDeviceRow.*?(?=function Open-HistoryDetails)').Value
    . ([scriptblock]::Create($findRow))
    $waits = [Collections.Generic.List[int]]::new()
    $searchPattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = 'previous' }; Changes = 0 }
    $searchPattern | Add-Member ScriptMethod SetValue { param($Value) $this.Current.Value = $Value; $this.Changes++ }
    $searchControl = [pscustomobject]@{}
    $searchControl | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $searchPattern }
    $nameCell = [pscustomobject]@{ Current = [pscustomobject]@{ Name = 'History normal' } }
    $row = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
    } }
    $row | Add-Member ScriptMethod FindFirst { param($Scope, $Condition) return $nameCell }
    $list = [pscustomobject]@{ Current = $row.Current }
    $list | Add-Member ScriptMethod FindAll { param($Scope, $Condition) return @($row) }
    function Select-HistoryDevices {}
    function Start-Sleep { param($Milliseconds) $waits.Add($Milliseconds) }
    function Find-HistoryControl($Value, [switch] $ByName, [switch] $Optional) {
        if ($Value -eq 'Search devices') { return $searchControl }
        if ($Value -eq 'ResultsList') { return $list }
        throw "Unexpected history lookup '$Value'."
    }
    function Wait-UiRegressionState([scriptblock] $Condition, [string] $Description) {
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            $result = & $Condition
            if ($result) { return $result }
        }
        throw "Timed out waiting for $Description."
    }
    $null = Find-HistoryDeviceRow 'History normal'
    $null = Find-HistoryDeviceRow 'History normal'
    Assert-Equal $searchPattern.Changes 1 'Repeated assertions must not reapply the same search'
    Assert-Equal $waits @(300) 'A changed filter retains its original debounce settling; unchanged filters need none'
    $nameCell.Current.Name = 'History virtual'
    Assert-Throws { Find-HistoryDeviceRow 'History normal' } "*Timed out*exactly one visible history device matching 'History normal'*"
    $nameCell.Current.Name = 'History normal'
    $row.Current.IsOffscreen = $true
    Assert-Throws { Find-HistoryDeviceRow 'History normal' } "*Timed out*exactly one visible history device matching 'History normal'*"
}
