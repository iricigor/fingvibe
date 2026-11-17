# Shared foundation: element lookup, page containers, app lifecycle, environment and fixtures.
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
        $state = @{ Fail = $false; Captures = 0; MinimumWidths = @() }
        function Save-UiReviewWindowScreenshot {
            param($WindowHandle, $Path, $MinimumWidth = 640)
            $state.Captures++
            $state.MinimumWidths += $MinimumWidth
            if ($state.Fail) { throw 'capture failure' }
        }
        Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'success.png')
        $state.Fail = $true
        Assert-RegressionFailure { Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'failure.png') } 'capture failure'
        $records = @(Get-Content -LiteralPath (Join-Path $directory 'phases.jsonl') | ConvertFrom-Json)
        Assert-Regression ($state.Captures -eq 2 -and $records.Count -eq 2 -and $records[0].succeeded -and -not $records[1].succeeded) 'Capture timing must preserve failures, not report success.'
        Assert-Regression ($records[0].elapsedMilliseconds -ge 0 -and $records[0].phase -eq 'capture/success.png') 'Capture phase must include measured timing and name.'
        $state.Fail = $false
        $controlsAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Controls.Helpers.ps1'), [ref]$null, [ref]$null)
        $saveAppearance = $controlsAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-SidebarAppearance'
        }, $true)
        . ([scriptblock]::Create($saveAppearance.Extent.Text))
        function Focus-SidebarWindow {}
        function Start-Sleep {}
        $ScreenshotDirectory = $directory
        $windowHandle = [IntPtr]::new(1)
        $settingsAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Settings.Helpers.ps1'), [ref]$null, [ref]$null)
        $scaledCapture = $settingsAst.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Save-SidebarAppearance' -and
                $node.Extent.Text.Contains('settings-collapsed-text-200-high-contrast-$width')
        }, $true)
        foreach ($width in @(480, 640)) { Invoke-Expression $scaledCapture.Extent.Text }
        Assert-Regression (($state.MinimumWidths -join ',') -eq '640,640,480,640') 'The actual scaled Settings captures must forward their intentional width without changing ordinary capture defaults.'
    }
}
finally {
    Restore-UiRegressionEnvironment -Saved $original
    Remove-Item -LiteralPath $directory -Recurse -Force
    foreach ($fixtureDirectory in $fixtureDirectories) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
