$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "..\tools\New-LogoDevConfiguration.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-logo-test-" + [guid]::NewGuid())
$output = Join-Path $directory "LogoDevPublishableKey.txt"
$savedKey = $env:LOGO_DEV_PUBLISHABLE_KEY
try {
    $env:LOGO_DEV_PUBLISHABLE_KEY = $null
    & $script -OutputPath $output
    if ([IO.File]::ReadAllText($output) -ne "") { throw "Keyless configuration must be empty." }

    $env:LOGO_DEV_PUBLISHABLE_KEY = "pk_test_not_a_real_key"
    $logged = & $script -OutputPath $output *>&1 | Out-String
    if ($logged -match "pk_test") { throw "Configuration generation must not log the key." }
    if ([IO.File]::ReadAllText($output) -cne $env:LOGO_DEV_PUBLISHABLE_KEY) {
        throw "Configured build resource must contain the publishable key."
    }

    $env:LOGO_DEV_PUBLISHABLE_KEY = $null
    & $script -OutputPath $output
    if ([IO.File]::ReadAllText($output) -ne "") { throw "A keyless rebuild must erase the previous key." }

    foreach ($invalid in @("sk_test_not_a_real_key", "pk_", "pk_test`"invalid", "pk_test`ninvalid", "PK_test")) {
        $env:LOGO_DEV_PUBLISHABLE_KEY = $invalid
        $rejected = $false
        try { & $script -OutputPath $output }
        catch {
            $rejected = $true
            if ($_.Exception.Message.Contains($invalid)) { throw "Validation errors must not reveal credentials." }
        }
        if (-not $rejected) { throw "Invalid or secret keys must be rejected." }
    }
    Write-Output "Logo.dev build configuration tests passed."
}
finally {
    $env:LOGO_DEV_PUBLISHABLE_KEY = $savedKey
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
}
