[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ScreenshotPath,

    [Parameter(Mandatory)]
    [int] $PullRequestNumber,

    [Parameter(Mandatory)]
    [ValidatePattern("^[^/]+/[^/]+$")]
    [string] $Repository,

    [Parameter(Mandatory)]
    [long] $RunId
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    & git -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $ScreenshotPath -PathType Leaf)) {
    throw "The UI review screenshot was not found at '$ScreenshotPath'."
}
if (-not $env:GH_TOKEN) {
    throw "GH_TOKEN is required to publish the UI review screenshot."
}
if (-not $env:GITHUB_OUTPUT) {
    throw "GITHUB_OUTPUT is required to expose the published screenshot URL."
}

gh auth setup-git
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI could not configure Git authentication."
}

$owner, $repositoryName = $Repository.Split("/", 2)
$repositoryUrl = "https://github.com/$Repository.git"
$publishDirectory = Join-Path $env:RUNNER_TEMP "fingvibe-ui-review-pages"
$remoteBranchExists = $false

& git ls-remote --exit-code --heads $repositoryUrl gh-pages *> $null
if ($LASTEXITCODE -eq 0) {
    $remoteBranchExists = $true
}
elseif ($LASTEXITCODE -ne 2) {
    throw "Could not inspect the remote gh-pages branch."
}

if ($remoteBranchExists) {
    & git clone --branch gh-pages --single-branch $repositoryUrl $publishDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Could not clone the gh-pages branch."
    }
}
else {
    New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
    Invoke-Git -WorkingDirectory $publishDirectory -Arguments @("init")
    Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
        "remote",
        "add",
        "origin",
        $repositoryUrl
    )
    Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
        "checkout",
        "--orphan",
        "gh-pages"
    )
}

Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
    "config",
    "user.name",
    "github-actions[bot]"
)
Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
    "config",
    "user.email",
    "41898282+github-actions[bot]@users.noreply.github.com"
)

$null = New-Item -ItemType File `
    -Path (Join-Path $publishDirectory ".nojekyll") `
    -Force
$destinationDirectory = Join-Path $publishDirectory "ui-review\pr-$PullRequestNumber"
New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
Copy-Item `
    -LiteralPath $ScreenshotPath `
    -Destination (Join-Path $destinationDirectory "fingvibe-ui-review.png") `
    -Force

Invoke-Git -WorkingDirectory $publishDirectory -Arguments @("add", ".")
& git -C $publishDirectory diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
        "commit",
        "-m",
        "Update UI review screenshot for PR $PullRequestNumber"
    )

    $pushed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & git -C $publishDirectory push origin HEAD:gh-pages
        if ($LASTEXITCODE -eq 0) {
            $pushed = $true
            break
        }

        Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
            "fetch",
            "origin",
            "gh-pages"
        )
        Invoke-Git -WorkingDirectory $publishDirectory -Arguments @(
            "rebase",
            "origin/gh-pages"
        )
    }

    if (-not $pushed) {
        throw "Could not push the UI review screenshot after three attempts."
    }
}

$imageUrl =
    "https://$owner.github.io/$repositoryName/ui-review/pr-$PullRequestNumber/fingvibe-ui-review.png?run=$RunId"
"url=$imageUrl" >> $env:GITHUB_OUTPUT

Write-Host "Published UI review screenshot to '$imageUrl'."
