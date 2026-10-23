param(
    [Parameter(Mandatory)]
    [string] $ZipPath
)

$ErrorActionPreference = "Stop"

try {
    $zip = Get-Item -LiteralPath $ZipPath
    if ($zip.PSIsContainer -or $zip.Name -notlike "FingVibe-*-win-x64.zip") {
        throw "Select a FingVibe release ZIP named FingVibe-<version>-win-x64.zip."
    }

    if (Get-Process | Where-Object ProcessName -eq "FingVibe.App") {
        throw "Close FingVibe before updating."
    }

    $destination = Join-Path $env:LOCALAPPDATA "Programs\FingVibe"
    Unblock-File -LiteralPath $zip.FullName
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $destination -Force

    $appPath = Join-Path $destination "FingVibe.App.exe"
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        throw "The extracted archive does not contain FingVibe.App.exe."
    }

    Start-Process -FilePath $appPath -WorkingDirectory $destination
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Read-Host "Press Enter to close" | Out-Null
    exit 1
}
