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
Import-Module (Join-Path $PSScriptRoot "RealTaskCoordination.psm1") -Force
$state = Read-RealTaskJson $StatePath
if ($Action -ceq "ProtocolError") {
    $path = Publish-RealTaskProtocolError $InputPath $state $Directory
    Read-RealTaskJson $path | ConvertTo-Json -Depth 100 -Compress
    return
}
$observation = Read-RealTaskJson $ObservationPath
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
        $spec = Read-RealTaskJson $InputPath
        $allowed = @("type", "context", "payload", "inReplyTo", "record")
        foreach ($key in $allowed) { if ($key -cnotin @($spec.Keys)) { throw "Specification missing '$key'." } }
        foreach ($key in $spec.Keys) { if ($key -cnotin $allowed) { throw "Unknown specification field '$key'." } }
        $message = New-RealTaskMessage -Type $spec.type -Sender $observation.sender -Recipient $observation.recipient `
            -Context $spec.context -Payload $spec.payload -InReplyTo $spec.inReplyTo -Record $spec.record -Directory $Directory
        $null = Publish-RealTaskMessage $message $state $observation.sender $observation.recipient $Directory
        $message | ConvertTo-Json -Depth 100 -Compress
    }
    "Receive" {
        if (-not [IO.Path]::IsPathFullyQualified($InputPath)) { throw "Input path must be absolute." }
        Receive-RealTaskMessage ([IO.File]::ReadAllText($InputPath)) $state $observation.sender $observation.recipient `
            $Directory $observation.evidence | ConvertTo-Json -Depth 100 -Compress
    }
    "Confirm" {
        Confirm-RealTaskMessage (Read-RealTaskJson $InputPath) $state $observation.sender $observation.recipient `
            $Directory $observation.evidence
    }
}
