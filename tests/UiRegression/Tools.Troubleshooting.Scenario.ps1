# The accessibility scenario needs the .NET Framework WinRT projection.
# Windows PowerShell must drain native stderr before enforcing the exit code.
$troubleshootingErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA `
        -File (Join-Path $PSScriptRoot '..\NetworkTroubleshooting.Ui.Tests.ps1') -AppPath $AppPath `
        -ScreenshotDirectory (Join-Path $ScreenshotDirectory 'troubleshooting') 2>&1 | ForEach-Object { Write-Host $_ }
} finally {
    $ErrorActionPreference = $troubleshootingErrorActionPreference
}
if ($null -eq $global:LASTEXITCODE) {
    throw "Network troubleshooting native UI check did not report a Windows PowerShell exit code."
}
if ($global:LASTEXITCODE -ne 0) {
    throw "Network troubleshooting native UI check failed in Windows PowerShell (exit code $global:LASTEXITCODE)."
}
