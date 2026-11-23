# Sidebar feature helpers: Settings and preference readiness, scan flows and People/Rooms.
& {
    $settingsAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Settings.Helpers.ps1'), [ref]$null, [ref]$null)
    $position = $settingsAst.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Show-UiRegressionScrollTargets' -and
            $node.Extent.Text.Contains('"scaled Settings $id"')
    }, $true)
    $targetParameter = $position.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'GetTargets'
    }
    $targetIndex = $position.CommandElements.IndexOf($targetParameter)
    $getTargets = $position.CommandElements[$targetIndex + 1].ScriptBlock.GetScriptBlock()
    $summaryCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'AppearanceSummary')
    $condition = $summaryCondition
    $target = [pscustomobject]@{}
    $root = [pscustomobject]@{}
    $root | Add-Member ScriptMethod FindFirst {
        param($Scope, [System.Windows.Automation.Condition] $Match)
        Assert-Regression ($Match.Value -eq 'AppearanceSummary') 'Scaled Settings lookup must retain its UIA condition inside nested waits.'
        return $target
    }
    $found = Wait-UiRegressionState -Description 'scaled Settings target callback' -Condition { & $getTargets }
    Assert-Regression ($found -eq $target) 'The actual scaled Settings callback must survive the shared wait scope.'
}
& {
    $identityAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'BuildIdentity.Ui.Tests.ps1'), [ref]$null, [ref]$null)
    $readiness = $identityAst.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Wait-UiRegressionState' -and
            $node.Extent.Text.Contains('"$id visible in high contrast"')
    }, $true)
    Assert-Regression ($null -ne $readiness) 'High-contrast preferences must wait for actual rendered visibility after expanding.'
    $preferenceCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CompactRowsSwitch')
    $preferencePeer = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $true; BoundingRectangle = [System.Windows.Rect]::new(0, 0, 100, 30)
    } }
    $state = @{ Lookups = 0 }
    $previousRoot = $script:root
    try {
        $script:root = [pscustomobject]@{}
        $script:root | Add-Member ScriptMethod FindFirst {
            param($Scope, [System.Windows.Automation.Condition] $Match)
            Assert-Regression ($Match.Value -eq 'CompactRowsSwitch') 'High-contrast readiness must retain the preference identity inside the wait.'
            $state.Lookups++
            $preferencePeer.Current.IsOffscreen = $state.Lookups -lt 3
            return $preferencePeer
        }
        $found = Invoke-Expression $readiness.Extent.Text
        Assert-Regression ($found -eq $preferencePeer -and $state.Lookups -eq 3) 'Preference readiness must await the expanded content layout, not merely its peer.'
    }
    finally { $script:root = $previousRoot }
}
Add-Type -TypeDefinition @'
public static class SidebarReviewKeyboard
{
    public static int Taps;
    public static void Tap(int key) { Taps++; }
    public static void MoveTo(int x, int y) {}
}
'@
foreach ($case in @('rounded', 'square', 'gap', 'unreadable')) {
    & {
        . (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Navigation.Helpers.ps1')
        $ScreenshotDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-caption-pixels-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory
        $scale = 1
        $windowHandle = [IntPtr]::Zero
        function Find-SidebarElement($Property, $Value) {
            $bounds = if ($Value -eq 'TitleBarAppName') { [System.Windows.Rect]::new(0, 0, 80, 18) }
                else { [System.Windows.Rect]::new(10, 20, 46, 40) }
            return [pscustomobject]@{ Current = [pscustomobject]@{
                BoundingRectangle = $bounds
            } }
        }
        function Get-UiReviewWindowBounds($Handle) { return [System.Windows.Rect]::new(0, 0, 100, 80) }
        function Save-SidebarAppearance([string] $Name) {
            $bitmap = [Drawing.Bitmap]::new(100, 80)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $background = if ($case -eq 'unreadable') { [Drawing.Color]::FromArgb(32, 36, 42) }
                else { [Drawing.Color]::FromArgb(236, 239, 243) }
            try {
                $graphics.Clear($background)
                $graphics.DrawString('FingVibe', [Drawing.SystemFonts]::DefaultFont, [Drawing.Brushes]::Black, 0, 0)
                if ($Name.EndsWith('-hover')) {
                    $graphics.FillRectangle([Drawing.Brushes]::Red, 10, 20, 46, 40)
                    if ($case -ne 'square') {
                        $bitmap.SetPixel(10, 20, $background)
                        $bitmap.SetPixel(11, 21, [Drawing.Color]::FromArgb(236, 237, 240))
                    }
                    if ($case -eq 'gap') { $bitmap.SetPixel(33, 58, $background) }
                }
                $bitmap.Save((Join-Path $ScreenshotDirectory "$Name.png"))
            }
            finally { $graphics.Dispose(); $bitmap.Dispose() }
        }
        try {
            if ($case -eq 'rounded') { Test-TitleBarCaptionHover 'caption' }
            elseif ($case -eq 'unreadable') {
                Assert-RegressionFailure { Test-TitleBarCaptionHover 'caption' } '*4.5:1 contrast*'
            }
            else {
                Assert-RegressionFailure { Test-TitleBarCaptionHover 'caption' } '*rounded transparent corner*'
            }
        }
        finally { Remove-Item -LiteralPath $ScreenshotDirectory -Recurse -Force }
    }
}
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
