$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-PrValidationChanges.ps1")

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

. (Join-Path $PSScriptRoot "PrValidation.Tests.Planning.ps1")
. (Join-Path $PSScriptRoot "PrValidation.Tests.CommentPublication.ps1")
. (Join-Path $PSScriptRoot "PrValidation.Tests.WorkflowContracts.ps1")
. (Join-Path $PSScriptRoot "PrValidation.Tests.NativeDispatch.ps1")
. (Join-Path $PSScriptRoot "PrValidation.Tests.FinalGate.ps1")
& (Join-Path $PSScriptRoot "NativeValidation.Tests.ps1")
Write-Host "PR validation planning, comment history, and required-check regression tests passed."
