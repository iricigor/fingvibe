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

function Set-UpdateResponse([string] $Outcome = 'newer', [string] $Download = 'success', [string] $Deployment = 'installed', [int] $AdvanceSeconds = 0) {
    $script:now = $script:now.AddSeconds($AdvanceSeconds)
    @{ now = $script:now.ToString('O'); outcome = $Outcome; download = $Download; deployment = $Deployment } |
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

$environment = Save-UiRegressionEnvironment @(
    'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UPDATE_REVIEW')
$fixture = New-UiRegressionFixtureDirectory -Suite updates
$script:response = Join-Path $fixture 'responses.json'
$script:now = [DateTimeOffset]::Parse('2026-11-16T12:00:00Z')
$script:process = $null
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
    $phase = Step-UiRegressionPhase $phase 'Updates/background-and-indicators' $ScreenshotDirectory
    Start-UpdateApp
    Select-UpdateSettings
    Open-UpdateAbout
    Wait-UpdateText UpdateStatus 'Updates have not been checked yet.'
    (Find-UpdateControl OverviewNavItem).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Set-UpdateResponse -AdvanceSeconds 60
    $null = Wait-UiRegressionState { (Find-UpdateSettingsNavigation).Current.ItemStatus -eq 'Update available' } 'background update without About'
    Select-UpdateSettings
    Set-UiReviewTheme $script:root 'Standard Light'
    Assert-UpdateIndicators $true (Join-Path $ScreenshotDirectory 'updates-settings-light.png')
    Open-UpdateAbout
    Wait-UpdateText UpdateStatus 'A newer version is available'
    $check = Show-UpdateControl CheckUpdatesButton
    if (-not $check.Current.IsKeyboardFocusable) { throw 'Check for updates must support keyboard focus.' }
    $check.SetFocus()
    Set-UpdateResponse -Outcome held -AdvanceSeconds 10
    [Windows.Forms.SendKeys]::SendWait(' ')
    Wait-UpdateText UpdateStatus 'Checking for updates...'
    Set-UpdateResponse -Outcome offline
    Wait-UpdateText UpdateStatus 'Unable to determine the latest version'
    Wait-UpdateText UpdateDetails '*Last confirmed*Latest check failed*'
    $null = Show-UpdateControl UpdateStatus
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-last-confirmed.png')
    Invoke-UpdateControl BackToSettingsButton
    Assert-UpdateIndicators $true (Join-Path $ScreenshotDirectory 'updates-retained-indicators.png')
    Set-UiReviewTheme $script:root 'Standard Dark'
    Open-UpdateAbout
    Set-UpdateResponse -Outcome current -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'You are on the latest version'
    Invoke-UpdateControl BackToSettingsButton
    Assert-UpdateIndicators $false (Join-Path $ScreenshotDirectory 'updates-current-dark.png')
    Open-UpdateAbout

    $phase = Step-UiRegressionPhase $phase 'Updates/download-and-launch-failures' $ScreenshotDirectory
    Set-UpdateResponse -Download fail -AdvanceSeconds 10
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'A newer version is available'
    Invoke-UpdateControl DownloadUpdateButton
    $dialog = Wait-UpdateDialog UpdateDownloadFailureDialog Close 'download failure popup'
    $links = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Hyperlink))
    if ($links.Count -ne 1 -or $links[0].Current.Name -notlike '*GitHub Releases*') { throw 'Download failure requires the manual releases hyperlink.' }
    Invoke-UpdateDialogButton Close
    Set-UpdateResponse -Download slow
    Invoke-UpdateControl DownloadUpdateButton
    Invoke-UpdateControl CancelUpdateDownloadButton
    Wait-UpdateText UpdateDownloadStatus 'Download cancelled*'
    if (Test-UiRegressionElementVisible (Find-UpdateControl InstallUpdateButton)) { throw 'Cancelled downloads must never offer installation.' }
    Set-UpdateResponse
    Invoke-UpdateControl DownloadUpdateButton
    Wait-UpdateText UpdateDownloadStatus 'Setup downloaded*'
    Invoke-UpdateControl InstallUpdateButton
    $null = Wait-UiRegressionState { Find-UpdateControl UpdateInstallConfirmationDialog } 'explicit install confirmation'
    Invoke-UpdateDialogButton Cancel
    if ($script:process.HasExited) { throw 'Cancelling confirmation must keep FingVibe running.' }
    Invoke-UpdateControl InstallUpdateButton
    Invoke-UpdateDialogButton 'Install and close'
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

    $phase = Step-UiRegressionPhase $phase 'Updates/portable-narrow' $ScreenshotDirectory
    Stop-UiRegressionApp $script:process
    $script:process.Dispose()
    Set-UpdateResponse -Deployment portable
    Start-UpdateApp
    Select-UpdateSettings
    Open-UpdateAbout
    Invoke-UpdateControl CheckUpdatesButton
    Wait-UpdateText UpdateStatus 'A newer version is available'
    if ((Find-UpdateControl DownloadUpdateButton).Current.Name -ne 'Download portable ZIP') { throw 'Portable copies must receive ZIP, not Setup.' }
    Invoke-UpdateControl DownloadUpdateButton
    Wait-UpdateText UpdateDownloadStatus 'ZIP downloaded*'
    if (Test-UiRegressionElementVisible (Find-UpdateControl InstallUpdateButton)) { throw 'Portable update must not offer installation.' }
    $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 640, 0x0044)) {
        throw [ComponentModel.Win32Exception]::new()
    }
    $null = Show-UpdateControl UpdateStatus
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'updates-portable-narrow.png')
    foreach ($id in @('UpdateStatus', 'UpdateDetails', 'UpdateDeploymentText', 'DownloadUpdateButton', 'UpdateDownloadStatus')) {
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
        { Stop-UiRegressionApp $script:process },
        { if ($script:process) { $script:process.Dispose() } },
        { Restore-UiRegressionEnvironment $environment },
        { Remove-Item -LiteralPath $fixture -Recurse -Force }
    )
}
