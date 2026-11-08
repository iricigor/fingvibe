function Wait-UiRegressionState {
    param(
        [Parameter(Mandatory)][scriptblock] $Condition,
        [Parameter(Mandatory)][string] $Description,
        [ValidateRange(1, 120000)][int] $TimeoutMilliseconds = 10000,
        [ValidateRange(1, 1000)][int] $PollMilliseconds = 100
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = & $Condition
        if ($result) { return $result }
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
        $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min($PollMilliseconds, $remaining))
    } while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "Timed out after $TimeoutMilliseconds ms waiting for $Description."
}

function Test-UiRegressionElementVisible {
    param($Element)
    $Element -and -not $Element.Current.IsOffscreen -and
        -not $Element.Current.BoundingRectangle.IsEmpty -and
        $Element.Current.BoundingRectangle.Width -gt 0 -and
        $Element.Current.BoundingRectangle.Height -gt 0
}

function Test-UiRegressionElementWithin {
    param($Element, $Viewport, $Window)
    if (-not (Test-UiRegressionElementVisible $Element) -or
        -not (Test-UiRegressionElementVisible $Viewport) -or
        -not (Test-UiRegressionElementVisible $Window)) { return $false }
    $bounds = $Element.Current.BoundingRectangle
    foreach ($container in @($Viewport, $Window)) {
        $area = $container.Current.BoundingRectangle
        if ($bounds.Left -lt $area.Left -or $bounds.Right -gt $area.Right -or
            $bounds.Top -lt $area.Top -or $bounds.Bottom -gt $area.Bottom) { return $false }
    }
    return $true
}

function Show-UiRegressionScrollTargets {
    param(
        [Parameter(Mandatory)][scriptblock] $GetViewport,
        [Parameter(Mandatory)][scriptblock] $GetTargets,
        [Parameter(Mandatory)][scriptblock] $GetWindow,
        [Parameter(Mandatory)][string] $Description,
        [double] $TopMargin = 0,
        [double] $BottomMargin = 0,
        [switch] $AlignBottom,
        [ValidateRange(1, 10000)][int] $TimeoutMilliseconds = 10000
    )
    $state = @{ Moves = 0; Geometry = $null }
    $targetDescription = $Description
    $positionClock = [Diagnostics.Stopwatch]::StartNew()
    $positioned = Wait-UiRegressionState -Description "$Description inside its viewport" -TimeoutMilliseconds $TimeoutMilliseconds -Condition {
        try {
            $viewportElement = & $GetViewport
            $windowElement = & $GetWindow
            $elements = @(& $GetTargets)
            if (-not $viewportElement -or -not $windowElement -or $elements.Count -eq 0 -or
                @($elements | Where-Object { -not $_ -or $_.Current.BoundingRectangle.IsEmpty }).Count) { return $null }
            $area = $viewportElement.Current.BoundingRectangle
            $windowArea = $windowElement.Current.BoundingRectangle
            $top = [Math]::Max($area.Top, $windowArea.Top) + $TopMargin
            $bottom = [Math]::Min($area.Bottom, $windowArea.Bottom) - $BottomMargin
            $targetTop = ($elements | ForEach-Object { $_.Current.BoundingRectangle.Top } | Measure-Object -Minimum).Minimum
            $targetBottom = ($elements | ForEach-Object { $_.Current.BoundingRectangle.Bottom } | Measure-Object -Maximum).Maximum
            if ($targetBottom - $targetTop -gt $bottom - $top) { throw "$targetDescription cannot fit together inside its viewport." }
            $fits = $targetTop -ge $top -and $targetBottom -le $bottom -and
                @($elements | Where-Object { -not (Test-UiRegressionElementWithin $_ $viewportElement $windowElement) }).Count -eq 0
            $scroll = $viewportElement.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            if ($fits -and (-not $AlignBottom -or [Math]::Abs($targetBottom - $bottom) -le 1 -or
                    $scroll.Current.VerticalScrollPercent -eq 0)) { return $elements[0] }
            if (-not $scroll.Current.VerticallyScrollable) {
                throw "$targetDescription is clipped in a non-scrollable viewport."
            }
            $viewSize = $scroll.Current.VerticalViewSize
            if ($viewSize -le 0 -or $viewSize -ge 100) { return $null }
            $geometry = "$targetTop|$targetBottom|$top|$bottom|$viewSize"
            if ($geometry -eq $state.Geometry) { return $null }
            if ($state.Moves -ge 8) { throw "$targetDescription did not settle after eight measured scroll adjustments." }
            $delta = if ($AlignBottom -or $targetBottom -gt $bottom) { $targetBottom - $bottom } else { $targetTop - $top }
            $extent = $area.Height * (100 / $viewSize - 1)
            $percent = [Math]::Max(0, [Math]::Min(100, $scroll.Current.VerticalScrollPercent + 100 * $delta / $extent))
            $state.Geometry = $geometry
            $state.Moves++
            $scroll.SetScrollPercent(-1, $percent)
            # The next bounded observation must see the actual target bounds, not just a changed percentage.
            return $null
        }
        catch {
            if ($_.Exception.GetBaseException().GetType().FullName -ne
                'System.Windows.Automation.ElementNotAvailableException') { throw }
            return $null
        }
    }
    Write-Host "Positioned $targetDescription in $($state.Moves) measured scroll adjustments, $($positionClock.ElapsedMilliseconds) ms."
    return $positioned
}

function Find-UiRegressionElement {
    param(
        [Parameter(Mandatory)][scriptblock] $Container,
        [Parameter(Mandatory)] $Condition,
        [Parameter(Mandatory)][string] $Description,
        [switch] $Optional,
        [scriptblock] $Find = {
            param($Owner, $Match)
            $Owner.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $Match)
        }
    )
    $matchCondition = $Condition
    $lookup = {
        try {
            $owner = & $Container
            if (-not $owner) { return $null }
            $element = & $Find $owner $matchCondition
            if (Test-UiRegressionElementVisible $element) { return $element }
        }
        catch {
            if ($_.Exception.GetBaseException().GetType().FullName -ne
                'System.Windows.Automation.ElementNotAvailableException') { throw }
        }
        return $null
    }
    if ($Optional) { return & $lookup }
    Wait-UiRegressionState -Condition $lookup -Description $Description
}

function Wait-UiRegressionWindow {
    param([Parameter(Mandatory)] $Process, [int] $TimeoutMilliseconds = 30000)
    Wait-UiRegressionState -TimeoutMilliseconds $TimeoutMilliseconds -Description "app window (PID $($Process.Id))" -Condition {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Review app exited with code $($Process.ExitCode)." }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        return $null
    }
}

function Get-UiRegressionPageContainer {
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)][string] $PageMarkerId,
        [string] $ContainerId = 'MainNavigation'
    )
    $marker = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $PageMarkerId))
    if (-not (Test-UiRegressionElementVisible $marker)) { return $null }
    $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $ContainerId))
}

function Stop-UiRegressionApp {
    param(
        $Process,
        [ValidateRange(1, 30000)][int] $TimeoutMilliseconds = 5000,
        [scriptblock] $Terminate = { param($App) Stop-Process -Id $App.Id -ErrorAction Stop }
    )
    if (-not $Process -or $Process.HasExited) { return }
    $null = $Process.CloseMainWindow()
    if ($Process.WaitForExit($TimeoutMilliseconds)) { return }
    & $Terminate $Process
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        throw "Review app PID $($Process.Id) did not terminate after forced cleanup."
    }
    throw "Review app PID $($Process.Id) did not close normally; forced cleanup was required."
}

function Save-UiRegressionEnvironment {
    param([Parameter(Mandatory)][string[]] $Names)
    $saved = @{}
    foreach ($name in $Names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    return $saved
}

function New-UiRegressionFixtureDirectory {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string] $Suite)
    $path = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-$Suite-$([Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $path
    return $path
}

function Restore-UiRegressionEnvironment {
    param([Parameter(Mandatory)][hashtable] $Saved)
    foreach ($name in $Saved.Keys) {
        if ($null -eq $Saved[$name]) {
            if (Test-Path -LiteralPath "Env:\$name") { Remove-Item -LiteralPath "Env:\$name" }
        } else { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) }
    }
}

function Start-UiRegressionPhase {
    param([Parameter(Mandatory)][string] $Name)
    Write-Host "Starting UI regression phase: $Name"
    [pscustomobject]@{ Name = $Name; StartedUtc = [DateTime]::UtcNow; Clock = [Diagnostics.Stopwatch]::StartNew() }
}

function Complete-UiRegressionPhase {
    param(
        [Parameter(Mandatory)] $Phase,
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][bool] $Succeeded
    )
    $Phase.Clock.Stop()
    $record = [ordered]@{
        phase = $Phase.Name; startedUtc = $Phase.StartedUtc.ToString('o')
        elapsedMilliseconds = $Phase.Clock.Elapsed.TotalMilliseconds; succeeded = $Succeeded
    }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $Directory 'phases.jsonl') -Encoding UTF8
    $seconds = $Phase.Clock.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
    $line = "$($Phase.Name) elapsed: $seconds seconds; succeeded=$Succeeded"
    Write-Host $line
    if ($env:GITHUB_STEP_SUMMARY) { $line >> $env:GITHUB_STEP_SUMMARY }
}

function Save-UiRegressionScreenshot {
    param([Parameter(Mandatory)][IntPtr] $WindowHandle, [Parameter(Mandatory)][string] $Path)
    $phase = Start-UiRegressionPhase -Name "capture/$([IO.Path]::GetFileName($Path))"
    $succeeded = $false
    try {
        Save-UiReviewWindowScreenshot $WindowHandle $Path
        $succeeded = $true
    }
    finally {
        Complete-UiRegressionPhase -Phase $phase -Directory ([IO.Path]::GetDirectoryName($Path)) -Succeeded $succeeded
    }
}
