[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Initialize", "Offer", "Correlate", "Confirm", "Progress", "Followup", "Release", "Publish")]
    [string] $Action,
    [Parameter(Mandatory)][string] $Directory,
    [Parameter(Mandatory)][string] $InputPath,
    [guid] $GateOwner,
    [string] $GateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination")
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "Agent4Coordination.psm1") -Force -DisableNameChecking
$inputRecord = Read-Agent4Json $InputPath
$statePath = Join-Path $Directory "state.json"
if ($Action -eq "Initialize") {
    $next = New-Agent4State $inputRecord
    Save-Agent4State $next $Directory -1 $GateOwner $GateDirectory
} else {
    $state = Read-Agent4Json $statePath
    Assert-Agent4State $state
    if ($Action -eq "Publish") {
        Publish-Agent4WorkerRecord $state $inputRecord.record $inputRecord.observedActor $Directory
        return
    }
    if ($Action -in @("Confirm", "Progress")) {
        $eventRoot = [IO.Path]::GetFullPath((Join-Path $Directory "events")) + [IO.Path]::DirectorySeparatorChar
        if (-not [IO.Path]::GetFullPath($inputRecord.recordPath).StartsWith($eventRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Only immutable records in this environment's events directory may be ingested."
        }
    }
    $next = switch ($Action) {
        "Offer" { New-Agent4Offers $state $inputRecord.packet $inputRecord.hostObservations }
        "Correlate" { Set-Agent4OfferHost $state $inputRecord.offerId $inputRecord.runId $inputRecord.sessionId $inputRecord.evidence }
        "Confirm" {
            $record = Read-Agent4Json $inputRecord.recordPath
            Confirm-Agent4Response $state $record $inputRecord.observedActor $inputRecord.freshEvidence
        }
        "Progress" {
            $record = Read-Agent4Json $inputRecord.recordPath
            Set-Agent4Progress $state $record $inputRecord.observedActor
        }
        "Followup" {
            New-Agent4Followup $state $inputRecord.claimId $inputRecord.action $inputRecord.runId `
                $inputRecord.sessionId $inputRecord.stoppedEvidence $inputRecord.feedback $inputRecord.expectedHead
        }
        "Release" {
            Release-Agent4Claim $state $inputRecord.claimId $inputRecord.stoppedEvidence `
                $inputRecord.deliveryEvidence $inputRecord.cleanupEvidence
        }
    }
    Save-Agent4State $next $Directory $state.revision $GateOwner $GateDirectory
}
$next | ConvertTo-Json -Depth 100
