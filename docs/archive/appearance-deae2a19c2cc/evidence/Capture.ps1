[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceDirectory,
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [Parameter(Mandatory)][string] $SourceZipSha256
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "Run appearance archive capture only on a disposable GitHub-hosted Windows runner."
}
. (Join-Path $SourceDirectory ".github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $SourceDirectory ".github\scripts\UiReviewAppearance.ps1")

function Find-ArchiveElement([string] $Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element -and -not $element.Current.IsOffscreen) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible archive capture element '$Id' was not found."
}

function Select-ArchivePage([string] $Page) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Page),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $item = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $item -or $item.Current.IsOffscreen) { throw "Navigation '$Page' is not visible." }
    $selection = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selection.Select()
    if (-not $selection.Current.IsSelected) { throw "Navigation did not select '$Page'." }
    $sentinel = switch ($Page) {
        Settings { "ModePicker" }
        Overview { "OverviewNavItem" }
        Devices { "ResultCountText" }
        default { throw "Unexpected archive page '$Page'." }
    }
    $null = Find-ArchiveElement $sentinel
    Start-Sleep -Milliseconds 500
}

function Get-ArchiveChoice([string] $Picker) {
    $selected = (Find-ArchiveElement $Picker).GetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    if ($selected.Count -ne 1) { throw "'$Picker' must have exactly one selected choice." }
    $selected[0].Current.Name
}

function Set-ArchiveAppearance([string] $Mode, [string] $Theme, [string] $Style, [string] $Backdrop) {
    Select-ArchivePage Settings
    foreach ($pair in @(
        @("ModePicker", $Mode), @("ThemePicker", $Theme),
        @("VisualStylePicker", $Style), @("BackdropPicker", $Backdrop)
    )) {
        Set-UiReviewAppearanceChoice -Root $root -Picker $pair[0] -Choice $pair[1]
    }
    foreach ($pair in @(
        @("ModePicker", $Mode), @("ThemePicker", $Theme),
        @("VisualStylePicker", $Style), @("BackdropPicker", $Backdrop)
    )) {
        if ((Get-ArchiveChoice $pair[0]) -ne $pair[1]) { throw "Appearance changed unexpectedly: $($pair[0])." }
    }
    $script:materialStatus = (Find-ArchiveElement BackdropStatus).Current.Name
    if ([string]::IsNullOrWhiteSpace($script:materialStatus)) { throw "Material status was not reported." }
}

function Save-ArchiveCapture([string] $Page, [string] $Mode, [string] $Theme, [string] $Style, [string] $Backdrop) {
    Select-ArchivePage $Page
    if ($Page -eq "Devices" -and (Find-ArchiveElement ResultCountText).Current.Name -ne "8 devices") {
        throw "The eight-device synthetic snapshot did not load."
    }
    $name = if ($Page -eq "Settings") { "settings.png" }
        else { "$($Style.ToLowerInvariant())-$($Mode.ToLowerInvariant())-$($Theme.ToLowerInvariant())-$($Page.ToLowerInvariant()).png" }
    $path = Join-Path $OutputDirectory $name
    $null = [UiReviewNativeWindow]::SetForegroundWindow($windowHandle)
    Start-Sleep -Milliseconds 700
    Save-UiReviewWindowScreenshot -WindowHandle $windowHandle -Path $path
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        if ($bitmap.Width -ne 1600 -or $bitmap.Height -ne 960) {
            throw "All archive captures must use the same 1600x960 physical-pixel viewport."
        }
    } finally { $bitmap.Dispose() }
    $fallback = $script:materialStatus -notlike "Changes are previewed immediately*"
    $captures.Add([ordered]@{
        file = $name; page = $Page; mode = $Mode; theme = $Theme
        style = $Style; backdrop = $Backdrop
        materialStatus = $script:materialStatus
        materialEvidence = if ($Backdrop -eq "Solid") { "Solid selected; no native material requested." }
            elseif ($fallback) { "Opaque/system-color fallback reported by the application; intended native material not evidenced." }
            else { "Application reports material available; native material rendering remains Windows-managed, not independently measured." }
        width = 1600; height = 960; capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    Write-Host "Archived $name; $script:materialStatus"
}

$process = $null
$captures = [System.Collections.Generic.List[object]]::new()
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
if ($previousContext -eq [IntPtr]::Zero) { throw [System.ComponentModel.Win32Exception]::new() }
$savedReview = $env:FINGVIBE_UI_REVIEW
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
try {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $fixture = Join-Path $SourceDirectory "docs\screenshots\devices-fixture.json"
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = (Resolve-Path -LiteralPath $fixture).Path
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Archive app exited with code $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $windowHandle = $process.MainWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) { throw "Archive app did not create a window." }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    Initialize-UiReviewWindow $windowHandle
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($area.Width -lt 1600 -or $area.Height -lt 960) { throw "Disposable desktop must fit 1600x960 pixels." }
    if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::Zero,
            $area.Left, $area.Top, 1600, 960, 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 700
    $uiSettings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType=WindowsRuntime]::new()
    $accessibility = [Windows.UI.ViewManagement.AccessibilitySettings, Windows.UI.ViewManagement, ContentType=WindowsRuntime]::new()
    foreach ($style in @("Glass", "Clay", "Neumorphic")) {
        $backdrop = if ($style -eq "Glass") { "Mica Alt" } else { "Solid" }
        foreach ($mode in @("Light", "Dark")) {
            foreach ($theme in @("Standard", "Colored")) {
                Set-ArchiveAppearance $mode $theme $style $backdrop
                foreach ($page in @("Overview", "Devices")) {
                    Save-ArchiveCapture $page $mode $theme $style $backdrop
                }
            }
        }
    }
    Set-ArchiveAppearance Dark Standard Glass "Mica Alt"
    foreach ($picker in @("ModePicker", "ThemePicker", "VisualStylePicker", "BackdropPicker")) {
        $bounds = (Find-ArchiveElement $picker).Current.BoundingRectangle
        if (-not $root.Current.BoundingRectangle.Contains($bounds) -or $bounds.IsEmpty) {
            throw "Settings screenshot must show all four dropdowns completely."
        }
    }
    Save-ArchiveCapture Settings Dark Standard Glass "Mica Alt"
    if ($captures.Count -ne 25 -or @($captures.sha256 | Select-Object -Unique).Count -ne 25) {
        throw "Expected exactly 25 distinct screenshots."
    }
    [ordered]@{
        sourceCommit = "deae2a19c2cc8218183f08b777347215b7fa31e6"
        sourceBranch = "iricigor-solid-chainsaw"; sourcePullRequest = 143
        sourceZipSha256 = $SourceZipSha256.ToLowerInvariant()
        captureRun = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
        captureAttempt = $env:GITHUB_RUN_ATTEMPT; captureWorkflowCommit = $env:GITHUB_SHA
        runnerImage = $env:ImageOS; runnerImageVersion = $env:ImageVersion
        osVersion = [Environment]::OSVersion.VersionString
        dpi = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle)
        highContrast = $accessibility.HighContrast
        advancedEffectsEnabled = $uiSettings.AdvancedEffectsEnabled
        fixture = "docs/screenshots/devices-fixture.json"
        fixtureSha256 = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
        fixtureNote = "Unmodified archived eight-device TEST-NET-1 saved snapshot; no LAN scan. Review mode supplies loopback network and example public identity."
        captures = $captures.ToArray()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "capture-manifest.json") -Encoding UTF8
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $savedReview
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
