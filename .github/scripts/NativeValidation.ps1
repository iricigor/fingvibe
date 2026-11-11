. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")

function Get-NativeValidationPlan {
    param(
        [Parameter(Mandatory)][ValidateSet("Baseline", "Focused", "Full")][string] $Mode,
        [Parameter(Mandatory)][ValidateSet("capture", "sidebar", "sidebar-presentation", "sidebar-scan-flows", "sidebar-scan-presentation", "sidebar-preferences-scheduling", "devices", "details-summary", "details-identity", "details-observations", "details-activity", "tools", "tools-utilities", "tools-device-data")][string] $Suite,
        [string[]] $Scenarios = @()
    )
    if ($Mode -eq "Baseline" -and $Suite -ne "capture") {
        throw "Baseline runs only the capture suite."
    }
    if ($Mode -ne "Focused" -and $Scenarios.Count -gt 0) {
        throw "Explicit scenarios are supported only in Focused mode."
    }
    if ($Mode -eq "Focused" -and $Suite -eq "capture" -and $Scenarios.Count -eq 0) {
        throw "Focused capture requires at least one explicit scenario."
    }
    if ($Suite -ne "capture" -and $Scenarios.Count -gt 0) {
        throw "Explicit capture scenarios cannot select native regression suites."
    }
    $selected = switch ($Mode) {
        Baseline { @("Devices", "DevicesEmpty", "DeviceDetails") }
        Full { @($UiReviewScenarios.Keys) }
        Focused {
            if ($Suite -eq "capture") { @($Scenarios) }
            elseif ($Suite -eq "details-identity") { @("DeviceDetails", "Network") }
            elseif ($Suite -eq "details-summary") { @("DeviceDetails", "PersonDetails") }
            elseif ($Suite -like "details-*") { @("DeviceDetails") }
            else { @("Devices") }
        }
    }
    @(Get-UiReviewCapturePlan -RepositoryPath $PSScriptRoot -AdditionalScenarios $selected)
}

function Assert-NativeValidationResults {
    param(
        [Parameter(Mandatory)][ValidateSet("Baseline", "Full")][string] $Mode,
        [Parameter(Mandatory)][hashtable] $Results
    )
    $required = if ($Mode -eq "Full") { @("build", "checks", "installer", "native") }
        else { @("build", "native") }
    foreach ($name in $required) {
        if ($Results[$name] -ne "success") {
            throw "Independent $Mode validation did not pass: $name result '$($Results[$name])'."
        }
    }
    if ($Mode -eq "Baseline") {
        foreach ($name in @("checks", "installer")) {
            if ($Results[$name] -ne "skipped") {
                throw "Baseline must explicitly omit $name, not report '$($Results[$name])'."
            }
        }
    }
}
