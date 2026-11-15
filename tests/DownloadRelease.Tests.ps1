$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $root '.github\skills\download-release\scripts\download-release.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) "download-release-tests-$([guid]::NewGuid().ToString('N'))"
$savedExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$environmentNames = @('OS', 'CI', 'GITHUB_ACTIONS', 'CODESPACES', 'SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY')
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$global:DownloadReleaseTestState = @{
    Calls = [Collections.Generic.List[object]]::new()
    Unblocked = [Collections.Generic.List[string]]::new()
    Launched = [Collections.Generic.List[object]]::new()
    Events = [Collections.Generic.List[string]]::new()
    Fail = ''
    Payload = 'inert test text, not an executable'
    Omit = $false
    Extra = $false
    MissingGh = $false
}

function Get-Command {
    param([string] $Name, $ErrorAction)
    if ($Name -ne 'gh') { throw 'Unexpected command lookup in release helper.' }
    if (-not $global:DownloadReleaseTestState.MissingGh) { 'mock gh' }
}
function gh {
    $call = @($args)
    $state = $global:DownloadReleaseTestState
    $state.Calls.Add($call)
    $global:LASTEXITCODE = 0
    $operation = $call[1]
    if ($state.Fail -eq $operation) { $global:LASTEXITCODE = 1; return }
    switch ($operation) {
        'status' { return }
        'view' { return ($state.Release | ConvertTo-Json -Depth 5) }
        'download' {
            $pattern = $call[[Array]::IndexOf($call, '--pattern') + 1]
            $directory = $call[[Array]::IndexOf($call, '--dir') + 1]
            if (-not $state.Omit) { [IO.File]::WriteAllText((Join-Path $directory $pattern), $state.Payload) }
            if ($state.Extra) { [IO.File]::WriteAllText((Join-Path $directory 'extra.exe'), 'inert extra text') }
        }
        default { throw 'Unexpected gh invocation; no real network command is allowed.' }
    }
}
function Unblock-File {
    param([string] $LiteralPath)
    if ($global:DownloadReleaseTestState.Fail -eq 'unblock') { throw 'Mock unblock failed.' }
    $global:DownloadReleaseTestState.Events.Add('unblock')
    $global:DownloadReleaseTestState.Unblocked.Add($LiteralPath)
}
function Start-Process {
    param([string] $FilePath, [string] $WorkingDirectory)
    if ($global:DownloadReleaseTestState.Fail -eq 'launch') { throw 'Mock launch failed.' }
    $global:DownloadReleaseTestState.Events.Add('launch')
    $global:DownloadReleaseTestState.Launched.Add(@($FilePath, $WorkingDirectory))
}
function Reset-State {
    $state = $global:DownloadReleaseTestState
    $state.Calls.Clear()
    $state.Unblocked.Clear()
    $state.Launched.Clear()
    $state.Events.Clear()
    $state.Fail = ''
    $state.Omit = $false
    $state.Extra = $false
    $state.MissingGh = $false
    $state.Payload = 'inert test text, not an executable'
    $state.Release = @{
        tagName = 'v1.2.141'
        url = 'https://github.com/iricigor/fingvibe/releases/tag/v1.2.141'
        isDraft = $false
        isPrerelease = $false
        assets = @(@{ name = 'FingVibe-1.2.141-win-x64-Setup.exe' }, @{ name = 'FingVibe-1.2.141-win-x64.zip' })
    }
}
function Assert-NoRun {
    Assert-Equal $global:DownloadReleaseTestState.Unblocked.Count 0 'Must not unblock'
    Assert-Equal $global:DownloadReleaseTestState.Launched.Count 0 'Must not launch'
}

try {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:OS = 'Windows_NT'
    New-Item -ItemType Directory -Path $temp | Out-Null
    Reset-State
    $output = @(& $helper -DownloadRoot $temp)
    Assert-Equal $output.Count 4 'Report all required fields'
    Assert-Equal $output[0] "Release: $($global:DownloadReleaseTestState.Release.url)" 'Release URL'
    Assert-Equal $output[1] 'Tag: v1.2.141' 'Release tag'
    $firstFile = $output[2].Substring('File: '.Length)
    Assert-Equal (Split-Path $firstFile -Leaf) 'FingVibe-1.2.141-win-x64-Setup.exe' 'Exact asset'
    $expectedHash = (Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash
    Assert-Equal $output[3] "SHA-256 (informational, not verification against a trusted hash): $expectedHash" 'Informational hash'
    Assert-NoRun
    Assert-Equal $global:DownloadReleaseTestState.Calls.Count 3 'Auth, release metadata, download'
    Assert-Equal ($global:DownloadReleaseTestState.Calls[1] -join '|') 'release|view|--repo|iricigor/fingvibe|--json|tagName,url,assets,isDraft,isPrerelease' 'Latest stable metadata query'
    $download = $global:DownloadReleaseTestState.Calls[2]
    Assert-Equal ($download -join '|') "release|download|--repo|iricigor/fingvibe|--pattern|FingVibe-1.2.141-win-x64-Setup.exe|--dir|$(Split-Path $firstFile -Parent)|--|v1.2.141" 'Exact download arguments, no overwrite flag'

    Reset-State
    $output = @(& $helper -DownloadRoot $temp -Tag 'v1.2.141' -AssetName 'FingVibe-1.2.141-win-x64-Setup.exe' -Run)
    $secondFile = $output[2].Substring('File: '.Length)
    if ($secondFile -eq $firstFile) { throw 'Repeated downloads must use fresh directories.' }
    Assert-Equal ([IO.File]::ReadAllText($firstFile)) 'inert test text, not an executable' 'Previous download remains untouched'
    Assert-Equal ($global:DownloadReleaseTestState.Calls[1][-2..-1] -join '|') '--|v1.2.141' 'Explicit tag'
    Assert-Equal $global:DownloadReleaseTestState.Unblocked.Count 1 'Only one unblock'
    Assert-Equal $global:DownloadReleaseTestState.Unblocked[0] $secondFile 'Unblock exact EXE'
    Assert-Equal $global:DownloadReleaseTestState.Launched.Count 1 'Only one launch'
    Assert-Equal $global:DownloadReleaseTestState.Launched[0][0] $secondFile 'Launch exact EXE'
    Assert-Equal $global:DownloadReleaseTestState.Launched[0][1] (Split-Path $secondFile -Parent) 'Launch working directory'
    Assert-Equal ($global:DownloadReleaseTestState.Events -join '|') 'unblock|launch' 'Unblock before launch'

    Reset-State
    $global:DownloadReleaseTestState.Fail = 'unblock'
    Assert-Throws { & $helper -DownloadRoot $temp -Run } '*Mock unblock failed*'
    Assert-NoRun
    Reset-State
    $global:DownloadReleaseTestState.Fail = 'launch'
    Assert-Throws { & $helper -DownloadRoot $temp -Run } '*Mock launch failed*'
    Assert-Equal $global:DownloadReleaseTestState.Launched.Count 0 'Launch failures must propagate'

    Reset-State
    $global:DownloadReleaseTestState.Release.assets += @{ name = 'FingVibe-arm64-Setup.exe' }
    Assert-Throws { & $helper -DownloadRoot $temp -Run } '*Ambiguous EXE selection*Ask the user*'
    Assert-Equal $global:DownloadReleaseTestState.Calls.Count 2 'Ambiguity fails before download'
    Assert-NoRun
    $null = & $helper -DownloadRoot $temp -AssetName 'FingVibe-1.2.141-win-x64-Setup.exe'
    Assert-NoRun

    foreach ($case in @('no-exe', 'missing-name', 'unsafe-name', 'draft', 'prerelease')) {
        Reset-State
        $parameters = @{ DownloadRoot = $temp; Run = $true }
        $pattern = '*No matching Windows EXE*'
        switch ($case) {
            'no-exe' { $global:DownloadReleaseTestState.Release.assets = @(@{ name = 'portable.zip' }) }
            'missing-name' { $parameters.AssetName = 'missing.exe' }
            'unsafe-name' { $global:DownloadReleaseTestState.Release.assets = @(@{ name = '..\escape.exe' }); $pattern = '*Unsafe EXE*' }
            'draft' { $global:DownloadReleaseTestState.Release.isDraft = $true; $pattern = '*Expected a published stable release*' }
            'prerelease' { $global:DownloadReleaseTestState.Release.isPrerelease = $true; $pattern = '*Expected a published stable release*' }
        }
        Assert-Throws { & $helper @parameters } $pattern
        Assert-Equal $global:DownloadReleaseTestState.Calls.Count 2 "$case fails before download"
        Assert-NoRun
    }
    Reset-State
    $global:DownloadReleaseTestState.Release.isPrerelease = $true
    $null = & $helper -DownloadRoot $temp -Tag 'v1.2.141'
    Assert-NoRun

    foreach ($case in @('status', 'view', 'download', 'omit', 'empty', 'extra')) {
        Reset-State
        $pattern = '*Download failed*'
        switch ($case) {
            'status' { $global:DownloadReleaseTestState.Fail = $case; $pattern = '*GitHub authentication failed*' }
            'view' { $global:DownloadReleaseTestState.Fail = $case; $pattern = '*Could not read the release*' }
            'download' { $global:DownloadReleaseTestState.Fail = $case }
            'omit' { $global:DownloadReleaseTestState.Omit = $true; $pattern = '*expected executable was not downloaded*' }
            'empty' { $global:DownloadReleaseTestState.Payload = ''; $pattern = '*executable is empty*' }
            'extra' { $global:DownloadReleaseTestState.Extra = $true; $pattern = '*exactly one downloaded EXE*' }
        }
        Assert-Throws { & $helper -DownloadRoot $temp -Run } $pattern
        Assert-NoRun
    }

    foreach ($path in @($root, (Join-Path $root 'downloads'))) {
        Reset-State
        Assert-Throws { & $helper -DownloadRoot $path -Run } '*outside the checkout*'
        Assert-Equal $global:DownloadReleaseTestState.Calls.Count 2 'Reject checkout destination before download'
        Assert-NoRun
    }
    $junction = Join-Path $temp 'checkout-junction'
    New-Item -ItemType Junction -Path $junction -Value $root | Out-Null
    try {
        Reset-State
        Assert-Throws { & $helper -DownloadRoot (Join-Path $junction 'downloads') -Run } '*not files, symlinks, or junctions*'
        Assert-Equal $global:DownloadReleaseTestState.Calls.Count 2 'Reject redirected destination before download'
        Assert-NoRun
    } finally {
        [IO.Directory]::Delete($junction)
    }
    foreach ($case in @(
        @{ Path = "\\?\$temp"; Pattern = '*ordinary local drive path*' },
        @{ Path = "$root.\downloads"; Pattern = '*outside the checkout*' }
    )) {
        Reset-State
        Assert-Throws { & $helper -DownloadRoot $case.Path -Run } $case.Pattern
        Assert-NoRun
    }
    Reset-State
    $global:DownloadReleaseTestState.MissingGh = $true
    Assert-Throws { & $helper -DownloadRoot $temp } '*GitHub CLI (gh) is required*'
    Assert-Equal $global:DownloadReleaseTestState.Calls.Count 0 'Missing gh fails before invocation'
    Reset-State
    $env:OS = 'Linux'
    Assert-Throws { & $helper -DownloadRoot $temp } '*must run locally on Windows*'
    Assert-Equal $global:DownloadReleaseTestState.Calls.Count 0 'Non-Windows fails before gh'
    $env:OS = 'Windows_NT'
    Reset-State
    Assert-Throws { & { $PSSenderInfo = @{}; & $helper -DownloadRoot $temp -Run } } '*PowerShell remoting detected*'
    Assert-Equal $global:DownloadReleaseTestState.Calls.Count 0 'Remoting fails before gh'
    Assert-NoRun
    foreach ($name in $environmentNames | Where-Object { $_ -ne 'OS' }) {
        Reset-State
        [Environment]::SetEnvironmentVariable($name, 'true')
        Assert-Throws { & $helper -DownloadRoot $temp -Run } '*Cloud/remote execution detected*'
        Assert-Equal $global:DownloadReleaseTestState.Calls.Count 0 'Remote host fails before gh'
        Assert-NoRun
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    Reset-State
    Assert-Throws { & $helper -Repo 'another/repo' -DownloadRoot $temp } '*ValidateSet*'
    Assert-Throws { & $helper -AssetName '*.exe' -DownloadRoot $temp } '*does not match*'
    Assert-NoRun
    'Download-release offline regression checks passed; no network downloads or executable launches.'
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    $global:LASTEXITCODE = $savedExitCode
    Remove-Item Function:\gh, Function:\Get-Command, Function:\Unblock-File, Function:\Start-Process
    Remove-Variable DownloadReleaseTestState -Scope Global
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
