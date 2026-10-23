param(
    [Parameter(Mandatory)]
    [string] $PublishDirectory
)

$ErrorActionPreference = "Stop"

foreach ($fileName in @("FingVibe.App.exe", "FingVibe.App.dll")) {
    $path = Join-Path $PublishDirectory $fileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Published app file is missing: $path"
    }

    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path -LiteralPath $path).Path)
    foreach ($property in @{
        CompanyName = "Igor (iricigor)"
        ProductName = "FingVibe"
        FileDescription = "FingVibe"
    }.GetEnumerator()) {
        if ($info.($property.Key) -cne $property.Value) {
            throw "$fileName $($property.Key): expected '$($property.Value)', got '$($info.($property.Key))'."
        }
    }
}

$publisher = Get-Content -LiteralPath (Join-Path $PublishDirectory "PUBLISHER.txt") -Raw
foreach ($line in @(
    "Author / publisher: Igor (iricigor)",
    "Publisher website: https://igor.iric.online",
    "Project repository: https://github.com/iricigor/fingvibe",
    "indicate digital signing or a verified publisher."
)) {
    if (-not $publisher.Contains($line)) {
        throw "Published PUBLISHER.txt is missing '$line'."
    }
}

Write-Host "Published executable, assembly, and publisher information passed."
