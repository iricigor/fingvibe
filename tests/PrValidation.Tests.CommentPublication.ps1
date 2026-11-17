# PR comment publisher: append, upsert and remove modes.
$publisher = Join-Path $PSScriptRoot "..\.github\scripts\Publish-PrComment.ps1"
$savedExitCode = $global:LASTEXITCODE
$global:PrValidationGhState = @{
    Calls = [System.Collections.Generic.List[string]]::new()
    CommandFails = $false
    Existing = $false
}
function gh {
    $global:PrValidationGhState.Calls.Add(($args -join " "))
    $global:LASTEXITCODE = if ($global:PrValidationGhState.CommandFails) { 1 } else { 0 }
    if ($args -contains "--paginate") {
        if ($global:PrValidationGhState.Existing) {
            '[[{"id":99,"user":{"login":"other"},"body":"<!-- marker -->"}],[{"id":123,"user":{"login":"github-actions[bot]"},"body":"<!-- marker --> old"}]]'
        } else { '[[]]' }
    }
}
try {
    $parameters = @{ PullRequestNumber = 62; Repository = "test/repo"; Marker = "<!-- marker -->"; Body = "<!-- marker --> new" }
    & $publisher @parameters -Mode Append
    & $publisher @parameters -Mode Append
    Assert-Equal $global:PrValidationGhState.Calls.Count 2 "One new comment per successful build run"
    foreach ($call in $global:PrValidationGhState.Calls) {
        if ($call -notlike "pr comment 62 *" -or $call -match "PATCH|DELETE|--paginate") {
            throw "Append mode must not search for, edit, or remove earlier comments."
        }
    }
    $global:PrValidationGhState.Calls.Clear()
    $global:PrValidationGhState.Existing = $true
    & $publisher @parameters
    Assert-Equal $global:PrValidationGhState.Calls.Count 2 "Upsert queries then updates"
    if ($global:PrValidationGhState.Calls[1] -notlike "*PATCH repos/test/repo/issues/comments/123*") { throw "Update only the bot's matching comment across all pages." }
    $global:PrValidationGhState.Calls.Clear()
    & $publisher @parameters -Mode Remove
    if ($global:PrValidationGhState.Calls[1] -notlike "*DELETE repos/test/repo/issues/comments/123*") { throw "Remove only the matching bot comment." }
    $global:PrValidationGhState.Existing = $false
    $global:PrValidationGhState.Calls.Clear()
    & $publisher @parameters
    if ($global:PrValidationGhState.Calls[1] -notlike "pr comment 62 *") { throw "Missing marker must create a comment." }
    $global:PrValidationGhState.CommandFails = $true
    Assert-Throws { & $publisher @parameters -Mode Append } "*Could not append*"
    Assert-Throws { & $publisher @parameters } "*Could not list*"
    $global:PrValidationGhState.CommandFails = $false
    Assert-Throws { & $publisher -PullRequestNumber 62 -Repository "test/repo" -Marker "missing" -Body "invalid" } "*must include its marker*"
} finally {
    Remove-Item Function:\gh
    Remove-Variable PrValidationGhState -Scope Global
    $global:LASTEXITCODE = $savedExitCode
}
