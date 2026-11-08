$ErrorActionPreference = "Stop"

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$root = Join-Path $PSScriptRoot ".."
$helper = Join-Path $root ".github\scripts\Download-Gitleaks.ps1"
$workflow = Get-Content (Join-Path $root ".github\workflows\security-review.yml") -Raw

if ($workflow -notmatch '(?s)permissions:\s+contents: read') {
    throw "Security review must retain read-only contents permission."
}
if ($workflow -notmatch '(?s)name: Test Gitleaks download helper\s+shell: pwsh\s+run: \.\\tests\\GitleaksDownload\.Tests\.ps1') {
    throw "Security review must run the Gitleaks download regression tests."
}
if ($workflow -notmatch '(?s)name: Scan for exposed secrets\s+id: secrets\s+env:\s+GH_TOKEN: \$\{\{ github\.token \}\}\s+shell: pwsh\s+run: .*?Download-Gitleaks\.ps1') {
    throw "Only the secret-scan step must receive the Actions job token and use the download helper."
}
$archiveCheck = $workflow.IndexOf('Get-FileHash $archivePath -Algorithm SHA256')
$extract = $workflow.IndexOf('Expand-Archive -LiteralPath $archivePath')
$scan = $workflow.IndexOf('& "$toolDirectory\gitleaks.exe" git . --redact --no-banner')
if ($archiveCheck -lt 0 -or $extract -le $archiveCheck -or $scan -le $extract) {
    throw "The checksum verification must remain before extraction and scanning."
}
if ($workflow -notmatch '(?s)Fail on critical dependency vulnerabilities.*?throw "Dependency vulnerability analysis failed\."') {
    throw "The blocking critical dependency analysis must remain in the security workflow."
}

$savedToken = $env:GH_TOKEN
$hadToken = Test-Path Env:\GH_TOKEN
$savedExitCode = $global:LASTEXITCODE
$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) "gitleaks-download-tests-$([Guid]::NewGuid())"
$global:GitleaksDownloadTestState = @{
    Calls = [System.Collections.Generic.List[object]]::new()
    FailName = $null
    OmitName = $null
}

function gh {
    $call = @($args)
    $global:GitleaksDownloadTestState.Calls.Add($call)
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $global:LASTEXITCODE = 2
        return
    }
    $patternIndex = [Array]::IndexOf($call, "--pattern")
    $outputIndex = [Array]::IndexOf($call, "--output")
    if ($patternIndex -lt 0 -or $outputIndex -lt 0) {
        $global:LASTEXITCODE = 2
        return
    }
    $name = $call[$patternIndex + 1]
    if ($name -eq $global:GitleaksDownloadTestState.FailName) {
        $global:LASTEXITCODE = 1
        return
    }
    if ($name -ne $global:GitleaksDownloadTestState.OmitName) {
        [IO.File]::WriteAllText($call[$outputIndex + 1], "test asset")
    }
    $global:LASTEXITCODE = 0
}

try {
    $null = New-Item -ItemType Directory -Path $tempDirectory
    $archiveName = "gitleaks_8.30.1_windows_x64.zip"
    $checksumsName = "gitleaks_8.30.1_checksums.txt"
    $archivePath = Join-Path $tempDirectory $archiveName
    $checksumsPath = Join-Path $tempDirectory $checksumsName
    $parameters = @{
        Version = "8.30.1"
        ArchiveName = $archiveName
        ArchivePath = $archivePath
        ChecksumsName = $checksumsName
        ChecksumsPath = $checksumsPath
    }

    $env:GH_TOKEN = "test-token"
    & $helper @parameters
    Assert-Equal $global:GitleaksDownloadTestState.Calls.Count 2 "Download both release assets"
    foreach ($call in $global:GitleaksDownloadTestState.Calls) {
        Assert-Equal $call[0] "release" "Use GitHub CLI release downloads"
        Assert-Equal $call[1] "download" "Use GitHub CLI release downloads"
        Assert-Equal $call[2] "v8.30.1" "Pin the release tag"
        if (($call -join " ") -notmatch '--repo gitleaks/gitleaks') {
            throw "Release downloads must target the Gitleaks repository."
        }
    }
    Assert-Equal $global:GitleaksDownloadTestState.Calls[0][6] $archiveName "Download the pinned archive"
    Assert-Equal $global:GitleaksDownloadTestState.Calls[1][6] $checksumsName "Download the checksum manifest"

    $global:GitleaksDownloadTestState.Calls.Clear()
    Remove-Item Env:\GH_TOKEN
    Assert-Throws { & $helper @parameters } "*GH_TOKEN is required*"
    Assert-Equal $global:GitleaksDownloadTestState.Calls.Count 0 "Missing token must fail before invoking gh"

    $env:GH_TOKEN = "test-token"
    $global:GitleaksDownloadTestState.Calls.Clear()
    $global:GitleaksDownloadTestState.FailName = $archiveName
    Assert-Throws { & $helper @parameters } "*Could not download Gitleaks release asset '$archiveName'*"
    Assert-Equal $global:GitleaksDownloadTestState.Calls.Count 1 "Download failure must stop immediately"

    $global:GitleaksDownloadTestState.Calls.Clear()
    $global:GitleaksDownloadTestState.FailName = $checksumsName
    Assert-Throws { & $helper @parameters } "*Could not download Gitleaks release asset '$checksumsName'*"
    Assert-Equal $global:GitleaksDownloadTestState.Calls.Count 2 "Checksum download failure must stop immediately"

    $global:GitleaksDownloadTestState.Calls.Clear()
    $global:GitleaksDownloadTestState.FailName = $null
    $global:GitleaksDownloadTestState.OmitName = $archiveName
    Remove-Item -LiteralPath $archivePath
    Assert-Throws { & $helper @parameters } "*did not create '$archiveName'*"
    Assert-Equal $global:GitleaksDownloadTestState.Calls.Count 1 "Missing downloaded file must stop immediately"

    "Gitleaks download helper and workflow contracts passed."
} finally {
    Remove-Item Function:\gh -ErrorAction SilentlyContinue
    Remove-Variable GitleaksDownloadTestState -Scope Global -ErrorAction SilentlyContinue
    if ($hadToken) { $env:GH_TOKEN = $savedToken } else { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
    $global:LASTEXITCODE = $savedExitCode
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
