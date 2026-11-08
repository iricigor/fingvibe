$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1"), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors.Message -join "; ") }
foreach ($name in @("Test-HistoryStaleException", "Get-HistoryNextViewport", "Show-HistorySectionCore",
    "Visit-HistoryRowsCore", "Find-HistoryControl", "Assert-HistoryRows", "Get-HistoryLocalTime",
    "Invoke-HistoryTimed", "Visit-HistoryRows")) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $function) { throw "Missing history helper '$name'." }
    Invoke-Expression $function.Extent.Text
}
function Assert-HistoryTest($Actual, $Expected, [string] $Description) {
    if (($Actual -join "|") -cne ($Expected -join "|")) { throw "$Description : expected '$Expected', got '$Actual'." }
}
function Assert-HistoryFailure([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected explicit failure matching '$Pattern'."
}

Assert-HistoryTest (Get-HistoryNextViewport 0 20) 20 "One viewport with 20% overlap"
Assert-HistoryTest (Get-HistoryNextViewport 95 20) 100 "Last boundary"
Assert-HistoryTest (Get-HistoryNextViewport 0 80) 100 "Almost non-scrollable list"
foreach ($metrics in @(@(0, 0), @(0, 100), @(-1, 20), @(101, 20), @([double]::NaN, 20))) {
    Assert-HistoryFailure { Get-HistoryNextViewport $metrics[0] $metrics[1] } "*Invalid scroll metrics*"
}

& {
    $script:detailsRoot = $null
    $script:observationsRoot = $null
    $calls = [System.Collections.Generic.List[string]]::new()
    $leaf = [pscustomobject]@{ Current = [pscustomobject]@{ Name = "205 completed scan observations" } }
    $container = [pscustomobject]@{}
    $container | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        $calls.Add("observations:$($Condition.Value)")
        return $leaf
    }
    $page = [pscustomobject]@{}
    $page | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        $calls.Add("page:$($Condition.Value)")
        return $container
    }
    $script:root = [pscustomobject]@{}
    $script:root | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        $calls.Add("window:$($Condition.Value)")
        if ($Condition.Value -ne "DeviceDetailsScroll") { throw "History lookup must be scoped." }
        return $page
    }
    $null = Find-HistoryControl DeviceScanHistoryCount
    $null = Find-HistoryControl DeviceScanHistoryList
    Assert-HistoryTest $calls.ToArray() @(
        "window:DeviceDetailsScroll", "page:DeviceScanHistoryExpander",
        "observations:DeviceScanHistoryCount", "observations:DeviceScanHistoryList") "Reuse owning containers"
    $stale = [pscustomobject]@{}
    $stale | Add-Member ScriptMethod FindFirst {
        throw [System.Windows.Automation.ElementNotAvailableException]::new("fixture stale container")
    }
    $script:observationsRoot = $stale
    $null = Find-HistoryControl DeviceScanHistoryCount
    Assert-HistoryTest $calls[-1] "observations:DeviceScanHistoryCount" "Stale container reacquired"
    $script:root = $stale
    $script:detailsRoot = $null
    $script:observationsRoot = $null
    Assert-HistoryFailure { Find-HistoryControl DeviceScanHistoryCount } "*fixture stale container*"
}

& {
    function Start-Sleep { param($Milliseconds) }
    $state = @{ Percent = 0.0; Moves = [System.Collections.Generic.List[double]]::new() }
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalViewSize = 20.0; VerticalScrollPercent = 0.0 } }
    $element = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [System.Drawing.RectangleF]::new(0, 1500, 100, 100) } }
    $element | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Result); return $false }
    $page = [pscustomobject]@{ Current = [pscustomobject]@{
        BoundingRectangle = [System.Drawing.RectangleF]::new(0, 0, 500, 500) } }
    $page | Add-Member ScriptMethod GetCurrentPattern { param($Pattern); return $scroll }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Vertical)
        $state.Moves.Add($Vertical)
        $this.Current.VerticalScrollPercent = $Vertical
        $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, 1500 - 20 * $Vertical, 100, 100)
    }
    function Find-HistoryControl([string] $Value) {
        if ($Value -eq "DeviceDetailsScroll") { return $page }
        return $element
    }
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    Assert-HistoryTest $state.Moves.Count 1 "Direct geometry correction instead of percent sweep"
    $state.Moves.Clear()
    $scroll.Current.VerticalScrollPercent = 90
    $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, -300, 100, 100)
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    Assert-HistoryTest $state.Moves.Count 1 "Reverse correction from current position"
    $scroll.Current.VerticallyScrollable = $false
    $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, 50, 100, 100)
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, 600, 100, 100)
    Assert-HistoryFailure { Show-HistorySectionCore DeviceScanHistoryList 35 } "*does not fit*"
    $scroll.Current.VerticallyScrollable = $true
    $scroll.Current.VerticalScrollPercent = 0
    $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::Empty
    $state.Moves.Clear()
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    Assert-HistoryTest $state.Moves[0] 20 "Unrealized section uses overlapping viewport fallback"
    $bringState = @{ Calls = 0 }
    $bring = [pscustomobject]@{}
    $bring | Add-Member ScriptMethod ScrollIntoView {
        $bringState.Calls++
        $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, 50, 100, 100)
    }
    $bringState.Pattern = $bring
    $element | Add-Member ScriptMethod TryGetCurrentPattern {
        param($Pattern, $Result)
        $Result.Value = $bringState.Pattern
        return $true
    } -Force
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    Assert-HistoryTest $bringState.Calls 1 "Supported ScrollItem bring-into-view"
    $element | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Result); return $false } -Force
    $scroll.Current.VerticallyScrollable = $false
    $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::Empty
    $layout = @{ Polls = 0 }
    function Start-Sleep {
        param($Milliseconds)
        if (++$layout.Polls -ge 3) {
            $element.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(0, 50, 100, 100)
        }
    }
    $null = Show-HistorySectionCore DeviceScanHistoryList 35
    if ($layout.Polls -lt 3) { throw "Section positioning must wait for expansion layout before treating a page as non-scrollable." }
}

& {
    $state = @{ Rows = 100; Stale = 0; Reads = 0; Delay = 0
        Positions = [System.Collections.Generic.List[double]]::new(); Seen = @{}; Visits = 0 }
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalViewSize = 10.0; VerticalScrollPercent = 0.0 } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Vertical)
        $this.Current.VerticalScrollPercent = $Vertical
        $state.Positions.Add($Vertical)
        $state.Delay = 1
    }
    $list = [pscustomobject]@{}
    $list | Add-Member ScriptMethod GetCurrentPattern { param($Pattern); return $scroll }
    $list | Add-Member ScriptMethod FindAll {
        param($Scope, $Condition)
        $state.Reads++
        if ($state.Stale -gt 0) {
            $state.Stale--
            throw [System.Windows.Automation.ElementNotAvailableException]::new("fixture stale list")
        }
        if ($state.Delay-- -gt 0) { return @() }
        $first = if ($scroll.Current.VerticallyScrollable) {
            [int][Math]::Floor($scroll.Current.VerticalScrollPercent / 100 * ($state.Rows - 10))
        } else { 0 }
        $last = [Math]::Min($state.Rows - 1, $first + 9)
        return @($first..$last | ForEach-Object { [pscustomobject]@{ Current = [pscustomobject]@{ Name = "row-$_" } } })
    }
    function Find-HistoryControl([string] $Value) { return $list }
    function Wait-HistoryState([scriptblock] $Predicate, [string] $Description) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (& $Predicate) { return }
        }
        throw "Timed out waiting for $Description."
    }
    $visit = {
        param($Items)
        $state.Visits++
        foreach ($item in $Items) { $state.Seen[$item.Current.Name] = $true }
    }.GetNewClosure()
    Visit-HistoryRowsCore $visit
    Assert-HistoryTest $state.Seen.Count 100 "Exhaustive virtualized reachability"
    Assert-HistoryTest $state.Positions[0] 0 "First boundary"
    Assert-HistoryTest $state.Positions[-1] 100 "Last boundary"
    if ($state.Visits -ge 20) { throw "Viewport traversal must not take 101 positions." }
    $state.Rows = 5
    $state.Visits = 0
    $state.Seen.Clear()
    $scroll.Current.VerticallyScrollable = $false
    Visit-HistoryRowsCore $visit
    Assert-HistoryTest $state.Visits 1 "Non-scrollable five-row final page"
    Assert-HistoryTest $state.Seen.Count 5 "All short-page rows"
    $state.Stale = 1
    Visit-HistoryRowsCore $visit
    $state.Stale = 3
    Assert-HistoryFailure { Visit-HistoryRowsCore $visit } "*fixture stale list*"
    $state.Rows = 0
    $state.Stale = 0
    $list | Add-Member ScriptMethod FindAll { param($Scope, $Condition); return @() } -Force
    Assert-HistoryFailure { Visit-HistoryRowsCore $visit } "*Timed out waiting for realized history rows*"
    $list | Add-Member ScriptMethod FindAll { throw [InvalidOperationException]::new("unexpected fixture error") } -Force
    Assert-HistoryFailure { Visit-HistoryRowsCore $visit } "*unexpected fixture error*"
}

& {
    $script:historyTimings = @{}
    $script:process = [pscustomobject]@{ MainWindowHandle = [IntPtr]::Zero }
    $script:ScreenshotDirectory = "fixture-screenshots"
    $time = Get-HistoryLocalTime 0
    $row = [pscustomobject]@{ Current = [pscustomobject]@{
        Name = "$($time.ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed present" } }
    $rowTexts = @($time.ToString("yyyy-MM-dd"), $time.ToString("HH:mm:ss"), "Present") |
        ForEach-Object { [pscustomobject]@{ Current = [pscustomobject]@{ Name = $_ } } }
    $row | Add-Member ScriptMethod FindAll { param($Scope, $Condition); return $rowTexts }
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticallyScrollable = $false } }
    $list = [pscustomobject]@{}
    $list | Add-Member ScriptMethod GetCurrentPattern { param($Pattern); return $scroll }
    function Find-HistoryControl([string] $Value) {
        if ($Value -eq "DeviceScanHistoryCount") {
            return [pscustomobject]@{ Current = [pscustomobject]@{ Name = "1 completed scan observations" } }
        }
        return $list
    }
    function Show-HistorySection([string] $Id) { return $list }
    function Visit-HistoryRowsCore([scriptblock] $Visit) { & $Visit @($row) }
    function Save-HistoryScreenshot { param($Handle, $Path) }
    Assert-HistoryRows fixture 0
    Assert-HistoryTest $script:historyTimings["list-traversal"].Calls 1 "Timed callback retains script-local helpers"
}

. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScenarios.ps1")
function Invoke-UiReviewGit([string] $RepositoryPath, [string[]] $Arguments) {
    if ($Arguments[0] -eq "merge-base") { return "fixture-base" }
    return @("tests/DeviceScanHistory.Ui.Tests.ps1")
}
$plan = @(Get-UiReviewCapturePlan -RepositoryPath $PSScriptRoot -BaseRevision fixture-base)
if ($plan.Scenario -notcontains "DeviceDetails") { throw "Native history changes must select history validation." }
Write-Host "History scoped lookup, section positioning, viewport traversal and failure checks passed."
