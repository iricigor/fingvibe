[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LogDirectory,
    [string] $SourceDirectory
)

$ErrorActionPreference = "Stop"
if (-not $SourceDirectory) { $SourceDirectory = Join-Path $PSScriptRoot "..\.." }
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
$null = New-Item -ItemType Directory -Path $LogDirectory -Force
$results = [System.Collections.Generic.List[object]]::new()
function Invoke-FullCheck([string] $Name, [scriptblock] $Action) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = "failure"
    Start-Transcript -Path (Join-Path $LogDirectory "$Name.log")
    Push-Location $SourceDirectory
    try {
        & $Action
        $result = "success"
    }
    catch {
        Write-Host $_
        Write-Host $_.ScriptStackTrace
    }
    finally {
        $clock.Stop()
        $results.Add([pscustomobject]@{ name = $Name; result = $result; seconds = $clock.Elapsed.TotalSeconds })
        $results | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $LogDirectory "checks.json") -Encoding UTF8
        $timing = "$Name : $result, $($clock.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) seconds"
        Write-Host $timing
        if ($env:GITHUB_STEP_SUMMARY) { $timing >> $env:GITHUB_STEP_SUMMARY }
        try { Stop-Transcript }
        finally { Pop-Location }
    }
}

Invoke-FullCheck "core" {
    dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --configuration Release
    if ($LASTEXITCODE -ne 0) { throw "Core tests failed." }
}
Invoke-FullCheck "speed-test" {
    node --test tests\SpeedTestHost.Tests.cjs
    if ($LASTEXITCODE -ne 0) { throw "Speed-test bridge tests failed." }
}
foreach ($name in @(
    "UiReviewScenarios", "UiRegression.Helpers", "AdditionalServices.Script", "SqlEditor.Script",
    "UsageCategory.Script", "DeviceActivity.Script", "NetworkActivity.Script", "EquipmentActivity.Script", "PrValidation", "DispatcherGate",
    "LogoDevConfiguration", "BuildIdentity.Metadata", "Installer.Script", "GitleaksDownload"
)) {
    Invoke-FullCheck $name {
        & (Join-Path $SourceDirectory "tests\$name.Tests.ps1")
    }
}
Invoke-FullCheck "secrets" {
    $version = "8.30.1"
    $archiveName = "gitleaks_${version}_windows_x64.zip"
    $checksumsName = "gitleaks_${version}_checksums.txt"
    $archivePath = Join-Path $LogDirectory $archiveName
    $checksumsPath = Join-Path $LogDirectory $checksumsName
    & (Join-Path $SourceDirectory ".github\scripts\Download-Gitleaks.ps1") -Version $version `
        -ArchiveName $archiveName -ArchivePath $archivePath `
        -ChecksumsName $checksumsName -ChecksumsPath $checksumsPath
    $line = Get-Content -LiteralPath $checksumsPath |
        Where-Object { $_ -match "\s$([Regex]::Escape($archiveName))$" } | Select-Object -First 1
    if (-not $line) { throw "Gitleaks release checksum is missing." }
    if ((Get-FileHash $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne ($line -split "\s+")[0].ToLowerInvariant()) {
        throw "Gitleaks archive failed SHA-256 verification."
    }
    $toolDirectory = Join-Path $LogDirectory "gitleaks"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $toolDirectory -Force
    & (Join-Path $toolDirectory "gitleaks.exe") git . --redact --no-banner
    if ($LASTEXITCODE -ne 0) { throw "Secret scanning failed or detected an exposed secret." }
}
Invoke-FullCheck "dependencies" {
    dotnet restore FingVibe.sln
    if ($LASTEXITCODE -ne 0) { throw "Dependency restore failed." }
    $report = dotnet list FingVibe.sln package --vulnerable --include-transitive --format json
    if ($LASTEXITCODE -ne 0) { throw "Dependency vulnerability analysis failed." }
    $report | Set-Content -LiteralPath (Join-Path $LogDirectory "dependency-vulnerabilities.json")
    $json = $report | ConvertFrom-Json
    $critical = @($json.projects.frameworks.topLevelPackages; $json.projects.frameworks.transitivePackages) |
        Where-Object { $_.vulnerabilities.severity -contains "Critical" }
    if (@($critical).Count -gt 0) {
        $critical | ConvertTo-Json -Depth 10 | Write-Host
        throw "Critical dependency vulnerabilities detected."
    }
}
if (@($results | Where-Object result -ne "success").Count -gt 0) {
    throw "Full non-UI validation failed. See checks.json and the individual transcripts."
}
