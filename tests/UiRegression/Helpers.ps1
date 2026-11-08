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
            if ($element -and -not $element.Current.IsOffscreen -and
                -not $element.Current.BoundingRectangle.IsEmpty -and
                $element.Current.BoundingRectangle.Width -gt 0 -and
                $element.Current.BoundingRectangle.Height -gt 0) { return $element }
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
        [Parameter(Mandatory)][string] $NavigationId,
        [string] $ContainerId = 'MainNavigation'
    )
    $navigation = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $NavigationId))
    if (-not $navigation -or -not $navigation.GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { return $null }
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
