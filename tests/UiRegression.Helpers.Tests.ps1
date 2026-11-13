$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.PeopleRooms.Helpers.ps1')

function Assert-Regression([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-RegressionFailure([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$state = @{ Attempts = 0 }
$result = Wait-UiRegressionState -Description 'current result' -PollMilliseconds 1 -Condition {
    $state.Attempts++
    if ($state.Attempts -eq 2) { return 'ready' }
}
Assert-Regression ($result -eq 'ready' -and $state.Attempts -eq 2) 'Wait must return the current successful result.'
foreach ($condition in @({ $false }, { $null }, {})) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Assert-RegressionFailure { Wait-UiRegressionState -Condition $condition -Description 'bounded failure' -TimeoutMilliseconds 20 -PollMilliseconds 5 } '*20 ms*bounded failure*'
    Assert-Regression ($clock.ElapsedMilliseconds -ge 20 -and $clock.ElapsedMilliseconds -lt 2000) 'Wait did not respect its deadline.'
}
Assert-RegressionFailure { Wait-UiRegressionState -Description 'unexpected error' -Condition { throw 'unexpected condition error' } } 'unexpected condition error'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
Add-Type -TypeDefinition @'
public static class SidebarReviewKeyboard
{
    public static int Taps;
    public static void Tap(int key) { Taps++; }
}
'@
foreach ($case in @('completed', 'cancelled', 'hidden', 'missing', 'name')) {
    & {
        . (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Scans.Helpers.ps1')
        $scanHoldPath = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-scan-context-$([Guid]::NewGuid().ToString('N')).hold"
        $state = @{ Finished = $false; ContextChecks = 0 }
        [SidebarReviewKeyboard]::Taps = 0
        $page = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 900; Height = 600 }
        } }
        $heading = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
        } }
        $selection = [pscustomobject]@{}
        $selection | Add-Member ScriptMethod GetSelection { return @([pscustomobject]@{ Current = @{ Name = 'Review LAN' } }) }
        $picker = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $true } }
        $picker | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return [pscustomobject]@{ Current = $selection } }
        $scan = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $true; HasKeyboardFocus = $true } }
        $scan | Add-Member ScriptMethod SetFocus {}
        $cancelControl = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $true; HasKeyboardFocus = $true } }
        function Focus-SidebarWindow {}
        function Wait-UiRegressionState {
            param($Condition, $Description)
            $result = & $Condition
            if (-not $result) { throw "Missing $Description." }
            return $result
        }
        function Wait-DeviceScan {
            $state.Finished = $true
            $heading.Current.IsOffscreen = $case -ne 'name'
            $page.Current.IsOffscreen = $case -eq 'hidden'
        }
        function Find-SidebarElement {
            param($Property, $Value, [switch] $Optional)
            $scanning = [SidebarReviewKeyboard]::Taps -gt 0 -and -not $state.Finished
            switch ($Value) {
                NetworkPicker { $picker.Current.IsEnabled = -not $scanning; return $picker }
                ScanButton { if (-not $scanning) { return $scan }; return $null }
                CancelButton { if ($scanning) { return $cancelControl }; return $null }
                ScanProgressBar { return [pscustomobject]@{} }
            }
            $state.ContextChecks++
            Find-UiRegressionElement -Container { 'review window' } -Condition "$Property/$Value" `
                -Description "visible scan context '$Value'" -Optional:$Optional -Find {
                    param($Owner, $Match)
                    if ($Match -eq 'AutomationId/NetworkPage') {
                        if ($case -ne 'missing' -or -not $state.Finished) { return $page }
                    }
                    elseif ($Match -eq 'Name/Public IP address') { return $heading }
                }
        }
        $arguments = if ($case -eq 'name') {
            @{ Sentinel = 'Public IP address' }
        } else {
            @{ Sentinel = 'NetworkPage'; SentinelProperty = 'AutomationId'; Cancel = $case -eq 'cancelled' }
        }
        try {
            if ($case -in @('hidden', 'missing')) {
                Assert-RegressionFailure { Test-SharedScanContext @arguments } "*visible scan context 'NetworkPage'*"
            }
            else {
                Test-SharedScanContext @arguments
            }
            Assert-Regression ($state.Finished -and $state.ContextChecks -eq 3) 'Scan context must be checked before, during and after scanning.'
            Assert-Regression ([SidebarReviewKeyboard]::Taps -eq $(if ($case -eq 'cancelled') { 2 } else { 1 })) 'Context checks must preserve keyboard scan/cancel entry.'
            Assert-Regression (-not (Test-Path -LiteralPath $scanHoldPath)) 'Context failures must still release the isolated scan hold.'
            if ($case -in @('completed', 'cancelled')) {
                Assert-Regression ($heading.Current.IsOffscreen -and -not $page.Current.IsOffscreen) 'The retained Network viewport must remain valid when its heading scrolls offscreen.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
        }
    }
}
foreach ($initialWidth in @(480, 640)) {
    & {
        . (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Scans.Helpers.ps1')
        $expandedWidth = 1280
        $state = @{ Width = $initialWidth; OverviewSelected = $false; BaselineMeasured = $false }
        function Set-SidebarWindowWidth([int] $LogicalWidth) { $state.Width = $LogicalWidth }
        function Select-SidebarPage([string] $Name, [string] $Sentinel) {
            Assert-Regression ($state.Width -eq $expandedWidth) 'Text-scale setup must make navigation reachable before selecting Overview.'
            Assert-Regression ($Name -eq 'Overview' -and $Sentinel -eq 'Online devices') 'Text-scale setup must retain its Overview context.'
            $state.OverviewSelected = $true
        }
        function Find-SidebarElement($Property, $Value) {
            Assert-Regression ($state.OverviewSelected -and $state.Width -eq 640) 'The unscaled scan baseline must still be measured at 640 DIPs.'
            Assert-Regression ($Property -eq 'AutomationId' -and $Value -eq 'ScanButton') 'Text-scale setup must measure the shared scan action.'
            $state.BaselineMeasured = $true
            throw 'Text-scale baseline reached without desktop automation.'
        }
        $previousActions = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = 'true'
            Assert-RegressionFailure { Test-ScanTextScaling } 'Text-scale baseline reached without desktop automation.'
            Assert-Regression $state.BaselineMeasured 'Text-scale setup did not reach its narrow baseline.'
        }
        finally { $env:GITHUB_ACTIONS = $previousActions }
    }
}
foreach ($case in @('scaled', 'unscaled', 'wrapped', 'clipped', 'missing', 'disabled', 'outside')) {
    & {
        . (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Scans.Helpers.ps1')
        $root = [pscustomobject]@{ Current = @{ BoundingRectangle = [System.Windows.Rect]::new(0, 0, 640, 720) } }
        $text = [pscustomobject]@{ Current = @{
            Name = 'Scan LAN'; IsOffscreen = $false
            BoundingRectangle = [System.Windows.Rect]::new(100, 105,
                $(if ($case -in @('unscaled', 'wrapped')) { 55 } else { 106 }),
                $(if ($case -eq 'unscaled') { 19 } else { 34 }))
        } }
        $scan = [pscustomobject]@{ Current = @{
            Name = 'Scan LAN'; IsEnabled = $case -ne 'disabled'
            BoundingRectangle = [System.Windows.Rect]::new(80, 100, 240, 47)
        } }
        if ($case -eq 'clipped') { $text.Current.BoundingRectangle = [System.Windows.Rect]::new(300, 105, 110, 37) }
        if ($case -eq 'outside') { $root.Current.BoundingRectangle = [System.Windows.Rect]::new(0, 0, 100, 720) }
        $scan | Add-Member ScriptMethod FindFirst {
            param($Scope, $Condition)
            Assert-Regression ($Condition.Value -eq [System.Windows.Automation.ControlType]::Text.Id) 'Scale checks must measure the actual text peer, not button padding.'
            if ($case -ne 'missing') { return $text }
        }
        function Find-SidebarElement($Property, $Value) { return $scan }
        function Save-SidebarAppearance($Name) { $state.Captured = $true }
        $state = @{ Captured = $false }
        if ($case -eq 'scaled') {
            Assert-ScaledScanAction -NormalTextBounds ([System.Windows.Rect]::new(0, 0, 55, 19)) -Width 640
            Assert-Regression (-not $state.Captured) 'Correctly scaled text must not produce failure evidence.'
        }
        else {
            Assert-RegressionFailure { Assert-ScaledScanAction -NormalTextBounds ([System.Windows.Rect]::new(0, 0, 55, 19)) -Width 640 } '*label must grow without clipping*'
            Assert-Regression $state.Captured 'Scale failures must capture evidence before settings restoration.'
        }
    }
}
foreach ($focusable in @($true, $false)) {
    & {
        $state = @{ PageLookups = 0; FocusCalls = 0; PositionCalls = 0 }
        $target = [pscustomobject]@{ Current = [pscustomobject]@{
            IsKeyboardFocusable = $focusable; IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
        } }
        $target | Add-Member ScriptMethod SetFocus { $state.FocusCalls++ }
        $target | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Output) return $false }
        $page = [pscustomobject]@{}
        $page | Add-Member ScriptMethod FindFirst {
            param($Scope, [System.Windows.Automation.Condition] $Match)
            Assert-Regression ($Match.Value -eq 'EditPersonDetailButton') 'Person lookup lost its target condition inside a wait.'
            return $target
        }
        $page | Add-Member ScriptMethod FindAll {
            param($Scope, [System.Windows.Automation.Condition] $Match)
            Assert-Regression ($Match.Value -eq 'EditPersonDetailButton') 'Visible lookup must retain the same Person target.'
            return @($target)
        }
        $root = [pscustomobject]@{}
        $root | Add-Member ScriptMethod FindFirst {
            param($Scope, [System.Windows.Automation.Condition] $Match)
            Assert-Regression ($Match.Value -eq 'PersonDetailPage') 'Person lookup must remain page-scoped.'
            $state.PageLookups++
            if ($state.PageLookups -gt 1) { return $page }
        }
        function Show-UiRegressionScrollTargets {
            param($Description, $GetViewport, $GetTargets, $GetWindow)
            $state.PositionCalls++
            Wait-UiRegressionState -Description $Description -Condition { & $GetTargets }
        }
        $found = Find-PeopleRoomsElement AutomationId EditPersonDetailButton PersonDetailPage
        Assert-Regression ($found -eq $target -and $state.PageLookups -ge 3) 'Person lookup must await and reacquire its page.'
        Assert-Regression ($state.FocusCalls -eq [int]$focusable) 'Focusable Person controls must retain focus-based positioning.'
        Assert-Regression ($state.PositionCalls -eq [int](-not $focusable)) 'Nonfocusable Person controls must retain viewport positioning.'
    }
}
& {
    $state = @{ Observations = 0; Invocations = 0 }
    $dialog = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false
        BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 100 }
    } }
    $root = [pscustomobject]@{}
    $root | Add-Member ScriptMethod FindFirst {
        param($Scope, $Match)
        $state.Observations++
        if ($state.Observations -lt 3) { return $dialog }
        return $null
    }
    $invoke = [pscustomobject]@{}
    $invoke | Add-Member ScriptMethod Invoke { $state.Invocations++ }
    $button = [pscustomobject]@{}
    $button | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $invoke }
    function Find-PeopleRoomsElement {
        param($Property, $Value, $OwnerId)
        Assert-Regression ($OwnerId -eq 'PeopleRoomsDialog') 'Dialog actions must not fall back to a same-named button on the underlying detail page.'
        return $button
    }
    foreach ($action in @('Cancel', 'Delete')) {
        $state.Observations = 0
        Invoke-PeopleRoomsElement Name $action
        Assert-Regression ($state.Observations -eq 3) "$action must await actual dialog dismissal before another dialog or page lookup."
    }
    $state.Observations = 0
    Invoke-PeopleRoomsElement Name Save
    Assert-Regression ($state.Observations -eq 0 -and $state.Invocations -eq 3) 'Save must allow validation and persistence errors to retain their dialog.'
}
& {
    function New-TestRectangle([double] $Left, [double] $Top, [double] $Width, [double] $Height) {
        [pscustomobject]@{
            Left = $Left; Top = $Top; Width = $Width; Height = $Height
            Right = $Left + $Width; Bottom = $Top + $Height; IsEmpty = $false
        }
    }
    function New-BoundedElement([double] $Left, [double] $Top, [double] $Width, [double] $Height) {
        [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = New-TestRectangle $Left $Top $Width $Height
        } }
    }
    $window = New-BoundedElement 0 0 600 800
    $viewport = New-BoundedElement 20 100 560 900
    $cell = New-BoundedElement 20 768 36 32
    Assert-Regression (Test-UiRegressionElementWithin $cell $viewport $window) 'A cell at the visible bottom edge must not fail an invented 16-pixel inset.'
    foreach ($bounds in @(
        (New-TestRectangle 20 769 36 32),
        (New-TestRectangle 19 768 36 32),
        (New-TestRectangle 545 768 36 32),
        (New-TestRectangle 20 99 36 32)
    )) {
        $cell.Current.BoundingRectangle = $bounds
        Assert-Regression (-not (Test-UiRegressionElementWithin $cell $viewport $window)) 'Even one pixel outside the window or nested viewport must remain a failure.'
    }
    $cell.Current.BoundingRectangle = New-TestRectangle 20 768 36 32
    $cell.Current.IsOffscreen = $true
    Assert-Regression (-not (Test-UiRegressionElementWithin $cell $viewport $window)) 'Offscreen peers cannot prove rendered visibility.'

    $viewport = New-BoundedElement 0 0 500 300
    $window = New-BoundedElement 0 0 500 300
    $first = New-BoundedElement 10 900 100 20
    $last = New-BoundedElement 10 1100 100 30
    $positions = [Collections.Generic.List[double]]::new()
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    }; MoveBounds = $true }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $delta = ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        if ($this.MoveBounds) {
            foreach ($target in @($first, $last)) {
                $bounds = $target.Current.BoundingRectangle
                $target.Current.BoundingRectangle = New-TestRectangle $bounds.Left ($bounds.Top - $delta) $bounds.Width $bounds.Height
            }
        }
    }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $arguments = @{
        GetViewport = { $viewport }; GetWindow = { $window }; GetTargets = { $first; $last }
        Description = 'grouped summary'; TopMargin = 35; BottomMargin = 10
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $first -and $positions.Count -eq 1 -and $positions[0] -eq 70) 'Grouped controls must be positioned directly from geometry, not a percent-by-percent sweep.'
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'The last target, not only the first, must fit above the bottom margin.'
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1) 'Already-visible groups must not scroll again.'
    $last.Current.BoundingRectangle = New-TestRectangle 10 80 100 30
    $null = Show-UiRegressionScrollTargets -Description 'Settings footer' -AlignBottom -BottomMargin 10 `
        -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $last }
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'Settings positioning must retain footer alignment without sweeping through the whole page.'
    $positions.Clear()
    $first.Current.BoundingRectangle = New-TestRectangle 10 -20 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 180 100 30
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1 -and $first.Current.BoundingRectangle.Top -ge 35) 'Positioning must also move upwards while preserving every target.'
    $scroll.Current.VerticalScrollPercent = 0.0
    $positions.Clear()
    $first.Current.BoundingRectangle = New-TestRectangle 10 100 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 260.5 100 30
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1 -and $positions[0] -gt 0 -and $positions[0] -lt 1) 'Sub-percent scroll corrections must not round to an unchanged integer percentage.'
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'Fractional positioning must retain the full viewport margin without accepting clipped content.'
    $last.Current.BoundingRectangle = New-TestRectangle 10 1000 100 30
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*cannot fit together*'
    $first.Current.BoundingRectangle = New-TestRectangle 10 900 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 1100 100 30
    $scroll.Current.VerticalScrollPercent = 0.0
    $scroll.MoveBounds = $false
    $arguments.TimeoutMilliseconds = 500
    $before = $positions.Count
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*did not move after a measured scroll adjustment*'
    Assert-Regression ($positions.Count -eq $before + 1) 'An accepted scroll percentage without rendered movement must fail, not repeat or masquerade as visibility.'
    $scroll.Current.VerticallyScrollable = $false
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*non-scrollable viewport*'

    $viewport = New-BoundedElement 0 0 500 300
    $window = New-BoundedElement 0 0 500 300
    $target = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $true; BoundingRectangle = [pscustomobject]@{
            Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
        }
    } }
    $positions = [Collections.Generic.List[double]]::new()
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    }; DocumentTop = 900.0 }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        $top = $this.DocumentTop - $Percent * 12
        if ($top + 30 -le 0 -or $top -ge 300) {
            $target.Current.IsOffscreen = $true
            $target.Current.BoundingRectangle = [pscustomobject]@{
                Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
            }
        } else {
            $target.Current.IsOffscreen = $false
            $target.Current.BoundingRectangle = New-TestRectangle 10 $top 100 30
        }
    }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $arguments = @{
        GetViewport = { $viewport }; GetWindow = { $window }; GetTargets = { $target }
        Description = 'offscreen text target'; TopMargin = 35; BottomMargin = 10
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -eq 4) 'An empty offscreen UIA rectangle must trigger bounded discovery followed by measured positioning.'
    Assert-Regression ($target.Current.BoundingRectangle.Top -ge 35 -and $target.Current.BoundingRectangle.Bottom -le 290) 'A discovered target must satisfy the complete viewport margins.'

    $scroll.Current.VerticalScrollPercent = 100
    $positions.Clear()
    $target.Current.IsOffscreen = $true
    $target.Current.BoundingRectangle = [pscustomobject]@{
        Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -le 4) 'Unknown bounds from the lower endpoint must discover content by moving back toward the viewport.'

    $actual = @{ Top = 285.0; Height = 180.0 }
    $target.Current.IsOffscreen = $false
    $target.Current.BoundingRectangle = New-TestRectangle 10 285 100 15
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $actual.Top -= ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        $visibleTop = [Math]::Max(0.0, $actual.Top)
        $visibleBottom = [Math]::Min(300.0, $actual.Top + $actual.Height)
        $target.Current.BoundingRectangle = New-TestRectangle 10 $visibleTop 100 ($visibleBottom - $visibleTop)
    }
    $positions.Clear()
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -eq 1) 'A clipped UIA bottom edge must not cause repeated tiny scroll corrections.'
    Assert-Regression ($target.Current.BoundingRectangle.Top -eq 35 -and $target.Current.BoundingRectangle.Height -eq 180) 'Positioning must reveal the full target, not accept its clipped rectangle as its true height.'
}

$rectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
$element = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; BoundingRectangle = $rectangle } }
$state = @{ Owners = 0; Lookups = 0 }
$found = Find-UiRegressionElement -Description 'reacquired owner' -Condition 'match' -Container {
    $state.Owners++
    [pscustomobject]@{ Generation = $state.Owners }
} -Find {
    param($Owner, $Match)
    $state.Lookups++
    Assert-Regression ($Owner.Generation -eq $state.Lookups -and $Match -eq 'match') 'Lookup did not use a fresh owner and condition.'
    if ($state.Lookups -eq 1) { throw [System.Windows.Automation.ElementNotAvailableException]::new() }
    return $element
}
Assert-Regression ($found -eq $element -and $state.Owners -eq 2) 'Stale elements must be reacquired.'
$found = Find-UiRegressionElement -Description 'wrapped stale owner' -Condition 'match' -Optional -Container {
    throw [InvalidOperationException]::new('UI Automation wrapper', [System.Windows.Automation.ElementNotAvailableException]::new())
} -Find { throw 'Lookup must not run with an unavailable owner.' }
Assert-Regression ($null -eq $found) 'Native exceptions wrapped by PowerShell must still invalidate an optional owner.'
foreach ($invalid in @('offscreen', 'empty', 'zeroWidth', 'zeroHeight', 'absent')) {
    $element.Current.IsOffscreen = $invalid -eq 'offscreen'
    $rectangle.IsEmpty = $invalid -eq 'empty'
    $rectangle.Width = if ($invalid -eq 'zeroWidth') { 0 } else { 100 }
    $rectangle.Height = if ($invalid -eq 'zeroHeight') { 0 } else { 30 }
    $state.Lookups = 0
    $found = Find-UiRegressionElement -Description $invalid -Condition 'match' -Optional -Container { 'owner' } -Find {
        param($Owner, $Match)
        $state.Lookups++
        if ($invalid -ne 'absent') { return $element }
    }
    Assert-Regression ($null -eq $found -and $state.Lookups -eq 1) "Optional $invalid lookup must inspect current state once."
}
Assert-RegressionFailure { Find-UiRegressionElement -Description 'failed lookup' -Condition 'match' -Container { 'owner' } -Find { throw 'unexpected lookup error' } } 'unexpected lookup error'
$found = Find-UiRegressionElement -Description 'missing owner' -Condition 'match' -Optional -Container { $null } -Find { throw 'Lookup must not run without an owner.' }
Assert-Regression ($null -eq $found) 'Missing owner must not produce a control.'
& {
    $state = @{ Calls = 0 }
    $marker = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $true; BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 } } }
    $owner = [pscustomobject]@{ Id = 'TableViewport' }
    $shell = [pscustomobject]@{}
    $shell | Add-Member ScriptMethod FindFirst {
        param($Scope, $Match)
        $state.Calls++
        if ($Match.Value -eq 'DevicesHeading') { return $marker }
        if ($Match.Value -eq 'TableViewport') { return $owner }
        throw "Unexpected page container '$($Match.Value)'."
    }
    $container = Get-UiRegressionPageContainer -Root $shell -PageMarkerId DevicesHeading -ContainerId TableViewport
    Assert-Regression ($null -eq $container -and $state.Calls -eq 1) 'An offscreen page must not expose another page container.'
    $marker.Current.IsOffscreen = $false
    $container = Get-UiRegressionPageContainer -Root $shell -PageMarkerId DevicesHeading -ContainerId TableViewport
    Assert-Regression ($container -eq $owner -and $state.Calls -eq 3) 'Page scope must use actual visible peers even when narrow navigation is not realized.'
}

$app = [pscustomobject]@{ Id = 123; HasExited = $false; ExitCode = 9; MainWindowHandle = [IntPtr]::Zero; Refreshes = 0; Closed = 0; Waits = 0; Forced = 0; Mode = 'normal' }
$app | Add-Member ScriptMethod Refresh {
    $this.Refreshes++
    if ($this.Refreshes -eq 2) { $this.MainWindowHandle = [IntPtr]::new(456) }
}
$app | Add-Member ScriptMethod CloseMainWindow { $this.Closed++; return $true }
$app | Add-Member ScriptMethod WaitForExit {
    param($Timeout)
    $this.Waits++
    return $this.Mode -eq 'normal' -or ($this.Mode -eq 'forced' -and $this.Waits -gt 1)
}
$handle = Wait-UiRegressionWindow -Process $app -TimeoutMilliseconds 1000
Assert-Regression ($handle -eq [IntPtr]::new(456) -and $app.Refreshes -eq 2) 'Window must wait for the live handle.'
$app.MainWindowHandle = [IntPtr]::Zero
Assert-RegressionFailure { Wait-UiRegressionWindow -Process $app -TimeoutMilliseconds 20 } '*20 ms*app window*'
$app.HasExited = $true
Assert-RegressionFailure { Wait-UiRegressionWindow -Process $app } '*exited with code 9*'
Stop-UiRegressionApp -Process $app
Stop-UiRegressionApp -Process $null
Assert-Regression ($app.Closed -eq 0) 'Exited/null process must not be closed again.'
$app.HasExited = $false
$terminate = { param($Process) $Process.Forced++ }
Stop-UiRegressionApp -Process $app -Terminate $terminate
Assert-Regression ($app.Closed -eq 1 -and $app.Forced -eq 0) 'Normal close must not force termination.'
foreach ($mode in @('forced', 'stuck')) {
    $app.Mode = $mode
    $app.Waits = 0
    $app.Forced = 0
    $pattern = if ($mode -eq 'forced') { '*did not close normally*forced cleanup*' } else { '*did not terminate*' }
    Assert-RegressionFailure { Stop-UiRegressionApp -Process $app -Terminate $terminate } $pattern
    Assert-Regression ($app.Forced -eq 1 -and $app.Waits -eq 2) 'Forced cleanup must target the supplied process and verify exit.'
}
$app.Waits = 0
Assert-RegressionFailure { Stop-UiRegressionApp -Process $app -Terminate { throw 'termination denied' } } 'termination denied'

$directory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-foundation-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$names = @('FINGVIBE_FOUNDATION_TEST_PRESENT', 'FINGVIBE_FOUNDATION_TEST_ABSENT', 'GITHUB_STEP_SUMMARY')
$original = Save-UiRegressionEnvironment -Names $names
$fixtureDirectories = @()
try {
    $fixtureDirectories = @(New-UiRegressionFixtureDirectory -Suite foundation-test; New-UiRegressionFixtureDirectory -Suite foundation-test)
    Assert-Regression ($fixtureDirectories[0] -ne $fixtureDirectories[1]) 'Independent invocations must have different fixtures.'
    foreach ($fixtureDirectory in $fixtureDirectories) {
        Assert-Regression ((Test-Path -LiteralPath $fixtureDirectory -PathType Container) -and
            [IO.Path]::GetDirectoryName($fixtureDirectory) -eq [IO.Path]::GetTempPath().TrimEnd('\')) 'Fixtures must be newly created temporary directories.'
    }
    [Environment]::SetEnvironmentVariable($names[0], 'before')
    if (Test-Path -LiteralPath "Env:\$($names[1])") { Remove-Item -LiteralPath "Env:\$($names[1])" }
    $env:GITHUB_STEP_SUMMARY = Join-Path $directory 'summary.md'
    $saved = Save-UiRegressionEnvironment -Names $names
    Assert-RegressionFailure {
        try { $env:FINGVIBE_FOUNDATION_TEST_PRESENT = 'changed'; $env:FINGVIBE_FOUNDATION_TEST_ABSENT = 'created'; throw 'scenario failure' }
        finally { Restore-UiRegressionEnvironment -Saved $saved }
    } 'scenario failure'
    Assert-Regression ($env:FINGVIBE_FOUNDATION_TEST_PRESENT -eq 'before' -and $null -eq $env:FINGVIBE_FOUNDATION_TEST_ABSENT) 'Environment must restore values and absence on failure.'
    & {
        $state = @{ Fail = $false; Captures = 0 }
        function Save-UiReviewWindowScreenshot {
            param($WindowHandle, $Path)
            $state.Captures++
            if ($state.Fail) { throw 'capture failure' }
        }
        Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'success.png')
        $state.Fail = $true
        Assert-RegressionFailure { Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'failure.png') } 'capture failure'
        $records = @(Get-Content -LiteralPath (Join-Path $directory 'phases.jsonl') | ConvertFrom-Json)
        Assert-Regression ($state.Captures -eq 2 -and $records.Count -eq 2 -and $records[0].succeeded -and -not $records[1].succeeded) 'Capture timing must preserve failures, not report success.'
        Assert-Regression ($records[0].elapsedMilliseconds -ge 0 -and $records[0].phase -eq 'capture/success.png') 'Capture phase must include measured timing and name.'
    }
}
finally {
    Restore-UiRegressionEnvironment -Saved $original
    Remove-Item -LiteralPath $directory -Recurse -Force
    foreach ($fixtureDirectory in $fixtureDirectories) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}

function Get-RegressionSignature([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", '').Trim())
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Test-RegressionGroupOrchestration($Suite, [hashtable] $Definition, [string] $Root) {
    $moduleDirectory = Join-Path $Root 'UiRegression'
    $null = New-Item -ItemType Directory -Path $moduleDirectory
    foreach ($name in @($Definition.Preconditions) + @($Definition.Groups | ForEach-Object { $_.Modules })) {
        $initializers = if ($Definition.Preconditions.Count) { @($Definition.Preconditions[0]) }
            else { @($Definition.Groups | ForEach-Object { $_.Modules[0] }) }
        $initialization = if ($name -in $initializers) {
            @'
if ($null -ne $groupToken -or $null -ne $process) { throw 'Group state leaked across groups.' }
$groupToken = [Guid]::NewGuid()
$process = 'app'
$env:FINGVIBE_FOUNDATION_GROUP = "$groupToken"
'@
        } else { '' }
        $script = $initialization + "`n" + @"
`$state.Events.Add('$name')
if (`$null -eq `$groupToken -or `$env:FINGVIBE_FOUNDATION_GROUP -ne "`$groupToken") { throw 'Scenario state was lost within a group.' }
if (`$state.FailAt -eq '$name') { throw 'Synthetic module failure: $name' }
"@
        $script | Set-Content -LiteralPath (Join-Path $moduleDirectory "$($Suite.name).$name.Scenario.ps1")
    }
    $savedSummary = $env:GITHUB_STEP_SUMMARY
    $savedGroup = $env:FINGVIBE_FOUNDATION_GROUP
    try {
        $env:GITHUB_STEP_SUMMARY = $null
        $env:FINGVIBE_FOUNDATION_GROUP = 'outer'
        $invoke = {
            param([string] $Group, [scriptblock[]] $Cleanup = @({ $state.Cleanups.Add("$process") }))
            Invoke-UiRegressionGroups -Suite $Suite.name -Definition $Definition -Group $Group -ModuleDirectory $moduleDirectory `
                -Directory $Root -EnvironmentNames @('FINGVIBE_FOUNDATION_GROUP') -StateVariables @('process') `
                -OnFailure { param($FailedGroup) $state.Failures.Add("${FailedGroup}:$process") } -Cleanup $Cleanup
        }
        $newState = { @{ Events = [Collections.Generic.List[string]]::new(); Cleanups = [Collections.Generic.List[string]]::new(); Failures = [Collections.Generic.List[string]]::new(); FailAt = $null } }
        $expectedEvents = { param($Groups) @($Groups | ForEach-Object { @($Definition.Preconditions) + @($_.Modules) }) -join ',' }
        $groups = @($Definition.Groups)

        $state = & $newState
        & $invoke All
        Assert-Regression (($state.Events -join ',') -eq (& $expectedEvents $groups)) 'Every group must run its preconditions and modules exactly once.'
        Assert-Regression ($state.Cleanups.Count -eq $groups.Count -and -not ($state.Cleanups -ne 'app')) 'Cleanup must run once per group with that group''s state.'
        Assert-Regression ($state.Failures.Count -eq 0 -and $env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'Passing groups must restore the environment.'

        $state = & $newState
        $state.FailAt = $groups[0].Modules[0]
        Assert-RegressionFailure { & $invoke All } "*groups failed: $($groups[0].Name) (Synthetic module failure: $($state.FailAt))"
        $failedEvents = @(@($Definition.Preconditions) + $state.FailAt) + @(& $expectedEvents ($groups | Select-Object -Skip 1))
        Assert-Regression (($state.Events -join ',') -eq (($failedEvents | Where-Object { $_ }) -join ',')) 'A failed group must stop, and later groups must still run.'
        Assert-Regression (($state.Failures -join ',') -eq "$($groups[0].Name):app") 'Failure diagnostics must run once with the failed group''s state.'
        Assert-Regression ($state.Cleanups.Count -eq $groups.Count -and $env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'Failed groups must still clean up and restore the environment.'
        $record = @(Get-Content -LiteralPath (Join-Path $Root 'phases.jsonl') | ConvertFrom-Json |
            Where-Object phase -eq "$($Suite.name)/$($groups[0].Name)/$($state.FailAt)")[-1]
        Assert-Regression ($record -and -not $record.succeeded) 'Group orchestration must retain the failed phase.'

        $state = & $newState
        & $invoke $groups[-1].Name.ToUpperInvariant()
        Assert-Regression (($state.Events -join ',') -eq (& $expectedEvents @($groups[-1]))) 'Selecting a group must run only that group.'
        Assert-RegressionFailure { & $invoke 'no-such-group' } "Unknown UI regression group 'no-such-group'*"

        $state = & $newState
        Assert-RegressionFailure { & $invoke $groups[0].Name @({ throw 'cleanup broke' }) } "*groups failed: $($groups[0].Name) (cleanup broke)" 3>$null
        Assert-Regression ($env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'A failed cleanup step must not skip environment restoration.'
    }
    finally {
        $env:GITHUB_STEP_SUMMARY = $savedSummary
        $env:FINGVIBE_FOUNDATION_GROUP = $savedGroup
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\coverage.json') -Raw | ConvertFrom-Json
foreach ($suite in $manifest.suites) {
    $entry = Join-Path $PSScriptRoot $suite.entry
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$errors)
    Assert-Regression (-not $errors) "Entry $entry must parse."
    if ($suite.groupDefinition) {
        $groupDefinition = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\$($suite.groupDefinition)")
        $orchestration = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-UiRegressionGroups' }, $true)
        Assert-Regression ($null -ne $orchestration -and $ast.Extent.Text.Contains($suite.groupDefinition)) "$($suite.name) must run its declared groups."
        Assert-Regression ((@($groupDefinition.Preconditions) -join ',') -eq 'Setup,Ready') 'Every group must start from its own Setup and Ready preconditions.'
        $grouped = @($groupDefinition.Groups | ForEach-Object { $_.Modules })
        $behavior = @($suite.scenarioOrder | Where-Object { $_ -ne 'Setup' })
        Assert-Regression ((@($grouped | Sort-Object) -join ',') -eq (@($behavior | Sort-Object) -join ',')) "$($suite.name) groups must run every behavior module exactly once."
        Assert-Regression (@($groupDefinition.Groups.Name | Select-Object -Unique).Count -eq @($groupDefinition.Groups).Count) 'Group names must be unique.'
        foreach ($regressionGroup in $groupDefinition.Groups) {
            $indices = @($regressionGroup.Modules | ForEach-Object { [Array]::IndexOf([string[]]$suite.scenarioOrder, $_) })
            Assert-Regression (($indices -join ',') -eq (@($indices | Sort-Object) -join ',')) "Group $($regressionGroup.Name) must keep the original module order."
            Assert-Regression ($regressionGroup.Name -cmatch '^[a-z0-9-]+$') 'Group names must be valid CI suite suffixes.'
        }
        Assert-Regression (@($suite.files | Where-Object { $_.file -eq "$($suite.name).Ready.Scenario.ps1" -and $_.kind -eq 'precondition' }).Count -eq 1) 'The Ready precondition must be mapped.'
    }
    else {
        $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'regressionModule' }, $true)
        $order = @($loop.Condition.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
        Assert-Regression (($order -join ',') -eq ($suite.scenarioOrder -join ',')) "$($suite.name) scenario order changed."
        $execution = $loop.Body.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Dot' }, $true)
        Assert-Regression ($null -ne $execution) 'Modules must execute at entry script scope, preserving inter-scenario state.'
    }
    $loadedHelpers = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '\.Helpers\.ps1$'
    }, $true) | ForEach-Object { [IO.Path]::GetFileName($_.Value) })
    $requiredHelpers = @($suite.files | Where-Object kind -eq 'helpers' | ForEach-Object file)
    Assert-Regression (($loadedHelpers -join ',') -eq ($requiredHelpers -join ',')) 'Every mapped helper must be loaded exactly once in the original dependency order.'
    foreach ($module in $suite.files) {
        $path = Join-Path $PSScriptRoot "UiRegression\$($module.file)"
        $errors = $null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-Regression (-not $errors) "Module $path must parse."
        if (-not $module.refactored) {
            Assert-Regression ((Get-RegressionSignature $moduleAst.Extent.Text) -eq $module.baselineSha256) "Unchanged coverage in $path differs from the baseline."
        }
        $functions = @($moduleAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        Assert-Regression (($functions.Name -join ',') -eq ($module.functions.name -join ',')) "A mapped function was lost or duplicated in $path."
        foreach ($definition in $module.functions) {
            $actual = @($functions | Where-Object Name -eq $definition.name)[0]
            if (-not $definition.refactored) {
                Assert-Regression ((Get-RegressionSignature $actual.Extent.Text) -eq $definition.baselineSha256) "Unchanged function $($definition.name) differs from baseline."
            }
            if ($definition.name -in @('Test-DeviceRefresh', 'Save-SidebarAppearance', 'Save-DeviceCapture')) {
                $assertions = @($actual.Body.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true) |
                    ForEach-Object { Get-RegressionSignature $_.Extent.Text })
                foreach ($assertion in $definition.assertions) {
                    Assert-Regression ($assertion -in $assertions) "Behavioral failure coverage in $($definition.name) was lost."
                }
            }
        }
        $captures = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Save-DeviceCapture', 'Save-SidebarAppearance', 'Save-ScheduledScanFailure')
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($captures -join ',') -eq ($module.captures -join ',')) "Capture coverage/order changed in $path."
        $fixtureAssignments = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$results'
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($fixtureAssignments -join ',') -eq ($module.fixtureAssignments -join ',')) "Synthetic fixture data changed in $path."
    }
    $fixtureRoot = New-UiRegressionFixtureDirectory -Suite foundation-test
    if ($suite.groupDefinition) {
        try { Test-RegressionGroupOrchestration -Suite $suite -Definition $groupDefinition -Root $fixtureRoot }
        finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        continue
    }
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'UiRegression')
        foreach ($name in $suite.scenarioOrder) {
            $script = @"
`$events.Add('$name')
if ('$name' -eq 'Setup') { `$sharedSelection = `$invocation }
elseif (`$sharedSelection -ne `$invocation) { throw 'Scenario state was lost across scopes.' }
if (`$failAt -eq '$name') { throw 'Synthetic module failure: $name' }
"@
            $script | Set-Content -LiteralPath (Join-Path $fixtureRoot "UiRegression\$($suite.name).$name.Scenario.ps1")
        }
        $loopSource = $loop.Extent.Text.Replace('$PSScriptRoot', '$fixtureRoot')
        $ScreenshotDirectory = $fixtureRoot
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $null
        Invoke-Expression $loopSource
        Assert-Regression (($events -join ',') -eq ($suite.scenarioOrder -join ',')) 'Original orchestration must execute every scenario exactly once with shared state.'
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $suite.scenarioOrder[1]
        Assert-RegressionFailure { Invoke-Expression $loopSource } "Synthetic module failure: $failAt"
        Assert-Regression ($events.Count -eq 2) 'A failed scenario must stop later scenarios rather than succeed.'
        $record = Get-Content -LiteralPath (Join-Path $fixtureRoot 'phases.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        Assert-Regression (-not $record.succeeded -and $record.phase -eq "$($suite.name)/$failAt") 'Original orchestration must retain the failed phase.'
    }
    finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
& {
    $definition = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\Tools.Groups.psd1')
    $root = New-UiRegressionFixtureDirectory -Suite tools-foundation
    try {
        Test-RegressionGroupOrchestration -Suite @{ name = 'Tools' } -Definition $definition -Root $root
        $modules = @($definition.Groups | ForEach-Object { $_.Modules })
        Assert-Regression (($modules -join ',') -eq 'Identity,Troubleshooting,Import,Backups,Services,Sql') 'Tools must retain every original check and the focused backup module exactly once and in the original order.'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
& {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-call-costs-$([Guid]::NewGuid().ToString('N'))"
    $savedSummary = $env:GITHUB_STEP_SUMMARY
    try {
        $env:GITHUB_STEP_SUMMARY = $null
        $null = New-Item -ItemType Directory -Path $directory
        $script:UiRegressionCallCosts = $null
        $script:UiRegressionCallStack = $null
        $phase = Step-UiRegressionPhase $null 'costs/first' $directory
        $outer = Start-UiRegressionCall positioning
        $inner = Start-UiRegressionCall lookup
        Start-Sleep -Milliseconds 30
        Complete-UiRegressionCall $inner
        Complete-UiRegressionCall $outer
        $phase = Step-UiRegressionPhase $phase 'costs/second' $directory
        $abandoned = Start-UiRegressionCall wait
        $closing = Start-UiRegressionCall close
        Complete-UiRegressionCall $closing
        Complete-UiRegressionCall $abandoned
        $phase = Step-UiRegressionPhase $phase $null $directory
        Assert-Regression ($null -eq $phase) 'Completing the last phase must leave no open phase.'
        Write-UiRegressionCallCosts -Directory $directory -Name 'Synthetic.Ui'
        $costs = Get-Content -LiteralPath (Join-Path $directory 'call-costs.json') -Raw | ConvertFrom-Json
        $lookup = @($costs.entries | Where-Object { $_.phase -eq 'costs/first' -and $_.category -eq 'lookup' })[0]
        $positioning = @($costs.entries | Where-Object { $_.phase -eq 'costs/first' -and $_.category -eq 'positioning' })[0]
        Assert-Regression ($costs.check -eq 'Synthetic.Ui' -and $lookup.calls -eq 1 -and $lookup.exclusiveMilliseconds -ge 25) 'Call costs must record per-phase lookups.'
        Assert-Regression ($positioning.inclusiveMilliseconds -ge $lookup.inclusiveMilliseconds -and
            $positioning.exclusiveMilliseconds -lt $lookup.exclusiveMilliseconds) 'Nested lookup time must be excluded from positioning.'
        Assert-Regression (@($costs.entries | Where-Object phase -eq 'costs/second').Count -eq 2) 'Calls must be attributed to the active phase.'
        $phases = @(Get-Content -LiteralPath (Join-Path $directory 'phases.jsonl') | ConvertFrom-Json)
        Assert-Regression ((($phases.phase) -join ',') -eq 'costs/first,costs/second' -and -not ($phases.succeeded -contains $false)) 'Phase steps must close each phase successfully.'
    }
    finally {
        $env:GITHUB_STEP_SUMMARY = $savedSummary
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}
& {
    $ran = [Collections.Generic.List[string]]::new()
    Invoke-UiRegressionCleanup -PrimaryFailed $true -Steps @({ $ran.Add('first'); throw 'cleanup broke' }, { $ran.Add('second') }) 3>$null
    Assert-Regression (($ran -join ',') -eq 'first,second') 'Cleanup must run every step after a failing step.'
    Assert-RegressionFailure { Invoke-UiRegressionCleanup -PrimaryFailed $false -Steps @({ throw 'cleanup broke' }) 3>$null } 'cleanup broke'
}
function Test-DatabaseBackupCleanup {
    param([string] $TestRoot = $PSScriptRoot)
    $tokens = $null
    $parseErrors = $null
    $backupAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $TestRoot 'DatabaseBackups.Ui.Tests.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw $parseErrors[0] }
    $backupTry = @($backupAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $cleanup = [scriptblock]::Create((@($backupTry.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $savedProcess = $script:process
    foreach ($primaryFailed in @($true, $false)) {
        $root = New-UiRegressionFixtureDirectory -Suite backup-cleanup
        $fixture = Join-Path $root 'inventory'
        $ScreenshotDirectory = Join-Path $root 'captures'
        $environment = Save-UiRegressionEnvironment @('FINGVIBE_BACKUP_CLEANUP_TEST')
        try {
            $null = New-Item -ItemType Directory -Path $fixture, $ScreenshotDirectory
            $env:FINGVIBE_BACKUP_CLEANUP_TEST = 'changed'
            $failure = if ($primaryFailed) { [InvalidOperationException]::new('primary backup failure') } else { $null }
            $phase = Start-UiRegressionPhase 'Backups/synthetic'
            $script:process = [pscustomobject]@{ Disposed = $false }
            $script:process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            function Stop-UiRegressionApp { throw 'synthetic backup close failure' }
            if ($primaryFailed) { & $cleanup 3>$null }
            else { Assert-RegressionFailure { & $cleanup 3>$null } 'synthetic backup close failure' }
            Assert-Regression ($script:process.Disposed -and -not (Test-Path -LiteralPath $fixture)) 'Backup cleanup must dispose and remove its fixture even when closing fails.'
            Assert-Regression ([Environment]::GetEnvironmentVariable('FINGVIBE_BACKUP_CLEANUP_TEST') -eq $environment.FINGVIBE_BACKUP_CLEANUP_TEST) 'Backup cleanup must restore its environment after a close failure.'
            $record = Get-Content (Join-Path $ScreenshotDirectory 'phases.jsonl') -Raw | ConvertFrom-Json
            Assert-Regression ($record.succeeded -eq (-not $primaryFailed)) 'Backup phase completion must retain the primary check outcome.'
        }
        finally {
            $script:process = $savedProcess
            Restore-UiRegressionEnvironment $environment
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Test-DatabaseBackupCleanup
& {
    $idle = ConvertFrom-UiRegressionSurfaceStatus 'Idle'
    Assert-Regression ($idle.State -eq 'Idle' -and $idle.Request -eq 0) 'Idle must parse without a request.'
    $ready = ConvertFrom-UiRegressionSurfaceStatus 'Ready (request 12): Last 30 days, 1-hour cells'
    Assert-Regression ($ready.State -eq 'Ready' -and $ready.Request -eq 12 -and $ready.Selection -eq 'Last 30 days, 1-hour cells') 'Status must parse state, request and selection.'
    foreach ($status in @($null, '', 'ready (request 1): x', 'Ready (request 0): x', 'Ready: x', 'Done (request 1): x')) {
        Assert-RegressionFailure { ConvertFrom-UiRegressionSurfaceStatus $status } '*Unrecognized async surface status*'
    }

    $states = [Collections.Generic.Queue[string]]::new()
    function New-StateElement([string] $Status) { [pscustomobject]@{ Current = [pscustomobject]@{ ItemStatus = $Status } } }
    $script:surfaceStatus = $null
    $getElement = { $next = if ($states.Count -gt 0) { $states.Dequeue() } else { $script:surfaceStatus }; $script:surfaceStatus = $next; New-StateElement $next }
    foreach ($status in @('Ready (request 3): old', 'Loading (request 4): new', 'Ready (request 4): other', 'Ready (request 5): new')) { $states.Enqueue($status) }
    $result = Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -Selection 'new' -After 3 -PollMilliseconds 1
    Assert-Regression ($result.Request -eq 5 -and $result.Selection -eq 'new') 'Wait must skip old requests, loading and other selections.'

    $states.Enqueue('Error (request 6): new')
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -After 5 -PollMilliseconds 1 } '*surface reported Error (request 6)*'
    $states.Enqueue('Error (request 7): new')
    $failed = Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -State Error -After 6 -PollMilliseconds 1
    Assert-Regression ($failed.Request -eq 7) 'Error must be awaitable when expected.'

    $script:surfaceStatus = 'Ready (request 7): new'
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -After 7 -TimeoutMilliseconds 20 -PollMilliseconds 1 } '*Last state: Ready (request 7): new'
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement { $null } -Description 'surface' -TimeoutMilliseconds 20 -PollMilliseconds 1 } 'Timed out*has no UI Automation peer.'
    $script:surfacePolls = 0
    $appearing = { $script:surfacePolls++; if ($script:surfacePolls -gt 2) { [pscustomobject]@{ Current = [pscustomobject]@{ ItemStatus = 'Ready (request 9): later' } } } }
    Assert-Regression ((Wait-UiRegressionSurfaceState -GetElement $appearing -Description 'surface' -After 8 -PollMilliseconds 1).Request -eq 9) 'A surface hidden during navigation is awaited, not failed'
}
Write-Host 'UI regression helper, cleanup, timing, async state, and orchestration checks passed.'
