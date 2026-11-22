param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Update UI checks require a disposable GitHub-hosted desktop.'
}
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewScreenshot.ps1')
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewAppearance.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class UpdateReviewContrast
{
    [StructLayout(LayoutKind.Sequential)]
    private struct HIGHCONTRAST
    {
        public uint Size;
        public uint Flags;
        public IntPtr Scheme;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);

    public static uint GetFlags()
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }

    public static void SetFlags(uint flags)
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
"@

function Find-UpdateControl([string] $Id) {
    $call = Start-UiRegressionCall lookup
    try {
        $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
    }
    finally { Complete-UiRegressionCall $call }
}

function Find-UpdateSettingsNavigation {
    $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Settings'),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem)))
}

function Show-UpdateControl([string] $Id, [string] $Viewport = 'UpdatesScroll') {
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-UpdateControl $Viewport } `
        -GetTargets { Find-UpdateControl $Id } -GetWindow { $script:root } -Description $Id
    Find-UpdateControl $Id
}

function Invoke-UpdateControl([string] $Id) {
    $element = Show-UpdateControl $Id
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-UpdateSettings {
    $settings = Find-UpdateSettingsNavigation
    if (-not (Test-UiRegressionElementVisible $settings)) {
        (Find-UpdateControl TogglePaneButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $settings = Find-UpdateSettingsNavigation
    }
    $settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $null = Wait-UiRegressionState { Test-UiRegressionElementVisible (Find-UpdateControl AboutSettingsButton) } 'Settings About row'
}

function Open-UpdateAbout {
    $row = Show-UpdateControl AboutSettingsButton SettingsPage
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    $null = Wait-UiRegressionState { Find-UpdateControl UpdateStatus } 'About update section'
}

function Set-UpdateResponse([string] $Outcome = 'newer', [string] $Download = 'success', [string] $Deployment = 'installed',
    [bool] $Metered = $true, [int] $AdvanceSeconds = 0, [string] $Notes = 'default') {
    $script:now = $script:now.AddSeconds($AdvanceSeconds)
    @{ now = $script:now.ToString('O'); outcome = $Outcome; download = $Download; deployment = $Deployment; metered = $Metered; notes = $Notes } |
        ConvertTo-Json | Set-Content -LiteralPath "$script:response.new" -Encoding UTF8
    [IO.File]::Move("$script:response.new", $script:response, $true)
}

function Wait-UpdateText([string] $Id, [string] $Pattern) {
    $null = Wait-UiRegressionState { (Find-UpdateControl $Id).Current.Name -like $Pattern } "$Id text '$Pattern'"
}

function Start-UpdateApp {
    $call = Start-UiRegressionCall launch
    try {
        $script:process = Start-Process -FilePath $AppPath -PassThru
        $handle = Wait-UiRegressionWindow $script:process
        Initialize-UiReviewWindow $handle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $null = Wait-UiRegressionState { Find-UpdateControl OverviewNavItem } 'update app navigation readiness'
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-UpdateIndicators([bool] $Available, [string] $Capture) {
    $row = Show-UpdateControl AboutSettingsButton SettingsPage
    $nav = Find-UpdateSettingsNavigation
    foreach ($element in @($row, $nav)) {
        if (($element.Current.ItemStatus -eq 'Update available') -ne $Available) {
            throw 'Settings navigation and About row must share accessible update availability.'
        }
    }
    if ($Available -and (Find-UpdateControl AboutSummary).Current.Name -notlike '*Update available*Last confirmed*') {
        throw 'About row must visibly explain the timestamped confirmed update.'
    }
    Save-UiRegressionScreenshot $script:process.MainWindowHandle $Capture
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $bitmap = [Drawing.Bitmap]::new($Capture)
    try {
        foreach ($element in @($row, $nav)) {
            $bounds = $element.Current.BoundingRectangle
            $orange = 0
            for ($x = [int]($bounds.Left - $window.Left); $x -lt [int]($bounds.Right - $window.Left); $x += 2) {
                for ($y = [int]($bounds.Top - $window.Top); $y -lt [int]($bounds.Bottom - $window.Top); $y += 2) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ($pixel.R -gt 180 -and $pixel.G -ge 70 -and $pixel.G -lt 180 -and $pixel.B -lt 60) { $orange++ }
                }
            }
            if (($orange -ge 4) -ne $Available) { throw "Rendered orange indicator mismatch: expected=$Available pixels=$orange." }
        }
    }
    finally { $bitmap.Dispose() }
}

function Wait-UpdateDialog([string] $Id, [string] $DismissButton, [string] $Description) {
    # Dialogs gain their automation ID before ShowAsync realizes content; wait for the opened, rendered dialog.
    Wait-UiRegressionState {
        $dialog = Find-UpdateControl $Id
        if (-not (Test-UiRegressionElementVisible $dialog)) { return $null }
        $dismiss = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, $DismissButton),
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button)))
        if (Test-UiRegressionElementVisible $dismiss) { return $dialog }
    } $Description
}

function Invoke-UpdateDialogButton([string] $Name) {
    $button = Wait-UiRegressionState {
        foreach ($id in @('UpdateDownloadFailureDialog', 'UpdateInstallConfirmationDialog', 'UpdateLaunchFailureDialog')) {
            $dialog = Find-UpdateControl $id
            if (-not (Test-UiRegressionElementVisible $dialog)) { continue }
            $found = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.AndCondition]::new(
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)))
            if (Test-UiRegressionElementVisible $found) { return $found }
        }
    } "dialog action $Name"
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Invoke-UpdateNow {
    Invoke-UpdateControl InstallUpdateButton
    $null = Wait-UiRegressionState { Find-UpdateControl UpdateInstallConfirmationDialog } 'Update now confirmation'
    Invoke-UpdateDialogButton 'Update now'
}

function Assert-UpdateReleaseNotes([string] $Capture) {
    $notes = Show-UpdateControl ReleaseNotesExpander
    $pattern = $notes.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($notes.Current.Name -ne "What's new in 1.2.130" -or
        $pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed -or
        (Test-UiRegressionElementVisible (Find-UpdateControl ReleaseNotesFallbackLink))) {
        throw "An available update must start with a collapsed 'What's new in 1.2.130' expander and no fallback link."
    }
    $pattern.Expand()
    $full = Show-UpdateControl ReleaseNotesFullLink
    $null = Wait-UiRegressionState {
        $pattern.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded
    } 'expanded release notes state'
    $texts = @($notes.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)) | ForEach-Object { $_.Current.Name })
    $links = @($notes.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Hyperlink)))
    if ('Highlights' -notin $texts -or 'Release notes in About: see #695.' -notin $texts -or
        @($texts | Where-Object { $_ -match 'alert|<script|https?://|\*\*' }).Count -ne 0 -or
        $links.Count -ne 1 -or $full.Current.Name -ne 'View full notes on GitHub (opens in browser)') {
        throw "Release notes must render headings and bullets as inert plain text with only the explicit full-notes link: $($texts -join ' | ')."
    }
    $null = Show-UpdateControl ReleaseNotesExpander
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory $Capture)
    $pattern.Collapse()
}

$environment = Save-UiRegressionEnvironment @(
    'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UPDATE_REVIEW')
$fixture = New-UiRegressionFixtureDirectory -Suite updates
$script:response = Join-Path $fixture 'responses.json'
$script:now = [DateTimeOffset]::Parse('2026-11-16T12:00:00Z')
$script:process = $null
$script:contrastFlags = $null
$script:root = $null
$phase = $null
$failure = $null
try {
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $env:FINGVIBE_UI_REVIEW = '1'
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture 'inventory.json'
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture 'unused-snapshot.json'
    $env:FINGVIBE_UPDATE_REVIEW = $script:response
    Set-UpdateResponse
    $handoffDirectory = Join-Path $fixture 'downloads'
    $null = New-Item -ItemType Directory -Path $handoffDirectory -Force
    @{
        schema = 1
        attemptId = 'previous-fixture'
        state = 'succeeded'
        requestedUtc = '2026-11-16T11:58:00Z'
        originProcessId = 100
        originProcessStartedUtc = '2026-11-16T11:57:00Z'
        originExecutablePath = $AppPath
        recordPath = (Join-Path $handoffDirectory 'install-handoff.json')
        helperProcessId = 101
        helperProcessStartedUtc = '2026-11-16T11:58:01Z'
        installerPath = (Join-Path $handoffDirectory 'FingVibe-1.2.99-win-x64-Setup.exe')
        installerSize = 17
        installerSha256 = ('A' * 64)
        expectedZoneId = 3
        expectedVersion = '1.2.99'
        installationDirectory = (Split-Path -Parent $AppPath)
        relaunchRequested = $true
        relaunchExecutablePath = $AppPath
        installerLogPath = (Join-Path $handoffDirectory 'installer.log')
        latestRecordPath = (Join-Path $handoffDirectory 'install-handoff.json')
        installerProcessId = 102
        installerProcessStartedUtc = '2026-11-16T11:58:02Z'
        outcome = @{
            completedUtc = '2026-11-16T11:59:00Z'
            installerExitCode = 0
            relaunchStarted = $true
            relaunchProcessId = 103
            error = $null
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $handoffDirectory 'install-handoff.json') -Encoding UTF8
    $phase = Step-UiRegressionPhase $phase 'Updates/background-and-indicators' $ScreenshotDirectory
    # Hold the GitHub response so the automatic startup check is observable before any time passes.
    Set-UpdateResponse -Outcome held
    Start-UpdateApp
    Select-UpdateSettings
    Open-UpdateAbout
    Wait-UpdateText UpdateStatus 'Checking for updates...'
    Wait-UpdateText UpdateInstallOutcome 'Updated to 1.2.99.'
    (Find-UpdateControl OverviewNavItem).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Set-UpdateResponse
    $null = Wait-UiRegressionState { (Find-UpdateSettingsNavigation).Current.ItemStatus -eq 'Update available' } 'background update without About'
    Select-UpdateSettings
    $settingsUpdate = Find-UpdateControl SettingsUpdateNowButton
    if (-not (Test-UiRegressionElementVisible $settingsUpdate) -or
        -not $settingsUpdate.Current.IsKeyboardFocusable -or $settingsUpdate.Current.Name -ne 'Update FingVibe now') {
        throw 'Settings must offer a separate, keyboard-accessible Update now action.'
    }
    Set-UiReviewTheme $script:root 'Standard Light'
    Assert-UpdateIndicators $true (Join-Path $ScreenshotDirectory 'updates-settings-light.png')
    # The Settings action lives in the Settings page scroller, not the About UpdatesScroll viewport.
    $settingsUpdate = Show-UpdateControl SettingsUpdateNowButton SettingsPage
    $settingsUpdate.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState { Find-UpdateControl UpdateInstallConfirmationDialog } `
        'Settings Update now confirmation'
    Invoke-UpdateDialogButton Cancel
    Wait-UpdateText UpdateStatus 'FingVibe * is available.'
    # AboutView is a UserControl without its own UIA peer; the About scroller replacing the Settings scroller proves the shared path.
    $null = Wait-UiRegressionState {
        (Test-UiRegressionElementVisible (Find-UpdateControl UpdatesScroll)) -and
            -not (Test-UiRegressionElementVisible (Find-UpdateControl SettingsPage))
    } 'Settings Update now shared About action path'
    Wait-UpdateText UpdateStatus 'FingVibe * is available.'
    if (-not (Test-UiRegressionElementVisible (Find-UpdateControl UpdateSecurityWarning)) -or
        (Find-UpdateControl UpdateDetailsExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
                [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
        throw 'Windows security wording must stay visible while update diagnostics remain collapsed.'
    }
    Assert-UpdateReleaseNotes 'updates-release-notes-light.png'
    $check = Show-UpdateControl CheckUpdatesButton
    if (-not $check.Current.IsKeyboardFocusable) { throw 'Check for updates must support keyboard focus.' }
    $check.SetFocus()
    Set-UpdateResponse -Outcome held -AdvanceSeconds 10
    [Windows.Forms.SendKeys]::SendWait(' ')
    Wait-UpdateText UpdateStatus 'Checking for updates...'
    Set-UpdateResponse -Outcome offline
    Wait-UpdateText UpdateStatus 'Update check failed:*'
    $details = Find-UpdateControl UpdateDetailsExpander
    $details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Wait-UpdateText UpdateDetails '*Last confirmed*Latest check failed*'
    Wait-UpdateText UpdateDetails '*Background download skipped because the connection is metered or its cost is unknown.*'
    Wait-UpdateText UpdateLastChecked 'Last checked * ago'
    $null = Show-UpdateControl UpdateStatus
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-last-confirmed.png')
    Invoke-UpdateControl BackToSettingsButton
    Assert-UpdateIndicators $true (Join-Path $ScreenshotDirectory 'updates-retained-indicators.png')
    Set-UiReviewTheme $script:root 'Standard Dark'
    Open-UpdateAbout
    Set-UpdateResponse -Outcome current -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'FingVibe is up to date.'
    Invoke-UpdateControl BackToSettingsButton
    Assert-UpdateIndicators $false (Join-Path $ScreenshotDirectory 'updates-current-dark.png')
    Open-UpdateAbout

    $phase = Step-UiRegressionPhase $phase 'Updates/download-and-launch-failures' $ScreenshotDirectory
    Set-UpdateResponse -Download fail -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'FingVibe * is available.'
    Assert-UpdateReleaseNotes 'updates-release-notes-dark.png'
    $script:contrastFlags = [UpdateReviewContrast]::GetFlags()
    [UpdateReviewContrast]::SetFlags($script:contrastFlags -bor 1)
    if (([UpdateReviewContrast]::GetFlags() -band 1) -eq 0) { throw 'High contrast did not activate.' }
    Start-Sleep -Seconds 2
    Assert-UpdateReleaseNotes 'updates-release-notes-high-contrast.png'
    [UpdateReviewContrast]::SetFlags($script:contrastFlags)
    $script:contrastFlags = $null
    Start-Sleep -Seconds 2
    Invoke-UpdateNow
    $dialog = Wait-UpdateDialog UpdateDownloadFailureDialog Close 'download failure popup'
    $links = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Hyperlink))
    if ($links.Count -ne 1 -or $links[0].Current.Name -notlike '*GitHub Releases*') { throw 'Download failure requires the manual releases hyperlink.' }
    Invoke-UpdateDialogButton Close
    Set-UpdateResponse -Download slow
    Invoke-UpdateNow
    Invoke-UpdateControl CancelUpdateDownloadButton
    Wait-UpdateText UpdateDownloadStatus 'Download cancelled*'
    if (-not (Test-UiRegressionElementVisible (Find-UpdateControl InstallUpdateButton))) {
        throw 'Cancelled downloads must leave Update now available for a safe retry.'
    }
    Set-UpdateResponse
    if ((Find-UpdateControl InstallUpdateButton).Current.Name -ne 'Update now') {
        throw 'A verified installed update must use the one-action Update now control.'
    }
    Invoke-UpdateControl InstallUpdateButton
    $null = Wait-UiRegressionState { Find-UpdateControl UpdateInstallConfirmationDialog } 'explicit install confirmation'
    Invoke-UpdateDialogButton Cancel
    if ($script:process.HasExited) { throw 'Cancelling confirmation must keep FingVibe running.' }
    Invoke-UpdateNow
    $dialog = Wait-UpdateDialog UpdateLaunchFailureDialog OK 'installer rejection popup'
    $links = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Hyperlink))
    $buttons = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button))
    if ($links.Count -ne 0 -or $buttons.Count -ne 1 -or $buttons[0].Current.Name -ne 'OK') {
        throw 'Installer launch failure must have acknowledgement only, with no links/retry/open actions.'
    }
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-launch-rejected.png')
    Invoke-UpdateDialogButton OK
    if ($script:process.HasExited) { throw 'Rejected installer handoff must keep FingVibe open.' }

    $phase = Step-UiRegressionPhase $phase 'Updates/background-staging' $ScreenshotDirectory
    # Use a newer release than the one already verified by the foreground flow; a verified version is never re-downloaded.
    Set-UpdateResponse -Outcome newest -Download fail -Metered $false -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'FingVibe v1.2.131 is available.'
    $details = Find-UpdateControl UpdateDetailsExpander
    if ($details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        $details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    }
    Wait-UpdateText UpdateDetails '*Background download failed: Controlled download failure.*'
    if (Test-UiRegressionElementVisible (Find-UpdateControl UpdateDownloadFailureDialog)) {
        throw 'Background download failure must remain diagnostic-only; it must not show a popup.'
    }
    Set-UpdateResponse -Outcome newest -Metered $false -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateDetails '*A verified update to 1.2.131 is ready.*'
    Set-UpdateResponse -Outcome newest -Download fail -Metered $false
    Invoke-UpdateNow
    $dialog = Wait-UpdateDialog UpdateLaunchFailureDialog OK 'staged update installer rejection'
    Invoke-UpdateDialogButton OK
    if ($script:process.HasExited) { throw 'A staged update must reach the handoff without foreground download.' }

    $phase = Step-UiRegressionPhase $phase 'Updates/portable-narrow' $ScreenshotDirectory
    Stop-UiRegressionApp $script:process
    $script:process.Dispose()
    Set-UpdateResponse -Deployment portable -Notes empty
    Start-UpdateApp
    Select-UpdateSettings
    Open-UpdateAbout
    # The relaunched app checks at startup; Check for updates is disabled until that check completes.
    Wait-UpdateText UpdateStatus 'FingVibe * is available.'
    $null = Wait-UiRegressionState { (Find-UpdateControl CheckUpdatesButton).Current.IsEnabled } `
        'Check for updates enabled after the startup check'
    $fallback = Show-UpdateControl ReleaseNotesFallbackLink
    if ($fallback.Current.Name -ne 'View release notes on GitHub (opens in browser)' -or
        (Test-UiRegressionElementVisible (Find-UpdateControl ReleaseNotesExpander))) {
        throw 'Empty release notes must fall back to the GitHub release notes link without an expander.'
    }
    if ((Find-UpdateControl DownloadUpdateButton).Current.Name -ne 'Download portable ZIP') { throw 'Portable copies must receive ZIP, not Setup.' }
    Invoke-UpdateControl DownloadUpdateButton
    Wait-UpdateText UpdateDownloadStatus 'ZIP downloaded*'
    if (Test-UiRegressionElementVisible (Find-UpdateControl InstallUpdateButton)) { throw 'Portable update must not offer installation.' }
    $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 640, 0x0044)) {
        throw [ComponentModel.Win32Exception]::new()
    }
    $null = Show-UpdateControl UpdateStatus
    $details = Find-UpdateControl UpdateDetailsExpander
    $details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-portable-narrow.png')
    foreach ($id in @('UpdateStatus', 'UpdateDetails', 'UpdateDeploymentText', 'DownloadUpdateButton', 'UpdateDownloadStatus', 'ReleaseNotesFallbackLink')) {
        $element = Show-UpdateControl $id
        if (-not (Test-UiRegressionElementWithin $element (Find-UpdateControl UpdatesScroll) $script:root)) {
            throw "Narrow update content is clipped or unreachable: $id."
        }
    }
}
catch {
    $failure = $_
    if ($script:process -and -not $script:process.HasExited) {
        try { Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-failure.png') }
        catch { Write-Warning "Could not capture update failure: $_" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed ($null -ne $failure) -Steps @(
        { if ($phase) { Complete-UiRegressionPhase $phase -Directory $ScreenshotDirectory -Succeeded ($null -eq $failure) } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name 'Updates' },
        { if ($null -ne $script:contrastFlags) { [UpdateReviewContrast]::SetFlags($script:contrastFlags) } },
        { Stop-UiRegressionApp $script:process },
        { if ($script:process) { $script:process.Dispose() } },
        { Restore-UiRegressionEnvironment $environment },
        { Remove-Item -LiteralPath $fixture -Recurse -Force }
    )
}
