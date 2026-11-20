$repositoryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$manifestDirectory = Join-Path $repositoryPath ".github\pr-regression-manifests"
$catalogPath = Join-Path $repositoryPath ".github\pr-regression\selectors.json"
$body = @"
Closes #256

<!-- regression-manifest: .github/pr-regression-manifests/256.json -->
"@
. (Join-Path $repositoryPath ".github\scripts\PrRegressionCoverage.ps1")

$plan = Get-PrRegressionPlan -RepositoryPath $repositoryPath -PullRequestBody $body `
    -ChangedPaths @(
        ".github/pr-regression-manifests/256.json",
        ".github/scripts/PrRegressionCoverage.ps1",
        "tests/PrValidation.Tests.RegressionCoverage.ps1"
    ) -CatalogPath $catalogPath
Assert-Equal $plan.category "validation" "Validation changes select the validation policy"
Assert-Equal (Get-PrRegressionCategory -Paths @(
    "src/FingVibe.App/Views/DevicesPageView.cs",
    "tests/DevicesList.Ui.Tests.ps1"
)) "ui" "Production UI paths determine category even when tests accompany them"
foreach ($selector in @("pr-validation", "native-validation", "ui-review-scenarios", "native-pr-matrix")) {
    Assert-Equal ($plan.selectors.id -contains $selector) $true "CI-owned selector $selector cannot be removed"
}
Assert-Throws {
    Assert-PrRegressionNativeDispatch `
        -Selector ([pscustomobject]@{ id = "native-details-summary"; target = "details-summary" }) `
        -Scenarios @("Devices", "DevicesEmpty")
} "*matched zero dispatchable checks*"
Assert-PrRegressionNativeDispatch `
    -Selector ([pscustomobject]@{ id = "native-details-summary"; target = "details-summary" }) `
    -Scenarios @("Devices", "DeviceDetails")

Assert-Throws {
    Get-PrRegressionPlan -RepositoryPath $repositoryPath `
        -PullRequestBody "Closes #256" `
        -ChangedPaths @(".github/pr-regression-manifests/256.json", "docs/reference.md") `
        -CatalogPath $catalogPath
} "*exactly one regression-manifest*"

Assert-Throws {
    Get-PrRegressionPlan -RepositoryPath $repositoryPath `
        -PullRequestBody ($body -replace "256\.json", "999.json") `
        -ChangedPaths @(".github/pr-regression-manifests/256.json") `
        -CatalogPath $catalogPath
} "*must match a closing reference*"

Assert-Throws {
    Get-PrRegressionPlan -RepositoryPath $repositoryPath -PullRequestBody $body `
        -ChangedPaths @(".github/pr-regression-manifests/256.json", "unmapped/new-component.bin") `
        -CatalogPath $catalogPath
} "*Unknown changed paths*"

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-pr-regression-$([Guid]::NewGuid())"
try {
    $null = New-Item -ItemType Directory -Path $fixture -Force
    $fixtureManifestDirectory = Join-Path $fixture ".github\pr-regression-manifests"
    $null = New-Item -ItemType Directory -Path $fixtureManifestDirectory -Force
    Copy-Item -LiteralPath (Join-Path $manifestDirectory "256.json") `
        -Destination (Join-Path $fixtureManifestDirectory "256.json")
    Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $fixture "selectors.json")
    foreach ($target in @(
        "tests\PrValidation.Tests.ps1",
        "tests\NativeValidation.Tests.ps1",
        "tests\UiReviewScenarios.Tests.ps1",
        ".github\workflows\ci.yml"
    )) {
        $fullTarget = Join-Path $fixture $target
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $fullTarget) -Force
        Set-Content -LiteralPath $fullTarget -Value "suite: [details-summary, tools-device-data]" -Encoding UTF8
    }
    $cases = @(
        @{ Change = { param($json) $json.category = "documentation" }; Error = "*inconsistent with changed paths*" }
        @{ Change = { param($json) $json.selectors = @("does-not-exist") }; Error = "*unsupported or nonexistent selectors*" }
        @{ Change = { param($json) Add-Member -InputObject $json -NotePropertyName command -NotePropertyValue "Invoke-Thing" }; Error = "*missing or unsupported fields*" }
        @{ Change = { param($json) $json.expectedAssertions = @() }; Error = "*expectedAssertions*" }
    )
    foreach ($case in $cases) {
        $json = Get-Content -LiteralPath (Join-Path $manifestDirectory "256.json") -Raw | ConvertFrom-Json
        & $case.Change $json
        $json | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $fixtureManifestDirectory "256.json") -Encoding UTF8
        Assert-Throws {
            Get-PrRegressionPlan -RepositoryPath $fixture -PullRequestBody $body `
                -ChangedPaths @(".github/pr-regression-manifests/256.json", "tests/fixture.ps1") `
                -CatalogPath (Join-Path $fixture "selectors.json")
        } $case.Error
    }

    Set-Content -LiteralPath (Join-Path $fixtureManifestDirectory "256.json") -Value '{"schema":' -Encoding UTF8
    Assert-Throws {
        Get-PrRegressionPlan -RepositoryPath $fixture -PullRequestBody $body `
            -ChangedPaths @(".github/pr-regression-manifests/256.json", "tests/fixture.ps1") `
            -CatalogPath (Join-Path $fixture "selectors.json")
    } "*is malformed*"

    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    ($catalog.selectors | Where-Object id -eq "pr-validation").target = "tests\missing.Tests.ps1"
    $catalog | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $fixture "selectors.json") -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $manifestDirectory "256.json") `
        -Destination (Join-Path $fixtureManifestDirectory "256.json") -Force
    Assert-Throws {
        Get-PrRegressionPlan -RepositoryPath $fixture -PullRequestBody $body `
            -ChangedPaths @(".github/pr-regression-manifests/256.json", "tests/fixture.ps1") `
            -CatalogPath (Join-Path $fixture "selectors.json")
    } "*matched zero files*"

    Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $fixture "selectors.json") -Force
    Copy-Item -LiteralPath (Join-Path $manifestDirectory "256.json") `
        -Destination (Join-Path $fixtureManifestDirectory "256.json") -Force
    $nativeDocumentation = Get-Content -LiteralPath (Join-Path $fixtureManifestDirectory "256.json") -Raw | ConvertFrom-Json
    $nativeDocumentation.category = "documentation"
    $nativeDocumentation.selectors = @("native-details-summary")
    $nativeDocumentation | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $fixtureManifestDirectory "256.json") -Encoding UTF8
    Assert-Throws {
        Get-PrRegressionPlan -RepositoryPath $fixture -PullRequestBody $body `
            -ChangedPaths @(".github/pr-regression-manifests/256.json", "docs/guide.md") `
            -CatalogPath (Join-Path $fixture "selectors.json")
    } "*Native regression selectors require*"
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

Write-Host "PR regression manifest, classification, selector and zero-match tests passed."
