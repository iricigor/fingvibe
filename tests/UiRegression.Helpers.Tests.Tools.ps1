# Tools feature helpers: landing cards and window layout.
& {
    . (Join-Path $PSScriptRoot 'UiRegression\Tools.Landing.Helpers.ps1')
    & {
        Add-Type -TypeDefinition @'
public static class ToolsLandingTestWindow
{
    public static int Width, Height, Resizes;
    public static bool FailResize;
    public static bool SetWindowPos(System.IntPtr window, System.IntPtr after,
        int x, int y, int width, int height, uint flags)
    {
        Resizes++;
        if (FailResize) return false;
        Width = width; Height = height;
        return true;
    }
}
'@
        $layoutAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'UiRegression\Tools.Landing.Helpers.ps1'), [ref]$null, [ref]$null)
        $layout = $layoutAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-ToolsLandingLayout'
        }, $true)
        Invoke-Expression ($layout.Extent.Text.Replace('[UiReviewNativeWindow]', '[ToolsLandingTestWindow]'))
        $waitImplementation = ${function:Wait-UiRegressionState}
        function Wait-UiRegressionState {
            param([scriptblock] $Condition, [string] $Description)
            & $waitImplementation -Condition $Condition -Description $Description -TimeoutMilliseconds 200 -PollMilliseconds 1
        }
        $state = @{ OnTools = $true; Selections = 0; Reads = 0; HoldLayout = $false; FailNavigation = $false }
        $landing = [pscustomobject]@{ Current = @{
            IsOffscreen = $false; BoundingRectangle = [Windows.Rect]::new(0, 0, 640, 720)
        } }
        $landing | Add-Member ScriptMethod GetCurrentPattern {
            param($Pattern)
            throw 'Tools landing geometry reached'
        }
        $window = [pscustomobject]@{ Current = @{
            IsOffscreen = $false; BoundingRectangle = [Windows.Rect]::new(0, 0, 640, 720)
        } }
        $window | Add-Member ScriptMethod FindFirst {
            param($Scope, $Match)
            Assert-Regression ($Match.Value -eq 'ToolsLanding') 'Readiness must identify the actual Tools-owned viewport.'
            if ($state.OnTools) { return $landing }
            return $null
        }
        function Get-UiReviewWindowBounds {
            param($WindowHandle)
            $width = [ToolsLandingTestWindow]::Width
            $height = [ToolsLandingTestWindow]::Height
            if ([ToolsLandingTestWindow]::Resizes -gt 0) {
                $state.Reads++
                if ($state.Reads -eq 1) { $height = 720 }
                $window.Current.BoundingRectangle = [Windows.Rect]::new(0, 0, $width, $height)
                if ($state.Reads -ge 3 -and -not $state.HoldLayout) {
                    $landing.Current.BoundingRectangle = [Windows.Rect]::new(0, 0, $width, $height)
                }
            }
            return @{ X = 0; Y = 0; Width = $width; Height = $height }
        }
        function Select-Page {
            param($Name)
            $state.Selections++
            if ([ToolsLandingTestWindow]::Width -eq 480 -or $state.FailNavigation) {
                throw "Missing selectable page: $Name"
            }
            Assert-Regression ($Name -eq 'Tools') 'Landing readiness must preserve the real Tools route.'
            $state.OnTools = $true
        }
        $process = [pscustomobject]@{ MainWindowHandle = [IntPtr]::new(319) }
        $previousRoot = $script:root
        try {
            $script:root = $window
            foreach ($alreadyOnTools in @($true, $false)) {
                [ToolsLandingTestWindow]::Width = 640
                [ToolsLandingTestWindow]::Height = 720
                [ToolsLandingTestWindow]::Resizes = 0
                $state.OnTools = $alreadyOnTools; $state.Selections = 0; $state.Reads = 0
                $landing.Current.BoundingRectangle = [Windows.Rect]::new(0, 0, 640, 720)
                Assert-RegressionFailure { Assert-ToolsLandingLayout -Width 480 -Height 480 -Variant 'narrow' } '*Tools landing geometry reached*'
                Assert-Regression ($state.Selections -eq [int](-not $alreadyOnTools)) 'An active landing must not depend on narrow navigation peers; other pages must still navigate before resizing.'
                Assert-Regression ($state.Reads -ge 3) 'Wait for target height and the actual resized viewport before checking cards.'
            }
            $state.HoldLayout = $true
            $landing.Current.BoundingRectangle = [Windows.Rect]::new(0, 0, 640, 720)
            Assert-RegressionFailure { Assert-ToolsLandingLayout -Width 480 -Height 480 -Variant 'missing-layout' } '*200 ms*Tools*480*'
            $state.HoldLayout = $false
            $state.OnTools = $false; $state.FailNavigation = $true
            [ToolsLandingTestWindow]::Resizes = 0
            Assert-RegressionFailure { Assert-ToolsLandingLayout -Width 480 -Variant 'missing-route' } 'Missing selectable page: Tools'
            Assert-Regression ([ToolsLandingTestWindow]::Resizes -eq 0) 'A genuine route failure must propagate before resizing.'
            $state.OnTools = $true
            [ToolsLandingTestWindow]::FailResize = $true
            Assert-RegressionFailure { Assert-ToolsLandingLayout -Width 480 -Variant 'resize-failure' } 'Could not resize the Tools window*'
        }
        finally { $script:root = $previousRoot }
    }
    $window = [pscustomobject]@{ Current = @{
        IsOffscreen = $false; BoundingRectangle = [Windows.Rect]::new(0, 0, 500, 300)
    } }
    $viewport = [pscustomobject]@{ Current = $window.Current }
    $card = [pscustomobject]@{ Current = @{ IsOffscreen = $false } }
    $descriptionPeer = [pscustomobject]@{ Current = @{ Name = 'View local backup copies and protect your saved device inventory.' } }
    $actionPeer = [pscustomobject]@{ Current = @{ Name = 'Open database backups' } }
    $unnamed = [pscustomobject]@{ Current = @{ Name = '' } }
    $card | Add-Member ScriptMethod FindAll {
        param($Scope, $Condition)
        Assert-Regression ($Scope -eq [System.Windows.Automation.TreeScope]::Descendants -and
            $Condition.Value -eq [System.Windows.Automation.ControlType]::Text.Id) 'Tools positioning must locate real descendant text peers.'
        return @($descriptionPeer, $actionPeer, $unnamed)
    }
    $lookups = [Collections.Generic.List[string]]::new()
    $lookupState = @{ Id = 'DatabaseBackupsCard'; Missing = $false; Error = $false }
    $window | Add-Member ScriptMethod FindFirst {
        param($Scope, $Match)
        $lookups.Add($Match.Value)
        Assert-Regression ($Scope -eq [System.Windows.Automation.TreeScope]::Descendants) 'Search the actual Tools descendants.'
        if ($Match.Value -eq 'ToolsLanding') { return $viewport }
        Assert-Regression ($Match.Value -eq $lookupState.Id) 'Position the requested real Tools peer.'
        if ($lookupState.Error) { throw 'Tools lookup failed' }
        if ($lookupState.Missing) { return $null }
        return $card
    }
    $rowGeometry = @{ Top = 285.0; EmptyBounds = $false }
    $positions = [Collections.Generic.List[double]]::new()
    $scroll = [pscustomobject]@{ Current = @{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        $top = $rowGeometry.Top - $Percent * 12
        $visibleTop = [Math]::Max(0, $top)
        $visibleBottom = [Math]::Min(300, $top + 180)
        $card.Current.IsOffscreen = $top -ge 300 -or $top + 180 -le 0
        $card.Current.BoundingRectangle = if ($card.Current.IsOffscreen) {
            if ($rowGeometry.EmptyBounds) { [Windows.Rect]::Empty }
            else { [Windows.Rect]::new(10, $top, 200, 180) }
        } else { [Windows.Rect]::new(10, $visibleTop, 200, $visibleBottom - $visibleTop) }
        foreach ($entry in @(@($descriptionPeer, 50, 40), @($actionPeer, 140, 20))) {
            $entry[0].Current.BoundingRectangle = [Windows.Rect]::new(25, $top + $entry[1], 170, $entry[2])
            $entry[0].Current.IsOffscreen = $top + $entry[1] -ge 300 -or $top + $entry[1] + $entry[2] -le 0
        }
    }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $previousRoot = $script:root
    try {
        $script:root = $window
        $scroll.SetScrollPercent(-1, 0)
        $positions.Clear()
        Assert-Regression (Test-UiRegressionElementWithin $card $viewport $window) 'The regression fixture must reproduce a clipped parent that incorrectly appears contained.'
        $null = Show-UiRegressionScrollTargets -Description 'Tools clipped-parent baseline' `
            -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $card }
        Assert-Regression ($positions.Count -eq 0 -and $descriptionPeer.Current.IsOffscreen -and
            $actionPeer.Current.IsOffscreen) 'Parent-only positioning reproduces the original offscreen text failure.'
        $targets = @(Get-ToolsLandingRowTargets @('DatabaseBackupsCard'))
        Assert-Regression ($targets.Count -eq 3 -and $descriptionPeer -in $targets -and $actionPeer -in $targets) 'Include offscreen named descriptions/actions, but not unnamed decoration.'
        $arguments = @{
            GetViewport = { $viewport }; GetWindow = { $window }
            GetTargets = { Get-ToolsLandingRowTargets @('DatabaseBackupsCard') }
            Description = 'Tools final card and text'
        }
        $null = Show-UiRegressionScrollTargets @arguments
        Assert-Regression ($positions.Count -eq 1 -and $lookups.Count -ge 3) 'Reacquire the row and perform measured scrolling despite its clipped parent bounds.'
        foreach ($text in @($descriptionPeer, $actionPeer)) {
            Assert-Regression (Test-UiRegressionElementWithin $text $viewport $window) 'Every named Tools label must actually be visible after positioning.'
        }
        $null = Show-UiRegressionScrollTargets @arguments
        Assert-Regression ($positions.Count -eq 1) 'Already-visible Tools rows must not scroll again.'
        $scroll.SetScrollPercent(-1, 0)
        $scroll.Current.VerticallyScrollable = $false
        Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*clipped in a non-scrollable viewport*'

        $scroll.Current.VerticallyScrollable = $true
        $rowGeometry.Top = 400
        foreach ($emptyBounds in @($false, $true)) {
            $rowGeometry.EmptyBounds = $emptyBounds
            $scroll.SetScrollPercent(-1, 0)
            $positions.Clear()
            Assert-Regression (-not (Test-UiRegressionElementVisible $card)) 'The last row must begin genuinely offscreen or unrendered.'
            $found = Show-UiRegressionScrollTargets @arguments
            Assert-Regression ($found -eq $card -and $positions.Count -eq 1) 'Discover the real offscreen peer before requiring visibility so bounded scrolling can reveal it.'
            foreach ($target in @($card, $descriptionPeer, $actionPeer)) {
                Assert-Regression (Test-UiRegressionElementWithin $target $viewport $window) 'Unrendered row positioning must end with actual visible card and text bounds.'
            }
        }
        $lookupState.Missing = $true
        Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments -TimeoutMilliseconds 20 } '*20 ms*Tools final card and text*'
        $lookupState.Missing = $false
        $lookupState.Error = $true
        Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*Tools lookup failed*'
        $lookupState.Error = $false
        & {
            $source = Get-Content (Join-Path $PSScriptRoot 'UiRegression\Tools.Landing.Helpers.ps1') -Raw
            $layoutAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
            $layout = $layoutAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-ToolsLandingLayout'
            }, $true)
            $loops = @($layout.Body.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.ForStatementAst]
            })
            $keyboardEntry = [scriptblock]::Create($source.Substring(
                $loops[0].Extent.EndOffset, $loops[1].Extent.StartOffset - $loops[0].Extent.EndOffset))
            $waitImplementation = ${function:Wait-UiRegressionState}
            function Wait-UiRegressionState {
                param([scriptblock] $Condition, [string] $Description)
                & $waitImplementation -Condition $Condition -Description $Description -TimeoutMilliseconds 200 -PollMilliseconds 1
            }
            $focusState = @{ Calls = 0 }
            $card | Add-Member ScriptMethod SetFocus {
                foreach ($target in @($this, $descriptionPeer, $actionPeer)) {
                    Assert-Regression (Test-UiRegressionElementWithin $target $viewport $window) 'Keyboard entry requires the first card and its named text inside the actual viewport.'
                }
                $focusState.Calls++
            }
            $ids = @('SqlEditorCard', 'FingImportCard', 'SpeedTestCard', 'TroubleshootingCard', 'DatabaseBackupsCard')
            $Variant = 'high-contrast'
            $lookupState.Id = $ids[0]
            $rowGeometry.Top = 10
            $rowGeometry.EmptyBounds = $false
            $scroll.SetScrollPercent(-1, 40)
            $positions.Clear()
            Assert-Regression (-not (Test-UiRegressionElementVisible $card)) 'The preceding bottom capture must leave the first card genuinely offscreen.'
            & $keyboardEntry
            Assert-Regression ($focusState.Calls -eq 1 -and $positions.Count -eq 1) 'Restore the first card with measured positioning before the strict focus lookup.'

            $scroll.SetScrollPercent(-1, 0)
            $positions.Clear()
            $focusState.Calls = 0
            & $keyboardEntry
            Assert-Regression ($focusState.Calls -eq 1 -and $positions.Count -eq 0) 'Already-visible keyboard entry must not scroll again.'

            $focusState.Calls = 0
            $lookupState.Missing = $true
            Assert-RegressionFailure { & $keyboardEntry } '*200 ms*SqlEditorCard*'
            Assert-Regression ($focusState.Calls -eq 0) 'A genuinely missing first card must not skip the focus precondition.'
            $lookupState.Missing = $false
            $scroll.SetScrollPercent(-1, 40)
            $scroll.Current.VerticallyScrollable = $false
            Assert-RegressionFailure { & $keyboardEntry } '*clipped in a non-scrollable viewport*'
            Assert-Regression ($focusState.Calls -eq 0) 'Unreachable keyboard entry must remain a failure.'
        }
    }
    finally { $script:root = $previousRoot }
}
