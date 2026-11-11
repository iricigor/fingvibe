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
    $state = @{ Moves = 0; Geometry = $null; MissingBoundsMoves = 0; Direction = 0; Reversals = 0 }
    $targetDescription = $Description
    $positionClock = [Diagnostics.Stopwatch]::StartNew()
    $positioned = Wait-UiRegressionState -Description "$Description inside its viewport" -TimeoutMilliseconds $TimeoutMilliseconds -Condition {
        try {
            $viewportElement = & $GetViewport
            $windowElement = & $GetWindow
            $elements = @(& $GetTargets)
            if (-not (Test-UiRegressionElementVisible $viewportElement) -or
                -not (Test-UiRegressionElementVisible $windowElement) -or $elements.Count -eq 0 -or
                @($elements | Where-Object { -not $_ }).Count) { return $null }
            $area = $viewportElement.Current.BoundingRectangle
            $windowArea = $windowElement.Current.BoundingRectangle
            $viewportTop = [Math]::Max($area.Top, $windowArea.Top)
            $viewportBottom = [Math]::Min($area.Bottom, $windowArea.Bottom)
            $top = $viewportTop + $TopMargin
            $bottom = $viewportBottom - $BottomMargin
            if ($bottom -le $top) { throw "$targetDescription has no usable viewport inside the window." }
            $scroll = $viewportElement.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            $missingBounds = @($elements | Where-Object { $_.Current.BoundingRectangle.IsEmpty })
            if ($missingBounds.Count) {
                if (-not $scroll.Current.VerticallyScrollable) {
                    throw "$targetDescription has no rendered bounds in a non-scrollable viewport."
                }
                if ($state.Direction -eq 0) {
                    $state.Direction = if ($scroll.Current.VerticalScrollPercent -ge 50) { -1 } else { 1 }
                }
                if ($state.MissingBoundsMoves -ge 8) {
                    throw "$targetDescription remained unrealized after eight bounded viewport moves."
                }
                $currentPercent = $scroll.Current.VerticalScrollPercent
                $nextPercent = [Math]::Max(0, [Math]::Min(100, $currentPercent + 25 * $state.Direction))
                if ($nextPercent -eq $currentPercent) {
                    if ($state.Reversals -ge 1) {
                        throw "$targetDescription has no rendered bounds after reaching both scroll limits."
                    }
                    $state.Direction = -$state.Direction
                    $state.Reversals++
                    $nextPercent = [Math]::Max(0, [Math]::Min(100, $currentPercent + 25 * $state.Direction))
                }
                $state.MissingBoundsMoves++
                $scroll.SetScrollPercent(-1, $nextPercent)
                return $null
            }
            $targetTop = ($elements | ForEach-Object { $_.Current.BoundingRectangle.Top } | Measure-Object -Minimum).Minimum
            $targetBottom = ($elements | ForEach-Object { $_.Current.BoundingRectangle.Bottom } | Measure-Object -Maximum).Maximum
            if ($targetBottom - $targetTop -gt $bottom - $top) { throw "$targetDescription cannot fit together inside its viewport." }
            $fits = $targetTop -ge $top -and $targetBottom -le $bottom -and
                @($elements | Where-Object { -not (Test-UiRegressionElementWithin $_ $viewportElement $windowElement) }).Count -eq 0
            if ($fits -and (-not $AlignBottom -or [Math]::Abs($targetBottom - $bottom) -le 1 -or
                    $scroll.Current.VerticalScrollPercent -eq 0)) { return $elements[0] }
            if (-not $scroll.Current.VerticallyScrollable) {
                throw "$targetDescription is clipped in a non-scrollable viewport."
            }
            $viewSize = $scroll.Current.VerticalViewSize
            if ($viewSize -le 0 -or $viewSize -ge 100) { return $null }
            $geometry = "$targetTop|$targetBottom|$top|$bottom|$viewSize"
            if ($geometry -eq $state.Geometry) { throw "$targetDescription did not move after a measured scroll adjustment." }
            if ($state.Moves -ge 8) { throw "$targetDescription did not settle after eight measured scroll adjustments." }
            # A single UIA peer may report a bottom edge clipped to the viewport.
            # Reveal it from its known top edge instead of chasing that clipped edge.
            $delta = if (-not $AlignBottom -and $elements.Count -eq 1 -and
                $targetBottom -gt $bottom -and $targetTop -gt $top) { $targetTop - $top }
                elseif ($AlignBottom -or $targetBottom -gt $bottom) { $targetBottom - $bottom }
                else { $targetTop - $top }
            $extent = ($viewportBottom - $viewportTop) * (100 / $viewSize - 1)
            if ($extent -le 0) { throw "$targetDescription has an invalid scroll extent." }
            $percent = [Math]::Max(0.0, [Math]::Min(100.0, $scroll.Current.VerticalScrollPercent + 100 * $delta / $extent))
            $state.Geometry = $geometry
            $state.Moves++
            Write-Host "Positioning ${targetDescription}: target $targetTop-$targetBottom; viewport $top-$bottom; view $viewSize%; scroll $($scroll.Current.VerticalScrollPercent)% -> $percent%."
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

# Device Details shows Overview and History as local tabs; a hidden tab's controls have no UI Automation peers.
$script:UiRegressionDeviceHistoryPattern = '^(Activity|DeviceScanHistory|VirtualDeviceHistory|' +
    'DeviceHistory(Scope|Latest|Newer|Older|PageStatus)$|Refresh activity$|Completed Scan Observations$|' +
    'Newer scans$|Older scans$|MAC and address history$|Device activity grid$|Completed scan history)'

function Get-UiRegressionDeviceTabFor {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -cmatch $script:UiRegressionDeviceHistoryPattern) { "History" } else { "Overview" }
}

function Select-UiRegressionDeviceTab {
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)][ValidateSet("Overview", "History")][string] $Tab,
        [switch] $Keyboard,
        [switch] $IfOpen
    )
    $byId = { param($Id) $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)) }
    $item = & $byId "Device${Tab}Tab"
    # The tab bar scrolls with the page; only a hidden Details page removes its peers.
    if (-not $item) {
        if ($IfOpen) { return $false }
        throw "Device Details is not open, so its $Tab tab cannot be selected."
    }
    $selection = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (-not $selection.Current.IsSelected) {
        if ($Keyboard) {
            # Focus the target tab like a keyboard user tabbing to it, then activate it.
            $item.SetFocus()
            $null = Wait-UiRegressionState -Description "keyboard focus on Device Details $Tab tab" -Condition { $item.Current.HasKeyboardFocus }
            [System.Windows.Forms.SendKeys]::SendWait(" ")
            Start-Sleep -Milliseconds 200
            if (-not $selection.Current.IsSelected) { [System.Windows.Forms.SendKeys]::SendWait("{ENTER}") }
        }
        else { $selection.Select() }
    }
    # Panels have no UI Automation peers; tab-owned text controls prove which panel is realized.
    $sentinel = @{ Overview = "DeviceHistoryFirstSeen"; History = "ActivityWindow" }
    $hidden = if ($Tab -eq "History") { "Overview" } else { "History" }
    $null = Wait-UiRegressionState -Description "Device Details $Tab tab" -Condition {
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected -and
            (& $byId $sentinel[$Tab]) -and -not (& $byId $sentinel[$hidden])
    }
    # Activity renders when History first lays out; wait until the tab's content stops moving
    # so later positioning measures the final layout.
    $script:UiRegressionTabTop = $null
    $null = Wait-UiRegressionState -Description "settled Device Details $Tab layout" -Condition {
        $activity = & $byId "ActivityScroll"
        $top = (& $byId $sentinel[$Tab]).Current.BoundingRectangle.Top
        $settled = $top -eq $script:UiRegressionTabTop -and
            ($Tab -eq "Overview" -or ($activity -and $activity.Current.ItemStatus -notlike "Loading*"))
        $script:UiRegressionTabTop = $top
        $settled
    }
    return $true
}

# Selects the tab that owns a missing Device Details control; returns whether the tab changed.
function Show-UiRegressionDeviceTabFor {
    param([Parameter(Mandatory)] $Root, [Parameter(Mandatory)][string] $Value)
    $tab = Get-UiRegressionDeviceTabFor $Value
    $item = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "Device${tab}Tab"))
    if (-not $item -or
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { return $false }
    Select-UiRegressionDeviceTab -Root $Root -Tab $tab
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

# Async surfaces publish "<State> (request <n>): <selection>" or "Idle" through UI Automation ItemStatus
# (see CONTRIBUTING.md, "Asynchronous surfaces"). Native tests wait for that state instead of incidental UI.
function ConvertFrom-UiRegressionSurfaceStatus {
    param([AllowNull()][AllowEmptyString()][string] $Status)
    if ($Status -ceq 'Idle') { return [pscustomobject]@{ State = 'Idle'; Request = 0; Selection = '' } }
    if ($Status -cmatch '^(?<state>Loading|Ready|Empty|Error) \(request (?<request>[1-9][0-9]*)\): (?<selection>.+)$') {
        return [pscustomobject]@{ State = $Matches.state; Request = [int]$Matches.request; Selection = $Matches.selection }
    }
    throw "Unrecognized async surface status '$Status'; expected '<State> (request <n>): <selection>' or 'Idle'."
}

function Get-UiRegressionSurfaceState {
    param([Parameter(Mandatory)][scriptblock] $GetElement, [Parameter(Mandatory)][string] $Description)
    $element = & $GetElement
    if (-not $element) { throw "The state element of $Description has no UI Automation peer." }
    ConvertFrom-UiRegressionSurfaceStatus $element.Current.ItemStatus
}

function Wait-UiRegressionSurfaceState {
    param(
        [Parameter(Mandatory)][scriptblock] $GetElement,
        [Parameter(Mandatory)][string] $Description,
        [ValidateSet('Loading', 'Ready', 'Empty', 'Error')][string] $State = 'Ready',
        [string] $Selection,
        [ValidateRange(0, [int]::MaxValue)][int] $After = 0,
        [ValidateRange(1, 120000)][int] $TimeoutMilliseconds = 25000,
        [ValidateRange(1, 1000)][int] $PollMilliseconds = 100
    )
    $observed = @{ Last = $null; Missing = $false }
    $surface = $Description
    $condition = {
        # Navigation can briefly remove the surface's peer, so a wait treats absence as "not yet" and reports it on timeout.
        $element = & $GetElement
        $observed.Missing = -not $element
        if (-not $element) { return $null }
        $current = ConvertFrom-UiRegressionSurfaceStatus $element.Current.ItemStatus
        $observed.Last = $current
        if ($current.Request -le $After) { return $null }
        if ($current.State -eq 'Error' -and $State -ne 'Error') {
            throw "$surface reported Error (request $($current.Request)): $($current.Selection)"
        }
        if ($current.State -ne $State -or ($Selection -and $current.Selection -cne $Selection)) { return $null }
        return $current
    }
    try {
        Wait-UiRegressionState -Condition $condition -TimeoutMilliseconds $TimeoutMilliseconds -PollMilliseconds $PollMilliseconds `
            -Description "$Description to report $State$(if ($Selection) { " for '$Selection'" }) after request $After"
    }
    catch {
        $last = $observed.Last
        if ($_.Exception.Message -like 'Timed out*' -and $observed.Missing) {
            throw "$($_.Exception.Message) The state element of $Description has no UI Automation peer."
        }
        if ($last -and $_.Exception.Message -like 'Timed out*') {
            throw "$($_.Exception.Message) Last state: $($last.State) (request $($last.Request)): $($last.Selection)"
        }
        throw
    }
}

function Assert-UiRegressionPeers {
    param([Parameter(Mandatory)] $Root, [Parameter(Mandatory)][string[]] $AutomationIds, [Parameter(Mandatory)][string] $Description)
    $conditions = [System.Windows.Automation.Condition[]]@($AutomationIds | ForEach-Object {
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $_)
    })
    $match = if ($conditions.Count -eq 1) { $conditions[0] } else { [System.Windows.Automation.OrCondition]::new($conditions) }
    $found = @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $match) | ForEach-Object { $_.Current.AutomationId })
    $missing = @($AutomationIds | Where-Object { $_ -notin $found })
    if ($missing) { throw "UI Automation peers missing during ${Description}: $($missing -join ', ')." }
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

function Step-UiRegressionPhase {
    param($Current, [string] $Name, [Parameter(Mandatory)][string] $Directory)
    if ($Current) { Complete-UiRegressionPhase -Phase $Current -Directory $Directory -Succeeded $true }
    $script:UiRegressionCurrentPhase = $Name
    if ($Name) { return Start-UiRegressionPhase -Name $Name }
}

function Start-UiRegressionCall {
    param([Parameter(Mandatory)][ValidateSet("lookup", "positioning", "wait", "launch", "close", "scan")][string] $Category)
    if ($null -eq $script:UiRegressionCallStack) { $script:UiRegressionCallStack = [Collections.Generic.Stack[object]]::new() }
    $call = [pscustomobject]@{ Category = $Category; Clock = [Diagnostics.Stopwatch]::StartNew(); ChildMilliseconds = 0.0 }
    $script:UiRegressionCallStack.Push($call)
    return $call
}

function Complete-UiRegressionCall {
    param([Parameter(Mandatory)] $Call)
    $Call.Clock.Stop()
    while ($script:UiRegressionCallStack.Count -gt 0 -and
        -not [object]::ReferenceEquals($script:UiRegressionCallStack.Pop(), $Call)) { }
    $inclusive = $Call.Clock.Elapsed.TotalMilliseconds
    # Exclusive time removes nested measured calls, e.g. lookups inside a wait or positioning loop.
    if ($script:UiRegressionCallStack.Count -gt 0) { $script:UiRegressionCallStack.Peek().ChildMilliseconds += $inclusive }
    if ($null -eq $script:UiRegressionCallCosts) { $script:UiRegressionCallCosts = [ordered]@{} }
    $phase = if ($script:UiRegressionCurrentPhase) { $script:UiRegressionCurrentPhase } else { "(none)" }
    $key = "$phase|$($Call.Category)"
    $entry = $script:UiRegressionCallCosts[$key]
    if (-not $entry) {
        $entry = [pscustomobject]@{
            phase = $phase; category = $Call.Category; calls = 0
            inclusiveMilliseconds = 0.0; exclusiveMilliseconds = 0.0; maxMilliseconds = 0.0
        }
        $script:UiRegressionCallCosts[$key] = $entry
    }
    $entry.calls++
    $entry.inclusiveMilliseconds += $inclusive
    $entry.exclusiveMilliseconds += [Math]::Max(0.0, $inclusive - $Call.ChildMilliseconds)
    $entry.maxMilliseconds = [Math]::Max($entry.maxMilliseconds, $inclusive)
}

function Write-UiRegressionCallCosts {
    param([Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][string] $Name)
    $entries = @(if ($script:UiRegressionCallCosts) { $script:UiRegressionCallCosts.Values })
    $null = New-Item -ItemType Directory -Path $Directory -Force
    [ordered]@{
        check = $Name
        note = "Exclusive time removes nested measured calls; positioning and wait exclusive time is property reads, scrolling and polling sleeps."
        entries = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory "call-costs.json") -Encoding UTF8
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $totals = @($entries | Group-Object category | Sort-Object Name | ForEach-Object {
        $calls = ($_.Group | Measure-Object calls -Sum).Sum
        $seconds = (($_.Group | Measure-Object exclusiveMilliseconds -Sum).Sum / 1000).ToString("F1", $culture)
        "$($_.Name) $calls calls $seconds s"
    })
    $line = "$Name call costs (exclusive): $(if ($totals) { $totals -join '; ' } else { 'none recorded' })"
    Write-Host $line
    if ($env:GITHUB_STEP_SUMMARY) { $line >> $env:GITHUB_STEP_SUMMARY }
}

function Invoke-UiRegressionCleanup {
    param([Parameter(Mandatory)][scriptblock[]] $Steps, [bool] $PrimaryFailed)
    $errors = @()
    foreach ($step in $Steps) {
        try { & $step }
        catch { $errors += $_ }
    }
    foreach ($failure in $errors) { Write-Warning "UI regression cleanup failed: $($failure.Exception.Message)" }
    # A cleanup failure must not replace the original check failure.
    if ($errors.Count -gt 0 -and -not $PrimaryFailed) { throw $errors[0] }
}

function Resolve-UiRegressionGroups {
    param([Parameter(Mandatory)][hashtable] $Definition, [Parameter(Mandatory)][string] $Group)
    $groups = @($Definition.Groups)
    if ($Group -eq 'All') { return $groups }
    $selected = @($groups | Where-Object { $_.Name -eq $Group })
    if ($selected.Count -ne 1) {
        throw "Unknown UI regression group '$Group'; expected All or one of: $(@($groups.Name) -join ', ')."
    }
    return $selected
}

function Invoke-UiRegressionGroups {
    param(
        [Parameter(Mandatory)][string] $Suite,
        [Parameter(Mandatory)][hashtable] $Definition,
        [Parameter(Mandatory)][string] $Group,
        [Parameter(Mandatory)][string] $ModuleDirectory,
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string[]] $EnvironmentNames,
        [string[]] $StateVariables = @(),
        [scriptblock] $OnFailure,
        [scriptblock[]] $Cleanup = @()
    )
    $uiRegressionGroupFailures = [Collections.Generic.List[string]]::new()
    foreach ($uiRegressionGroup in @(Resolve-UiRegressionGroups -Definition $Definition -Group $Group)) {
        $uiRegressionGroupResult = @{ Error = $null }
        $uiRegressionGroupClock = [Diagnostics.Stopwatch]::StartNew()
        # Each group runs in its own scope: its modules share state, but nothing leaks into later groups.
        & {
            foreach ($uiRegressionGroupStateName in $StateVariables) { Set-Variable -Name $uiRegressionGroupStateName -Value $null }
            $uiRegressionGroupSavedEnvironment = Save-UiRegressionEnvironment -Names $EnvironmentNames
            try {
                foreach ($regressionModule in @($Definition.Preconditions) + @($uiRegressionGroup.Modules)) {
                    $regressionPhase = Start-UiRegressionPhase -Name "$Suite/$($uiRegressionGroup.Name)/$regressionModule"
                    $regressionSucceeded = $false
                    try {
                        . (Join-Path $ModuleDirectory "$Suite.$regressionModule.Scenario.ps1")
                        $regressionSucceeded = $true
                    }
                    finally {
                        Complete-UiRegressionPhase -Phase $regressionPhase -Directory $Directory -Succeeded $regressionSucceeded
                    }
                }
            }
            catch {
                $uiRegressionGroupResult.Error = $_
                Write-Host $_
                Write-Host $_.ScriptStackTrace
                if ($OnFailure) {
                    try { & $OnFailure $uiRegressionGroup.Name }
                    catch { Write-Warning "UI regression failure capture failed: $($_.Exception.Message)" }
                }
            }
            finally {
                $uiRegressionCleanupPhase = Start-UiRegressionPhase -Name "$Suite/$($uiRegressionGroup.Name)/Cleanup"
                $uiRegressionCleanupSucceeded = $false
                try {
                    Invoke-UiRegressionCleanup -PrimaryFailed ($null -ne $uiRegressionGroupResult.Error) -Steps (@($Cleanup) + @(
                        { Restore-UiRegressionEnvironment -Saved $uiRegressionGroupSavedEnvironment }))
                    $uiRegressionCleanupSucceeded = $true
                }
                catch { $uiRegressionGroupResult.Error = $_ }
                finally {
                    Complete-UiRegressionPhase -Phase $uiRegressionCleanupPhase -Directory $Directory -Succeeded $uiRegressionCleanupSucceeded
                }
            }
        }
        $uiRegressionGroupClock.Stop()
        $uiRegressionGroupSeconds = $uiRegressionGroupClock.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
        $uiRegressionGroupStatus = if ($uiRegressionGroupResult.Error) { 'failed' } else { 'passed' }
        $uiRegressionGroupLine = "$Suite group $($uiRegressionGroup.Name) $uiRegressionGroupStatus in $uiRegressionGroupSeconds seconds"
        Write-Host $uiRegressionGroupLine
        if ($env:GITHUB_STEP_SUMMARY) { $uiRegressionGroupLine >> $env:GITHUB_STEP_SUMMARY }
        if ($uiRegressionGroupResult.Error) {
            $uiRegressionGroupFailures.Add("$($uiRegressionGroup.Name) ($($uiRegressionGroupResult.Error.Exception.Message))")
        }
    }
    if ($uiRegressionGroupFailures.Count -gt 0) {
        throw "$Suite groups failed: $($uiRegressionGroupFailures -join '; ')"
    }
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
