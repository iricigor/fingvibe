param(
    [Parameter(Mandatory)][string] $SourceDirectory,
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [Parameter(Mandatory)][ValidateSet("section", "list")][string] $Experiment
)

$ErrorActionPreference = "Stop"
$script:pinnedCommit = "ebd4f07d731d5f4df45d1949f4c3b79fb1ebb9e2"

function Get-HistoryProbeRectangle($Rectangle) {
    if ($Rectangle.IsEmpty) { return @{ empty = $true; raw = "$Rectangle" } }
    return @{
        empty = $false; raw = "$Rectangle"
        left = $Rectangle.Left; top = $Rectangle.Top
        right = $Rectangle.Right; bottom = $Rectangle.Bottom
        width = $Rectangle.Width; height = $Rectangle.Height
    }
}

function Test-HistoryProbeIntersection($Bounds, $Clip) {
    return -not $Bounds.empty -and -not $Clip.empty -and $Bounds.width -gt 0 -and $Bounds.height -gt 0 -and
        $Bounds.right -gt $Clip.left -and $Bounds.left -lt $Clip.right -and
        $Bounds.bottom -gt $Clip.top -and $Bounds.top -lt $Clip.bottom
}

function Write-HistoryProbeEvent([string] $Event, $Data) {
    $record = @{
        schema = 1; utc = [DateTime]::UtcNow.ToString("o")
        elapsedMs = $script:probeClock.Elapsed.TotalMilliseconds
        experiment = $Experiment; event = $Event; data = $Data
    }
    $record | ConvertTo-Json -Depth 20 -Compress |
        Add-Content -LiteralPath $script:probeTrace -Encoding utf8
}

function Get-HistoryProbeElement([string] $Id, $Within = $script:root) {
    if (-not $Within) { throw "Missing owner when locating diagnostic peer '$Id'." }
    $probeCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    return $Within.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $probeCondition)
}

function Get-HistoryProbePeer($Element, [switch] $Patterns) {
    if (-not $Element) { return @{ status = "missing" } }
    try {
        $probeCache = [System.Windows.Automation.CacheRequest]::new()
        foreach ($probeProperty in @(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            [System.Windows.Automation.AutomationElement]::NameProperty,
            [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty,
            [System.Windows.Automation.AutomationElement]::IsOffscreenProperty,
            [System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty,
            [System.Windows.Automation.AutomationElement]::HasKeyboardFocusProperty)) {
            $probeCache.Add($probeProperty)
        }
        $probeCurrent = $Element.GetUpdatedCache($probeCache).Cached
        $probePeer = @{
            status = "available"; id = $probeCurrent.AutomationId; name = $probeCurrent.Name
            runtimeId = @($Element.GetRuntimeId())
            bounds = Get-HistoryProbeRectangle $probeCurrent.BoundingRectangle
            offscreen = $probeCurrent.IsOffscreen; focusable = $probeCurrent.IsKeyboardFocusable
            focused = $probeCurrent.HasKeyboardFocus
        }
        $probePattern = $null
        if ($Patterns) {
            $probePeer.patterns = @($Element.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
        }
        if ($Patterns -and $Element.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$probePattern)) {
            $probePeer.scroll = @{
                percent = $probePattern.Current.VerticalScrollPercent
                viewSize = $probePattern.Current.VerticalViewSize
                scrollable = $probePattern.Current.VerticallyScrollable
            }
        }
        $probePattern = $null
        if ($Patterns -and $Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$probePattern)) {
            $probePeer.expansion = "$($probePattern.Current.ExpandCollapseState)"
        }
        return $probePeer
    }
    catch [System.Windows.Automation.ElementNotAvailableException] {
        Write-HistoryProbeEvent unavailable-peer @{ message = $_.Exception.Message; stack = $_.ScriptStackTrace }
        return @{ status = "unavailable"; error = $_.Exception.Message }
    }
}

function Write-HistoryProbeSnapshot([string] $Phase, [string] $Command) {
    $probeSampleClock = [Diagnostics.Stopwatch]::StartNew()
    $probeWindow = $script:root.Current.BoundingRectangle
    $probeWindowBounds = Get-HistoryProbeRectangle $probeWindow
    $probeDetails = Get-HistoryProbeElement DeviceDetailsScroll
    $probeExpanderElement = if ($probeDetails) {
        Get-HistoryProbeElement DeviceScanHistoryExpander $probeDetails
    } else { $null }
    $probeList = if ($probeExpanderElement) {
        Get-HistoryProbeElement DeviceScanHistoryList $probeExpanderElement
    } else { $null }
    $probePage = if ($probeExpanderElement) {
        Get-HistoryProbeElement DeviceHistoryPageStatus $probeExpanderElement
    } else { $null }
    $probeListPeer = Get-HistoryProbePeer $probeList -Patterns
    $probeRows = @()
    if ($probeList -and $Experiment -eq "list") {
        $probeRowCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem)
        foreach ($probeItem in $probeList.FindAll([System.Windows.Automation.TreeScope]::Children, $probeRowCondition)) {
            $probeRowPeer = Get-HistoryProbePeer $probeItem
            if ($probeRowPeer.status -eq "available") {
                $probeRowPeer.intersectsWindow = Test-HistoryProbeIntersection $probeRowPeer.bounds $probeWindowBounds
                $probeRowPeer.intersectsList = Test-HistoryProbeIntersection $probeRowPeer.bounds $probeListPeer.bounds
                $probeRowPeer.visibleCandidate = -not $probeRowPeer.offscreen -and
                    $probeRowPeer.intersectsWindow -and $probeRowPeer.intersectsList
            }
            $probeRows += $probeRowPeer
        }
    }
    $probeVisible = @($probeRows | Where-Object { $_.visibleCandidate })
    $probeSnapshot = @{
        phase = $Phase; command = $Command
        window = $probeWindowBounds
        nativeWindow = Get-HistoryProbeRectangle (Get-UiReviewWindowBounds $script:process.MainWindowHandle)
        details = Get-HistoryProbePeer $probeDetails -Patterns
        expander = Get-HistoryProbePeer $probeExpanderElement -Patterns
        cachedDetails = Get-HistoryProbePeer $script:detailsRoot
        cachedObservations = Get-HistoryProbePeer $script:observationsRoot
        list = $probeListPeer
        page = Get-HistoryProbePeer $probePage
        focused = Get-HistoryProbePeer ([System.Windows.Automation.AutomationElement]::FocusedElement)
        enumeratedCount = $probeRows.Count; visibleCandidateCount = $probeVisible.Count
        visibleLabels = @($probeVisible | ForEach-Object { $_.name }); rows = $probeRows
        rowsSampled = $Experiment -eq "list"
    }
    $probeSampleClock.Stop()
    $probeSnapshot.samplingMs = $probeSampleClock.Elapsed.TotalMilliseconds
    Write-HistoryProbeEvent snapshot $probeSnapshot
    return $probeSnapshot
}

function Save-HistoryProbeScreenshot([string] $Label) {
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (
        Join-Path $OutputDirectory "$Label.png")
}

function Invoke-HistoryObservedCommand([string] $CommandText, [scriptblock] $CommandAction,
    [object[]] $CommandArguments = @(), $CommandOwner) {
    Write-HistoryProbeEvent command @{
        text = $CommandText; arguments = @($CommandArguments)
        ownerInstance = if ($CommandOwner) { [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($CommandOwner) } else { $null }
        ownerType = if ($CommandOwner) { $CommandOwner.GetType().FullName } else { $null }
        ownerScroll = if ($CommandOwner -is [System.Windows.Automation.ScrollPattern]) {
            @{ percent = $CommandOwner.Current.VerticalScrollPercent
                viewSize = $CommandOwner.Current.VerticalViewSize
                scrollable = $CommandOwner.Current.VerticallyScrollable }
        } else { $null }
    }
    $probeBefore = Write-HistoryProbeSnapshot before $CommandText
    $probeCommandClock = [Diagnostics.Stopwatch]::StartNew()
    try { & $CommandAction }
    catch {
        Write-HistoryProbeEvent command-error @{
            command = $CommandText; message = $_.Exception.Message; stack = $_.ScriptStackTrace
        }
        throw
    }
    finally { $probeCommandClock.Stop() }
    $probeAfter = Write-HistoryProbeSnapshot immediate $CommandText
    Write-HistoryProbeEvent command-duration @{
        command = $CommandText; milliseconds = $probeCommandClock.Elapsed.TotalMilliseconds
        ownerScrollAfter = if ($CommandOwner -is [System.Windows.Automation.ScrollPattern]) {
            @{ percent = $CommandOwner.Current.VerticalScrollPercent
                viewSize = $CommandOwner.Current.VerticalViewSize
                scrollable = $CommandOwner.Current.VerticallyScrollable }
        } else { $null }
    }
    if ($script:probeQuiet) {
        for ($probePoll = 0; $probePoll -lt 8; $probePoll++) {
            Start-Sleep -Milliseconds 250
            $probeAfter = Write-HistoryProbeSnapshot poll $CommandText
        }
        Write-HistoryProbeEvent observation @{
            command = $CommandText
            visibleLabelsChanged = ($probeBefore.visibleLabels -join "|") -cne ($probeAfter.visibleLabels -join "|")
            beforePercent = $probeBefore.list.scroll.percent; afterPercent = $probeAfter.list.scroll.percent
            beforeDetailsPercent = $probeBefore.details.scroll.percent
            afterDetailsPercent = $probeAfter.details.scroll.percent
            beforeVisible = $probeBefore.visibleLabels; afterVisible = $probeAfter.visibleLabels
            beforeExpander = $probeBefore.expander; afterExpander = $probeAfter.expander
            note = "No compensating command during polling; candidate visibility requires screenshot corroboration."
        }
    }
}

function Get-HistoryInvestigationSource([string] $Path) {
    $probeParseErrors = $null
    $probeAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$probeParseErrors)
    if ($probeParseErrors) { throw ($probeParseErrors.Message -join "; ") }
    $probeStatements = @($probeAst.EndBlock.Statements)
    $probeTry = @($probeStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    })
    if ($probeTry.Count -ne 1) { throw "Pinned source must have one top-level fixture try block." }
    $probeBody = @($probeTry[0].Body.Statements)
    $probeFixtureLoop = @($probeBody | Where-Object {
        $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $_.Variable.VariablePath.UserPath -eq "index"
    })
    $probeThemeLoop = @($probeBody | Where-Object {
        $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $_.Variable.VariablePath.UserPath -eq "theme"
    })
    $probePaged = @($probeBody | Where-Object { $_.Extent.Text.StartsWith('$pagedHistory =') })
    if ($probeFixtureLoop.Count -ne 1 -or $probeThemeLoop.Count -ne 1 -or $probePaged.Count -ne 1) {
        throw "Pinned history fixture structure changed; do not invent replacement fixtures."
    }
    $probePrevious = @($probeStatements | Where-Object { $_.Extent.Text.StartsWith('$previous =') })
    if ($probePrevious.Count -ne 1) { throw "Missing pinned environment preservation." }
    return @{
        ast = $probeAst
        initialization = @($probeStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Extent.StartOffset -lt $probePrevious[0].Extent.StartOffset
        })
        environment = @($probeStatements | Where-Object {
            $_.Extent.StartOffset -ge $probePrevious[0].Extent.StartOffset -and
            $_.Extent.StartOffset -lt $probeTry[0].Extent.StartOffset
        })
        functions = @($probeStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
        })
        fixture = @($probeBody | Where-Object {
            $_.Extent.StartOffset -lt $probeFixtureLoop[0].Extent.StartOffset
        })
        sectionLoop = $probeFixtureLoop[0].Extent.Text
        seedFixture = @($probeFixtureLoop[0].Body.Statements | Where-Object {
            $_.Extent.StartOffset -lt (@($probeFixtureLoop[0].Body.Statements | Where-Object {
                $_.Extent.Text -eq "Start-HistoryApp"
            })[0].Extent.StartOffset)
        })
        themeLoop = $probeThemeLoop[0].Extent.Text
        pagedFixture = @($probeBody | Where-Object {
            $_.Extent.StartOffset -ge $probePaged[0].Extent.StartOffset -and
            $_.Extent.StartOffset -lt (@($probeBody | Where-Object {
                $_.Extent.StartOffset -gt $probePaged[0].Extent.StartOffset -and
                $_.Extent.Text -eq "Start-HistoryApp"
            })[0].Extent.StartOffset)
        })
    }
}

function Add-HistoryCommandInstrumentation($FunctionAst) {
    $probeText = $FunctionAst.Extent.Text
    $probeCalls = @($FunctionAst.FindAll({
        param($probeNode)
        $probeNode -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $probeNode.Member.Value -in @("SetScrollPercent", "Scroll", "ScrollIntoView", "SetFocus")
    }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending)
    foreach ($probeCall in $probeCalls) {
        $probeOriginal = $probeCall.Extent.Text
        $probeLiteral = $probeOriginal.Replace("'", "''")
        $probeArgumentText = (@($probeCall.Arguments | ForEach-Object { $_.Extent.Text }) -join ", ")
        $probeOwnerText = $probeCall.Expression.Extent.Text
        $probeReplacement = "(Invoke-HistoryObservedCommand -CommandText '$probeLiteral' -CommandArguments @($probeArgumentText) -CommandOwner $probeOwnerText -CommandAction { $probeOriginal })"
        $probeOffset = $probeCall.Extent.StartOffset - $FunctionAst.Extent.StartOffset
        $probeText = $probeText.Remove($probeOffset, $probeOriginal.Length).Insert($probeOffset, $probeReplacement)
    }
    return $probeText
}

if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_OS -ne "Windows") {
    throw "Native investigation is restricted to disposable GitHub Windows runners, not the working desktop."
}
$probeActualCommit = git -C $SourceDirectory rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $probeActualCommit -cne $script:pinnedCommit) {
    throw "Source checkout does not match the immutable history revision."
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$script:probeTrace = Join-Path $OutputDirectory "scroll-trace.jsonl"
$script:probeClock = [Diagnostics.Stopwatch]::StartNew()
$script:probeQuiet = $false
$ScreenshotDirectory = $OutputDirectory
$probeSourceTests = Join-Path $SourceDirectory "tests"
. (Join-Path $SourceDirectory ".github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $SourceDirectory ".github\scripts\UiReviewAppearance.ps1")
. (Join-Path $probeSourceTests "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath
$probeSource = Get-HistoryInvestigationSource (Join-Path $probeSourceTests "DeviceScanHistory.Ui.Tests.ps1")
foreach ($probeStatement in $probeSource.initialization) { Invoke-Expression $probeStatement.Extent.Text }
foreach ($probeFunction in $probeSource.functions) {
    $probeDefinition = if ($probeFunction.Name -eq "Show-HistorySectionCore") {
        Add-HistoryCommandInstrumentation $probeFunction
    } else { $probeFunction.Extent.Text }
    Invoke-Expression $probeDefinition
}
foreach ($probeStatement in $probeSource.environment) { Invoke-Expression $probeStatement.Extent.Text }
$probeProvenance = @{
    sourceCommit = $script:pinnedCommit; diagnosticCommit = $env:GITHUB_SHA
    runId = $env:GITHUB_RUN_ID; attempt = $env:GITHUB_RUN_ATTEMPT; experiment = $Experiment
    appSha256 = (Get-FileHash -LiteralPath $AppPath -Algorithm SHA256).Hash
    appVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($AppPath).FileVersion
    os = [Environment]::OSVersion.VersionString
    note = "Read-only UIA sampling can itself realize peers and alter timing. Replay has no added polling delays; controlled commands have a two-second quiet interval."
}
$probeProvenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory "provenance.json")
Write-HistoryProbeEvent start $probeProvenance
try {
    foreach ($probeStatement in $probeSource.fixture) { Invoke-Expression $probeStatement.Extent.Text }
    if ($Experiment -eq "section") {
        Write-HistoryProbeEvent replay @{ sequence = "Exact pinned five fixture iterations, normal/virtual navigation, summary collapse/expand and small-row assertions." }
        Invoke-Expression $probeSource.sectionLoop
        Start-HistoryApp
        Write-HistoryProbeEvent replay @{ sequence = "Pinned light/dark rendering, narrow resize, collapse, position, restore-width sequence." }
        Invoke-Expression $probeSource.themeLoop
        Save-HistoryProbeScreenshot section-replay-end
    }
    else {
        $index = 4
        foreach ($probeStatement in $probeSource.seedFixture) { Invoke-Expression $probeStatement.Extent.Text }
        Start-HistoryApp
        $null = Assert-HistoryLastSeenCell "History normal" "Last seen: $(Get-HistoryExactTime 4)"
        Stop-HistoryApp
        foreach ($probeStatement in $probeSource.pagedFixture) { Invoke-Expression $probeStatement.Extent.Text }
        Start-HistoryApp
        $probeDevice = Find-HistoryDeviceRow "History normal"
        $probeDevice.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Wait-HistoryState { Get-HistoryProbeElement DeviceDetailsScroll } "diagnostic details"
        $script:probeQuiet = $true
        $probeOuter = (Get-HistoryProbeElement DeviceDetailsScroll).GetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern)
        Invoke-HistoryObservedCommand "outer SetScrollPercent(0)" { $probeOuter.SetScrollPercent(-1, 0) }
        $probeExpander = Get-HistoryProbeElement DeviceScanHistoryExpander
        if ($probeExpander.Current.IsKeyboardFocusable) {
            Invoke-HistoryObservedCommand "expander SetFocus" { $probeExpander.SetFocus() }
        } else { Write-HistoryProbeEvent unsupported @{ command = "expander SetFocus" } }
        Invoke-HistoryObservedCommand "expander Expand" {
            $probeExpander.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        }
        Wait-HistoryState {
            $probeStatus = Get-HistoryProbeElement DeviceHistoryPageStatus
            $probeStatus -and $probeStatus.Current.Name -like "Showing 1-100 of 205.*"
        } "pinned 100-row page"
        for ($probePosition = 0; $probePosition -lt 20; $probePosition++) {
            $probeListElement = Get-HistoryProbeElement DeviceScanHistoryList
            if ($probeListElement -and -not $probeListElement.Current.IsOffscreen -and
                -not $probeListElement.Current.BoundingRectangle.IsEmpty -and
                $script:root.Current.BoundingRectangle.Contains($probeListElement.Current.BoundingRectangle)) { break }
            $probeOuter = (Get-HistoryProbeElement DeviceDetailsScroll).GetCurrentPattern(
                [System.Windows.Automation.ScrollPattern]::Pattern)
            Invoke-HistoryObservedCommand "outer LargeIncrement (setup $probePosition)" {
                $probeOuter.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount,
                    [System.Windows.Automation.ScrollAmount]::LargeIncrement)
            }
        }
        if ($probePosition -eq 20) { throw "List setup did not position the list within the window; see independent outer-scroll evidence." }
        Save-HistoryProbeScreenshot list-start
        $probeInner = $probeListElement.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        Invoke-HistoryObservedCommand "inner SetScrollPercent(0)" { $probeInner.SetScrollPercent(-1, 0) }
        $probeSeen = @{}
        for ($probeStep = 0; $probeStep -lt 20; $probeStep++) {
            $probeState = Write-HistoryProbeSnapshot list-checkpoint "step $probeStep"
            foreach ($probeLabel in $probeState.visibleLabels) { $probeSeen[$probeLabel] = $true }
            if (-not $probeState.list.scroll.scrollable) { throw "Pinned 100-row list unexpectedly reports non-scrollable." }
            if ($probeState.list.scroll.percent -ge 99.9) { break }
            $probeInner = (Get-HistoryProbeElement DeviceScanHistoryList).GetCurrentPattern(
                [System.Windows.Automation.ScrollPattern]::Pattern)
            Invoke-HistoryObservedCommand "inner LargeIncrement ($probeStep)" {
                $probeInner.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount,
                    [System.Windows.Automation.ScrollAmount]::LargeIncrement)
            }
            Save-HistoryProbeScreenshot "list-large-$probeStep"
            $probeState = Write-HistoryProbeSnapshot after-large "step $probeStep"
            foreach ($probeLabel in $probeState.visibleLabels) { $probeSeen[$probeLabel] = $true }
            if ($probeState.list.scroll.percent -ge 99.9) { break }
            $probeInner = (Get-HistoryProbeElement DeviceScanHistoryList).GetCurrentPattern(
                [System.Windows.Automation.ScrollPattern]::Pattern)
            Invoke-HistoryObservedCommand "inner SmallDecrement ($probeStep)" {
                $probeInner.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount,
                    [System.Windows.Automation.ScrollAmount]::SmallDecrement)
            }
        }
        Write-HistoryProbeEvent bounded-list-result @{
            steps = $probeStep; candidateLabelsSeen = $probeSeen.Count
            reachedReportedEnd = $probeState.list.scroll.percent -ge 99.9
            note = "Observed candidates only, not exhaustive regression acceptance. All commands and ineffective movement remain in the trace."
        }
        Save-HistoryProbeScreenshot list-end
    }
    Write-HistoryProbeEvent completed @{ outcome = "Experiment executed; interpret trace, not as optimization acceptance." }
}
catch {
    Write-HistoryProbeEvent experiment-error @{ message = $_.Exception.Message; stack = $_.ScriptStackTrace }
    if ($script:process -and -not $script:process.HasExited -and $script:root) {
        Save-HistoryProbeScreenshot failure
    }
    throw
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
