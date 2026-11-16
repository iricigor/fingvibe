# The accessibility scenario needs the .NET Framework WinRT projection.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA `
    -File (Join-Path $PSScriptRoot '..\NetworkTroubleshooting.Ui.Tests.ps1') -AppPath $AppPath `
    -ScreenshotDirectory (Join-Path $ScreenshotDirectory 'troubleshooting')
if ($LASTEXITCODE -ne 0) {
    throw "Network troubleshooting native UI check failed in Windows PowerShell (exit code $LASTEXITCODE)."
}
