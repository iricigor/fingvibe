param(
    [string] $AppDirectory,
    [string] $BuildTimestamp
)

$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "..\src\FingVibe.App\FingVibe.App.csproj"
$format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
$culture = [Globalization.CultureInfo]::InvariantCulture
$styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal

foreach ($kind in @("Development", "Test", "PullRequest", "Release")) {
    $before = [DateTimeOffset]::UtcNow.AddSeconds(-1)
    $output = & dotnet msbuild $project -nologo "-p:BuildKind=$kind" -getProperty:BuildTimestamp -getItem:AssemblyMetadata
    if ($LASTEXITCODE -ne 0) { throw "Could not evaluate $kind build timestamp metadata." }
    $metadata = ($output -join "`n") | ConvertFrom-Json
    $timestamp = [DateTimeOffset]::ParseExact($metadata.Properties.BuildTimestamp, $format, $culture, $styles)
    if ($timestamp -lt $before -or $timestamp -gt [DateTimeOffset]::UtcNow) {
        throw "$kind timestamp does not represent the actual UTC build time."
    }
    $stamp = @($metadata.Items.AssemblyMetadata | Where-Object Identity -eq "BuildTimestamp")
    if ($stamp.Count -ne 1 -or $stamp[0].Value -cne $metadata.Properties.BuildTimestamp) {
        throw "$kind does not embed its timestamp as assembly metadata."
    }
}

$override = "2026-11-01T12:20:35.1234567Z"
$output = & dotnet msbuild $project -nologo "-p:BuildTimestamp=$override" -getProperty:BuildTimestamp -getItem:AssemblyMetadata
if ($LASTEXITCODE -ne 0) { throw "Could not evaluate explicit build timestamp override." }
$metadata = ($output -join "`n") | ConvertFrom-Json
$stamp = @($metadata.Items.AssemblyMetadata | Where-Object Identity -eq "BuildTimestamp")
if ($metadata.Properties.BuildTimestamp -cne $override -or $stamp.Count -ne 1 -or $stamp[0].Value -cne $override) {
    throw "The explicit timestamp override was not preserved verbatim."
}

if ($AppDirectory) {
    if (-not $BuildTimestamp) { throw "Published assembly checks require the expected BuildTimestamp." }
    $assemblyPath = (Resolve-Path (Join-Path $AppDirectory "FingVibe.App.dll")).Path
    $assembly = [Reflection.Assembly]::LoadFrom($assemblyPath)
    $attributes = @($assembly.GetCustomAttributesData() | Where-Object {
        $_.AttributeType.FullName -eq "System.Reflection.AssemblyMetadataAttribute" -and
        $_.ConstructorArguments[0].Value -eq "BuildTimestamp"
    })
    if ($attributes.Count -ne 1 -or $attributes[0].ConstructorArguments[1].Value -cne $BuildTimestamp) {
        throw "Published assembly does not contain the expected build timestamp."
    }
}

Write-Host "UTC metadata stamping, all build kinds, explicit override, and requested artifact checks passed."
