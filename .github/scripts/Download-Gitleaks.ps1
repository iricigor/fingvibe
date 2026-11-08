param(
    [Parameter(Mandatory)]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $ArchiveName,

    [Parameter(Mandatory)]
    [string] $ArchivePath,

    [Parameter(Mandatory)]
    [string] $ChecksumsName,

    [Parameter(Mandatory)]
    [string] $ChecksumsPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw "GH_TOKEN is required to download the Gitleaks release assets."
}

$tag = "v$Version"
foreach ($asset in @(
    @{ Name = $ArchiveName; Path = $ArchivePath },
    @{ Name = $ChecksumsName; Path = $ChecksumsPath }
)) {
    & gh release download $tag `
        --repo "gitleaks/gitleaks" `
        --pattern $asset.Name `
        --output $asset.Path `
        --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "Could not download Gitleaks release asset '$($asset.Name)'."
    }
    if (-not (Test-Path -LiteralPath $asset.Path -PathType Leaf)) {
        throw "Gitleaks download did not create '$($asset.Name)'."
    }
}
