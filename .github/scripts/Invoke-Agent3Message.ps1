#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Prepare", "Receive", "Confirm", "ProtocolError", IgnoreCase = $false)]
    [string] $Action,
    [Parameter(Mandatory)]
    [string] $InputPath,
    [Parameter(Mandatory)]
    [string] $StatePath,
    [Parameter(Mandatory)]
    [string] $Directory,
    [string] $ObservationPath
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "Agent3Coordination.psm1") -Force
$state = Read-Agent3Json $StatePath
if ($Action -ceq "ProtocolError") {
    $path = Publish-Agent3ProtocolError $InputPath $state $Directory
    Read-Agent3Json $path | ConvertTo-Json -Depth 100 -Compress
    return
}
$observation = Read-Agent3Json $ObservationPath
foreach ($key in @("sender", "recipient", "evidence")) {
    if ($key -cnotin @($observation.Keys)) { throw "Observation missing '$key'." }
}
foreach ($key in $observation.Keys) {
    if ($key -cnotin @("sender", "recipient", "evidence")) { throw "Unknown observation field '$key'." }
}
if ($observation.evidence -isnot [array] -or $observation.evidence.Count -eq 0 -or
    @($observation.evidence | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
    throw "Independently observed evidence references are required."
}
switch -CaseSensitive ($Action) {
    "Prepare" {
        $spec = Read-Agent3Json $InputPath
        $allowed = @("type", "context", "payload", "inReplyTo", "record")
        foreach ($key in $allowed) { if ($key -cnotin @($spec.Keys)) { throw "Specification missing '$key'." } }
        foreach ($key in $spec.Keys) { if ($key -cnotin $allowed) { throw "Unknown specification field '$key'." } }
        $message = New-Agent3Message -Type $spec.type -Sender $observation.sender -Recipient $observation.recipient `
            -Context $spec.context -Payload $spec.payload -InReplyTo $spec.inReplyTo -Record $spec.record -Directory $Directory
        $path = Publish-Agent3Message $message $state $observation.sender $observation.recipient $Directory
        [IO.File]::ReadAllText($path)
    }
    "Receive" {
        if (-not [IO.Path]::IsPathFullyQualified($InputPath)) { throw "Input path must be absolute." }
        Receive-Agent3Message ([IO.File]::ReadAllText($InputPath)) $state $observation.sender $observation.recipient `
            $Directory $observation.evidence | ConvertTo-Json -Depth 100 -Compress
    }
    "Confirm" {
        Confirm-Agent3Message (Read-Agent3Json $InputPath) $state $observation.sender $observation.recipient `
            $Directory $observation.evidence
    }
}
