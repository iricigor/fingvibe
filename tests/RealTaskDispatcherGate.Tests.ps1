$ErrorActionPreference = "Stop"
$gate = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-RealTaskDispatcherGate.ps1"
$legacyGate = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-DispatcherGate.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-real-dispatch-test-" + [guid]::NewGuid())
$parameters = @{ Repository = "TestOwner/TestRepo"; StateDirectory = $root }
$owner = [guid]::NewGuid()
$other = [guid]::NewGuid()
$path = Join-Path $root "testowner\testrepo.dispatch.json"

function Assert-GateFailure([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

try {
    foreach ($writer in @($gate, $legacyGate)) {
        $record = (& $writer -Action Acquire -Owner $owner @parameters) | ConvertFrom-Json
        if ($record.owner -ne $owner.ToString() -or $record.repository -cne "testowner/testrepo" -or
            $record.schema -ne "fingvibe-dispatch-gate-v1") {
            throw "Both gate implementations must preserve the shared lock format."
        }
        foreach ($reader in @($gate, $legacyGate)) {
            Assert-GateFailure { & $reader -Action Acquire -Owner $other @parameters } "*Cannot acquire Dispatcher gate*"
            Assert-GateFailure { & $reader -Action Release -Owner $other @parameters } "*does not belong to this run*"
        }
        & $gate -Action Release -Owner $owner @parameters | Out-Null
        if (Test-Path -LiteralPath $path) { throw "Owner release retained the gate." }
    }
    $jobs = @()
    try {
        foreach ($candidate in @($gate, $legacyGate)) {
            $jobs += Start-Job -ScriptBlock {
                param($Script, $Root)
                $owner = [guid]::NewGuid()
                try {
                    & $Script -Action Acquire -Repository "TestOwner/TestRepo" -StateDirectory $Root -Owner $owner | Out-Null
                    [pscustomobject]@{ Acquired = $true; Owner = $owner; Error = $null }
                } catch {
                    [pscustomobject]@{ Acquired = $false; Owner = $owner; Error = $_.Exception.Message }
                }
            } -ArgumentList $candidate, $root
        }
        $jobs | Wait-Job -Timeout 30 | Out-Null
        if (@($jobs | Where-Object State -NE "Completed").Count -ne 0) { throw "Concurrent gate jobs did not finish." }
        $results = @($jobs | Receive-Job)
        $winners = @($results | Where-Object Acquired)
        $losers = @($results | Where-Object { -not $_.Acquired })
        if ($winners.Count -ne 1 -or $losers.Count -ne 1 -or $losers[0].Error -notlike "*Cannot acquire Dispatcher gate*") {
            throw "Only one Dispatcher version may acquire the repository gate."
        }
        & $gate -Action Release -Owner $winners[0].Owner @parameters | Out-Null
    } finally {
        foreach ($job in $jobs) {
            if ($job.State -notin @("Completed", "Failed", "Stopped")) { Stop-Job -Id $job.Id }
            Remove-Job -Id $job.Id
        }
    }
    Assert-GateFailure { & $gate -Action Acquire -Owner ([guid]::Empty) @parameters } "*nonempty UUID*"
    Assert-GateFailure { & $gate -Action Acquire -Owner $owner -Repository "../repo" -StateDirectory $root } "*does not match*"
    Assert-GateFailure { & $gate -Action Acquire -Owner $owner -Repository "owner/repo" -StateDirectory "." } "*must be absolute*"
    $previousLocalAppData = $env:LOCALAPPDATA
    $defaultDirectory = Join-Path $root "FingVibe\AgentCoordination\testowner"
    $defaultPath = Join-Path $defaultDirectory "testrepo.dispatch.json"
    try {
        $env:LOCALAPPDATA = $root
        & $gate -Action Acquire -Owner $owner -Repository "TestOwner/TestRepo" | Out-Null
        if (-not (Test-Path -LiteralPath $defaultPath)) { throw "The real gate changed the default repository lock location." }
        Assert-GateFailure { & $legacyGate -Action Acquire -Owner $other -Repository "TestOwner/TestRepo" } "*Cannot acquire Dispatcher gate*"
        & $legacyGate -Action Release -Owner $owner -Repository "TestOwner/TestRepo" | Out-Null
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        if (Test-Path -LiteralPath $defaultPath) { Remove-Item -LiteralPath $defaultPath }
        foreach ($directory in @($defaultDirectory, (Join-Path $root "FingVibe\AgentCoordination"), (Join-Path $root "FingVibe"))) {
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
        }
    }
    [IO.File]::WriteAllText($path, '{"schema":"broken"}')
    Assert-GateFailure { & $gate -Action Acquire -Owner $owner @parameters } "*Cannot acquire Dispatcher gate*"
    Assert-GateFailure { & $gate -Action Release -Owner $owner @parameters } "*does not belong to this run*"
    if (-not (Test-Path -LiteralPath $path)) { throw "Uncertain gate was discarded." }
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $directory = Join-Path $root "testowner"
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root }
}
Write-Output "Real-task Dispatcher gate and cross-version serialization tests passed."
& (Join-Path $PSScriptRoot "RealTaskDispatcherPreflight.Tests.ps1")
