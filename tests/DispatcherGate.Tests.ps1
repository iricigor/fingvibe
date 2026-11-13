$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-DispatcherGate.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-dispatch-test-" + [guid]::NewGuid())
$parameters = @{ Repository = "TestOwner/TestRepo"; StateDirectory = $root }
$owner = [guid]::NewGuid()
$other = [guid]::NewGuid()
$path = Join-Path $root "testowner\testrepo.dispatch.json"

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

try {
    $record = (& $script -Action Acquire -Owner $owner @parameters) | ConvertFrom-Json
    if ($record.owner -ne $owner.ToString() -or $record.repository -cne "testowner/testrepo" -or
        $record.schema -ne "fingvibe-dispatch-gate-v1" -or
        ([DateTimeOffset] $record.acquiredUtc).Offset -ne [TimeSpan]::Zero) {
        throw "Acquisition must persist normalized repository, owner, schema, and UTC time."
    }
    Assert-Throws { & $script -Action Acquire -Owner $other @parameters } "*Cannot acquire Dispatcher gate*"
    Assert-Throws { & $script -Action Acquire -Owner $owner @parameters } "*Cannot acquire Dispatcher gate*"
    Assert-Throws { & $script -Action Release -Owner $other @parameters } "*does not belong to this run*"
    if (-not (Test-Path -LiteralPath $path)) { throw "Wrong-owner release removed the gate." }
    & $script -Action Release -Owner $owner @parameters | Out-Null
    if (Test-Path -LiteralPath $path) { throw "Owner release retained the gate." }
    & $script -Action Acquire -Owner $other @parameters | Out-Null
    & $script -Action Release -Owner $other @parameters | Out-Null
    $jobs = @()
    try {
        foreach ($candidate in @($owner, $other)) {
            $jobs += Start-Job -ScriptBlock {
                param($Script, $Root, $Owner)
                try {
                    & $Script -Action Acquire -Repository "TestOwner/TestRepo" -StateDirectory $Root -Owner $Owner | Out-Null
                    [pscustomobject]@{ Acquired = $true; Owner = $Owner; Error = $null }
                } catch {
                    [pscustomobject]@{ Acquired = $false; Owner = $Owner; Error = $_.Exception.Message }
                }
            } -ArgumentList $script, $root, $candidate
        }
        $jobs | Wait-Job -Timeout 30 | Out-Null
        if (@($jobs | Where-Object State -NE "Completed").Count -ne 0) {
            throw "Concurrent acquisition jobs did not finish."
        }
        $results = @($jobs | Receive-Job)
        $winners = @($results | Where-Object Acquired)
        $losers = @($results | Where-Object { -not $_.Acquired })
        if ($winners.Count -ne 1 -or $losers.Count -ne 1 -or
            $losers[0].Error -notlike "*Cannot acquire Dispatcher gate*") {
            throw "Exactly one independent process must acquire the shared gate."
        }
        & $script -Action Release -Owner $winners[0].Owner @parameters | Out-Null
    } finally {
        foreach ($job in $jobs) {
            if ($job.State -notin @("Completed", "Failed", "Stopped")) { Stop-Job -Id $job.Id }
            Remove-Job -Id $job.Id
        }
    }
    Assert-Throws { & $script -Action Acquire -Owner ([guid]::Empty) @parameters } "*nonempty UUID*"
    Assert-Throws {
        & $script -Action Acquire -Owner $owner -Repository "../repo" -StateDirectory $root
    } "*does not match*"
    Assert-Throws {
        & $script -Action Acquire -Owner $owner -Repository "owner/.." -StateDirectory $root
    } "*does not match*"
    Assert-Throws {
        & $script -Action Acquire -Owner $owner -Repository "owner/repo" -StateDirectory "."
    } "*must be absolute*"
    [IO.File]::WriteAllText($path, '{"schema":"broken"}')
    Assert-Throws { & $script -Action Acquire -Owner $owner @parameters } "*Cannot acquire Dispatcher gate*"
    Assert-Throws { & $script -Action Release -Owner $owner @parameters } "*does not belong to this run*"
    if (-not (Test-Path -LiteralPath $path)) { throw "Uncertain gate was discarded." }
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $directory = Join-Path $root "testowner"
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root }
}
Write-Output "Dispatcher gate tests passed."
& (Join-Path $PSScriptRoot "DispatcherPreflight.Tests.ps1")
& (Join-Path $PSScriptRoot "Agent3Coordination.Tests.ps1")
& (Join-Path $PSScriptRoot "Agent3Protocol.Tests.ps1")
& (Join-Path $PSScriptRoot "Agent3Publication.Tests.ps1")
