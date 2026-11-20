$PrRegressionAllowedManifestProperties = @(
    "schema", "issue", "category", "changedBehavior", "selectors", "expectedAssertions"
)
$PrRegressionAllowedCategories = @("documentation", "core", "ui", "validation")
$PrRegressionAllowedRunners = @(
    "dotnet", "node", "python", "powershell", "native-matrix", "native-suite"
)

function Invoke-PrRegressionGit {
    param([string] $RepositoryPath, [string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    return $output
}

function Read-PrRegressionJson {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Regression JSON file '$Path' does not exist."
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Regression JSON file '$Path' is malformed: $($_.Exception.Message)"
    }
}

function Get-PrRegressionChangedPaths {
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [Parameter(Mandatory)][string] $BaseRevision,
        [Parameter(Mandatory)][string] $HeadRevision
    )
    $mergeBase = Invoke-PrRegressionGit $RepositoryPath @("merge-base", $BaseRevision, $HeadRevision)
    @(Invoke-PrRegressionGit $RepositoryPath @(
        "diff", "--name-only", "--no-renames", $mergeBase, $HeadRevision, "--"
    ))
}

function Get-PrRegressionCategory {
    param([Parameter(Mandatory)][string[]] $Paths)

    $signals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $known = @()
    $sawTests = $false
    foreach ($path in $Paths) {
        $relative = $path.Replace('\', '/')
        if ($relative -match '^\.github/pr-regression-manifests/[^/]+\.json$') {
            $known += $path
            continue
        }
        if ($relative -match '^docs/' -or $relative -cmatch '^(README|CONTRIBUTING|CHANGELOG)(\.md)?$' -or
            ($relative -match '\.md$' -and $relative -notmatch '^\.github/')) {
            $known += $path
            [void] $signals.Add("documentation")
            continue
        }
        if ($relative -match '^tests/') {
            $known += $path
            $sawTests = $true
            continue
        }
        if ($relative -match '^\.github/' -or $relative -match '^tools/' -or
            $relative -cmatch '^(FingVibe\.slnx?|global\.json|Directory\.[^/]+|mkdocs\.yml)$' -or
            $relative -cmatch 'NuGet\.Config$') {
            $known += $path
            [void] $signals.Add("validation")
            continue
        }
        if ($relative -match '^src/FingVibe\.App/') {
            $known += $path
            [void] $signals.Add("ui")
            continue
        }
        if ($relative -match '^src/FingVibe\.Core/') {
            $known += $path
            [void] $signals.Add("core")
            continue
        }
    }
    $unknown = @($Paths | Where-Object { $_ -notin $known })
    if ($unknown.Count -gt 0) {
        throw "Unknown changed paths cannot be classified for regression coverage: $($unknown -join ', ')."
    }
    if ($signals.Contains("validation")) { return "validation" }
    if ($signals.Contains("ui")) { return "ui" }
    if ($signals.Contains("core")) { return "core" }
    if ($signals.Contains("documentation")) { return "documentation" }
    if ($sawTests) { return "validation" }
    throw "The changed path set has no classifiable behavior."
}

function Get-PrRegressionMinimumSelectors {
    param([Parameter(Mandatory)][ValidateSet("documentation", "core", "ui", "validation")][string] $Category)
    switch ($Category) {
        "documentation" { @("documentation-tests", "documentation-publish") }
        "core" { @("core-tests") }
        "ui" { @("core-tests", "ui-regression-helpers", "native-pr-matrix") }
        "validation" { @("pr-validation", "native-validation", "ui-review-scenarios") }
    }
}

function Test-PrRegressionNativeImpact {
    param([Parameter(Mandatory)][string[]] $Paths)
    foreach ($path in $Paths) {
        $relative = $path.Replace('\', '/')
        if ($relative -match '^(src/|tools/|\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md))' -or
            $relative -cmatch '(^|/)([^/]+\.(slnx?|props|targets)|global\.json|NuGet\.Config)$' -or
            $relative -match '^tests/(UiRegression/|[^/]+\.Ui\.(Tests|Helpers)(\.[A-Za-z]+)?\.ps1$|[^/]+\.Fixture\.ps1$|(SidebarNavigation|UiReviewScreenshot(\.Content)?|Installer\.Lifecycle)\.Tests\.ps1$|Inventory\.Sqlite\.Helpers\.ps1$)') {
            return $true
        }
    }
    return $false
}

function Get-PrRegressionSelectorCatalog {
    param([Parameter(Mandatory)][string] $Path)
    $catalog = Read-PrRegressionJson $Path
    if ($catalog.schema -ne "fingvibe-pr-regression-selectors-v1") {
        throw "Unsupported regression selector catalog schema '$($catalog.schema)'."
    }
    $selectors = @($catalog.selectors)
    if ($selectors.Count -eq 0) { throw "Regression selector catalog has no selectors." }
    $ids = @($selectors | ForEach-Object { $_.id })
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
        throw "Regression selector catalog contains duplicate IDs."
    }
    foreach ($selector in $selectors) {
        $properties = @($selector.PSObject.Properties.Name | Sort-Object)
        if (($properties -join "|") -ne "id|runner|target") {
            throw "Regression selector '$($selector.id)' has unsupported fields."
        }
        if ([string]::IsNullOrWhiteSpace($selector.id) -or
            $selector.runner -notin $PrRegressionAllowedRunners -or
            [string]::IsNullOrWhiteSpace($selector.target)) {
            throw "Regression selector '$($selector.id)' is incomplete or has an unsupported runner."
        }
    }
    return $selectors
}

function Test-PrRegressionSelector {
    param(
        [Parameter(Mandatory)] $Selector,
        [Parameter(Mandatory)][string] $RepositoryPath
    )
    if ($Selector.runner -eq "native-suite") {
        $workflow = Get-Content -LiteralPath (Join-Path $RepositoryPath ".github\workflows\ci.yml") -Raw
        if ($workflow -notmatch "(?m)^\s+suite: \[[^\r\n]*\b$([regex]::Escape($Selector.target))\b[^\r\n]*\]") {
            throw "Native selector '$($Selector.id)' matched zero matrix suites."
        }
        return 1
    }
    $target = Join-Path $RepositoryPath $Selector.target
    $fullTarget = [IO.Path]::GetFullPath($target)
    $fullRoot = [IO.Path]::GetFullPath($RepositoryPath)
    if (-not $fullTarget.StartsWith($fullRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Regression selector '$($Selector.id)' resolves outside the repository."
    }
    if (-not (Test-Path -LiteralPath $fullTarget -PathType Leaf)) {
        throw "Regression selector '$($Selector.id)' matched zero files."
    }
    if ($Selector.runner -eq "native-matrix") {
        $workflow = Get-Content -LiteralPath $fullTarget -Raw
        if ($workflow -notmatch '(?m)^\s+suite: \[[^\r\n]*details-summary[^\r\n]*tools-device-data[^\r\n]*\]') {
            throw "Regression selector 'native-pr-matrix' matched no complete native matrix."
        }
    }
    return 1
}

function Assert-PrRegressionNativeDispatch {
    param(
        [Parameter(Mandatory)] $Selector,
        [Parameter(Mandatory)][string[]] $Scenarios
    )
    $requiredScenarios = switch -Wildcard ($Selector.target) {
        "details-summary" { @("DeviceDetails", "DeviceHistory", "PersonDetails") }
        "details-*" { @("DeviceDetails", "DeviceHistory") }
        "network-activity" { @("Network") }
        default { @() }
    }
    if ($requiredScenarios.Count -gt 0 -and
        @($Scenarios | Where-Object { $_ -in $requiredScenarios }).Count -eq 0) {
        throw "Native selector '$($Selector.id)' matched zero dispatchable checks for the PR capture plan."
    }
}

function Get-PrRegressionPlan {
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [Parameter(Mandatory)][string] $PullRequestBody,
        [Parameter(Mandatory)][string[]] $ChangedPaths,
        [string] $BaseRevision,
        [string] $HeadRevision = "HEAD",
        [string] $CatalogPath = (Join-Path $RepositoryPath ".github\pr-regression\selectors.json")
    )

    $markers = @([regex]::Matches(
        $PullRequestBody,
        '<!--\s*regression-manifest:\s*(?<path>[^<>\s]+)\s*-->'
    ))
    if ($markers.Count -ne 1) {
        throw "The PR body must contain exactly one regression-manifest reference."
    }
    $manifestRelativePath = $markers[0].Groups["path"].Value.Replace('/', '\')
    if ($manifestRelativePath -notmatch '^\.github\\pr-regression-manifests\\(?<issue>\d+)\.json$') {
        throw "Regression manifest reference '$manifestRelativePath' is outside the supported location."
    }
    $referenceIssue = [int] $Matches.issue
    $closingReferences = @([regex]::Matches(
        $PullRequestBody, '(?im)\b(?:Closes|Fixes|Resolves)\s+#(?<issue>\d+)\b'
    ) | ForEach-Object { [int] $_.Groups["issue"].Value })
    if ($referenceIssue -notin $closingReferences) {
        throw "Regression manifest issue #$referenceIssue must match a closing reference in the PR body."
    }
    $normalizedPaths = @($ChangedPaths | ForEach-Object { $_.Replace('/', '\') })
    if ($manifestRelativePath -notin $normalizedPaths) {
        throw "Regression manifest '$manifestRelativePath' is not committed in the current PR diff."
    }

    $manifestPath = Join-Path $RepositoryPath $manifestRelativePath
    $manifest = Read-PrRegressionJson $manifestPath
    $properties = @($manifest.PSObject.Properties.Name | Sort-Object)
    $expectedProperties = @($PrRegressionAllowedManifestProperties | Sort-Object)
    if (($properties -join "|") -ne ($expectedProperties -join "|")) {
        throw "Regression manifest has missing or unsupported fields."
    }
    if ($manifest.schema -ne "fingvibe-pr-regression-v1") {
        throw "Unsupported regression manifest schema '$($manifest.schema)'."
    }
    if ($manifest.issue -isnot [long] -and $manifest.issue -isnot [int]) {
        throw "Regression manifest issue must be an integer."
    }
    if ([int] $manifest.issue -ne $referenceIssue) {
        throw "Regression manifest issue does not match its filename/reference."
    }
    if ($manifest.category -notin $PrRegressionAllowedCategories) {
        throw "Regression manifest category '$($manifest.category)' is unsupported."
    }
    if ([string]::IsNullOrWhiteSpace($manifest.changedBehavior)) {
        throw "Regression manifest changedBehavior must be nonempty."
    }
    foreach ($field in @("selectors", "expectedAssertions")) {
        $values = @($manifest.$field)
        if ($values.Count -eq 0 -or @($values | Where-Object {
            $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
        }).Count -gt 0) {
            throw "Regression manifest $field must contain nonempty strings."
        }
        if (@($values | Select-Object -Unique).Count -ne $values.Count) {
            throw "Regression manifest $field contains duplicates."
        }
    }

    $category = Get-PrRegressionCategory -Paths $normalizedPaths
    if ($manifest.category -ne $category) {
        throw "Regression manifest category '$($manifest.category)' is inconsistent with changed paths; expected '$category'."
    }
    $catalog = Get-PrRegressionSelectorCatalog -Path $CatalogPath
    $catalogById = @{}
    foreach ($selector in $catalog) { $catalogById[$selector.id] = $selector }
    $unknownSelectors = @($manifest.selectors | Where-Object { -not $catalogById.ContainsKey($_) })
    if ($unknownSelectors.Count -gt 0) {
        throw "Regression manifest selects unsupported or nonexistent selectors: $($unknownSelectors -join ', ')."
    }

    $minimum = @(Get-PrRegressionMinimumSelectors -Category $category)
    $nativeImpact = Test-PrRegressionNativeImpact -Paths $normalizedPaths
    if ($nativeImpact) { $minimum += "native-pr-matrix" }
    $selected = @($minimum + @($manifest.selectors) | Select-Object -Unique)
    if (-not $nativeImpact -and @($selected | Where-Object {
        $catalogById[$_].runner -in @("native-matrix", "native-suite")
    }).Count -gt 0) {
        throw "Native regression selectors require a changed path that triggers the existing native matrix."
    }
    if ($BaseRevision) {
        $manifestNative = @($manifest.selectors | Where-Object {
            $catalogById[$_].runner -eq "native-suite"
        })
        if ($manifestNative.Count -gt 0) {
            . (Join-Path $RepositoryPath ".github\scripts\UiReviewScenarios.ps1")
            $capturePlan = @(Get-UiReviewCapturePlan -RepositoryPath $RepositoryPath `
                -BaseRevision $BaseRevision -HeadRevision $HeadRevision)
            foreach ($id in $manifestNative) {
                Assert-PrRegressionNativeDispatch -Selector $catalogById[$id] `
                    -Scenarios @($capturePlan.Scenario)
            }
        }
    }
    foreach ($id in $selected) {
        [void] (Test-PrRegressionSelector -Selector $catalogById[$id] -RepositoryPath $RepositoryPath)
    }
    $selectedCatalog = @($selected | ForEach-Object { $catalogById[$_] })
    if (@($selectedCatalog | Where-Object { $_.runner -notin @("native-matrix", "native-suite") }).Count -eq 0) {
        throw "Regression selection matched zero executable local behavioral tests."
    }

    $head = if ($BaseRevision -and $HeadRevision) {
        (Invoke-PrRegressionGit $RepositoryPath @("rev-parse", $HeadRevision) | Select-Object -First 1)
    } else { $null }
    [pscustomobject] [ordered]@{
        schema = "fingvibe-pr-regression-plan-v1"
        issue = $referenceIssue
        manifest = $manifestRelativePath.Replace('\', '/')
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        category = $category
        baseRevision = $BaseRevision
        headRevision = $head
        requiredSelectors = @($minimum)
        selectors = @($selectedCatalog | ForEach-Object {
            [pscustomobject]@{ id = $_.id; runner = $_.runner; target = $_.target }
        })
    }
}

function Invoke-PrRegressionPlan {
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][string] $RepositoryPath
    )
    foreach ($selector in @($Plan.selectors)) {
        Write-Host "Running regression selector: $($selector.id)"
        switch ($selector.runner) {
            "dotnet" {
                & dotnet test (Join-Path $RepositoryPath $selector.target) --configuration Release
                if ($LASTEXITCODE -ne 0) { throw "Regression selector '$($selector.id)' failed." }
            }
            "node" {
                & node --test (Join-Path $RepositoryPath $selector.target)
                if ($LASTEXITCODE -ne 0) { throw "Regression selector '$($selector.id)' failed." }
            }
            "python" {
                & python (Join-Path $RepositoryPath $selector.target)
                if ($LASTEXITCODE -ne 0) { throw "Regression selector '$($selector.id)' failed." }
            }
            "powershell" {
                & (Join-Path $RepositoryPath $selector.target)
            }
            "native-matrix" {
                Write-Host "Regression selector '$($selector.id)' is enforced by the unchanged authoritative ui-regression matrix."
            }
            "native-suite" {
                Write-Host "Regression selector '$($selector.id)' is enforced by the existing $($selector.target) matrix job."
            }
            default { throw "Unsupported selected runner '$($selector.runner)'." }
        }
    }
}
