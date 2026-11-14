param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Database backup UI checks require a disposable GitHub-hosted desktop.'
}
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewScreenshot.ps1')
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewAppearance.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'Inventory.Sqlite.Helpers.ps1')
Initialize-InventorySqlite $AppPath

function Find-BackupControl([string] $Id) {
    if (-not $script:root) { return $null }
    $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}

function Invoke-BackupControl([string] $Id) {
    $control = Find-BackupControl $Id
    if (-not $control) { throw "Missing backup control '$Id'." }
    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-BackupNavigation([string] $Id) {
    $item = Find-BackupControl $Id
    if (-not (Test-UiRegressionElementVisible $item)) { Invoke-BackupControl TogglePaneButton }
    $item = Find-BackupControl $Id
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Open-BackupPage {
    Select-BackupNavigation ToolsNavItem
    $card = Wait-UiRegressionState { Find-BackupControl DatabaseBackupsCard } 'Database backups Tools card'
    $card.SetFocus()
    $scrollItem = $null
    if ($card.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
        $scrollItem.ScrollIntoView()
    }
    $null = Wait-UiRegressionState { Test-UiRegressionElementVisible (Find-BackupControl DatabaseBackupsCard) } 'reachable backup card'
    Invoke-BackupControl DatabaseBackupsCard
}

function Wait-BackupSurface([string] $State, [int] $After = 0) {
    Wait-UiRegressionSurfaceState -GetElement { Find-BackupControl BackupsScroll } `
        -Description 'Database backups list' -Selection 'Database backups' -State $State -After $After
}

function Show-BackupAction([string] $Id) {
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-BackupControl BackupsScroll } `
        -GetTargets { Find-BackupControl $Id } -GetWindow { $script:root } -Description $Id
}

function Start-BackupApp {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    $null = Wait-UiRegressionState {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Backup review app exited: $($script:process.ExitCode)." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    } 'backup review window' -TimeoutMilliseconds 30000
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    $null = Wait-UiRegressionState { Find-BackupControl ToolsNavItem } 'Tools navigation readiness'
}

$environment = Save-UiRegressionEnvironment @(
    'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_BACKUP_HOLD')
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-backup-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixture 'device-inventory.json'
$database = [IO.Path]::ChangeExtension($inventory, '.sqlite')
$hold = Join-Path $fixture 'backup-hold'
$script:process = $null
$script:root = $null
$phase = $null
$failure = $null
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $env:FINGVIBE_UI_REVIEW = '1'
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture 'unused-snapshot.json'
    $env:FINGVIBE_UI_REVIEW_BACKUP_HOLD = $hold
    $phase = Step-UiRegressionPhase $phase 'Backups/missing' -Directory $ScreenshotDirectory
    Start-BackupApp
    Open-BackupPage
    $null = Wait-BackupSurface Empty
    if ((Find-BackupControl CompletedBackupsExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
        throw 'Completed backups must initially be collapsed.'
    }
    if ((Find-BackupControl BackupStatusText).Current.Name -notlike 'No database to back up*' -or (Test-Path $database)) {
        throw 'Missing inventory must be explicit and must not create an empty database.'
    }
    Show-BackupAction OpenBackupFolderButton
    Invoke-BackupControl OpenBackupFolderButton
    $null = Wait-UiRegressionState {
        $errorBar = Find-BackupControl BackupError
        if (-not (Test-UiRegressionElementVisible $errorBar)) { return $false }
        $text = @($errorBar.FindAll([System.Windows.Automation.TreeScope]::Subtree,
            [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
        $text -contains 'Backup needs attention' -and
            @($text | Where-Object { $_ -like 'Could not open backup folder:*Create a successful backup first*' }).Count -gt 0
    } 'inline unavailable-folder error'
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-empty.png')
    Stop-UiRegressionApp $script:process
    $script:process.Dispose()
    $script:process = $null

    $phase = Step-UiRegressionPhase $phase 'Backups/running-navigation' -Directory $ScreenshotDirectory
    @{
        version = 4
        data = @{
            revision = [Guid]::NewGuid().ToString()
            devices = @{}; names = @{}; classifications = @{}
            peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
            virtualDevices = @(); discoveryBaselines = @()
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $inventory -Encoding utf8
    Set-Content -LiteralPath $hold -Value 'hold synthetic backup, not SQLite'
    Start-BackupApp
    Open-BackupPage
    $null = Wait-BackupSurface Empty
    Show-BackupAction BackUpNowButton
    Invoke-BackupControl BackUpNowButton
    $null = Wait-UiRegressionState {
        (Find-BackupControl BackupStatusText).Current.Name -eq 'Creating backup...' -and
            -not (Find-BackupControl BackUpNowButton).Current.IsEnabled
    } 'indeterminate running backup and disabled manual action'
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-running.png')
    Select-BackupNavigation DevicesNavItem
    Open-BackupPage
    $null = Wait-BackupSurface Empty
    if ((Find-BackupControl BackupStatusText).Current.Name -ne 'Creating backup...') {
        throw 'Navigation must not cancel application-level backup work.'
    }
    Remove-Item -LiteralPath $hold
    $null = Wait-BackupSurface Ready
    if ((Find-BackupControl BackupCount).Current.Name -notlike '1 backup - newest * ago - oldest * ago') {
        throw 'Completed backup list did not refresh after creation.'
    }
    $null = Wait-UiRegressionState {
        (Find-BackupControl BackUpNowButton).Current.Name -eq 'Backed up' -and
            -not (Find-BackupControl BackUpNowButton).Current.IsEnabled
    } 'successful manual backup feedback and disabled cooldown'
    Select-BackupNavigation DevicesNavItem
    Open-BackupPage
    $null = Wait-BackupSurface Ready
    if ((Find-BackupControl BackUpNowButton).Current.Name -ne 'Backed up' -or
        (Find-BackupControl BackUpNowButton).Current.IsEnabled) {
        throw 'Navigation must preserve the application-level manual cooldown.'
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-completed-collapsed.png')
    Show-BackupAction CompletedBackupsExpander
    (Find-BackupControl CompletedBackupsExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Wait-UiRegressionState { Test-UiRegressionElementVisible (Find-BackupControl BackupRows) } 'expanded completed backup list'
    $copies = @(Get-ChildItem (Join-Path $fixture 'Backups') -Filter '*.sqlite')
    if ($copies.Count -ne 1 -or
        (Get-InventorySqliteValue $copies[0].FullName 'PRAGMA integrity_check') -ne 'ok') {
        throw 'The displayed completed copy must be independently readable.'
    }

    $phase = Step-UiRegressionPhase $phase 'Backups/error-last-success' -Directory $ScreenshotDirectory
    # The one-minute boundary is covered with fake time in Core; a new app session can exercise failure/retry without a desktop delay.
    Stop-UiRegressionApp $script:process
    $script:process.Dispose()
    $script:process = $null
    Start-BackupApp
    Open-BackupPage
    $null = Wait-BackupSurface Ready
    $lock = Join-Path $fixture 'Backups\device-inventory.backup.lock'
    Remove-Item -LiteralPath $lock
    $null = New-Item -ItemType Directory -Path $lock
    Show-BackupAction BackUpNowButton
    $before = (ConvertFrom-UiRegressionSurfaceStatus (Find-BackupControl BackupsScroll).Current.ItemStatus).Request
    Invoke-BackupControl BackUpNowButton
    $null = Wait-BackupSurface Error $before
    if ((Find-BackupControl BackupLastSuccess).Current.Name -like 'No successful*' -or
        (Find-BackupControl BackupCount).Current.Name -notlike '1 backup - newest * ago - oldest * ago' -or
        -not (Find-BackupControl BackUpNowButton).Current.IsEnabled -or
        (Find-BackupControl BackUpNowButton).Current.Name -ne 'Back up now') {
        throw 'A later failure must keep the last successful copy visible.'
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-error.png')
    Remove-Item -LiteralPath $lock
    $before = (ConvertFrom-UiRegressionSurfaceStatus (Find-BackupControl BackupsScroll).Current.ItemStatus).Request
    Invoke-BackupControl BackUpNowButton
    $null = Wait-BackupSurface Ready $before

    $phase = Step-UiRegressionPhase $phase 'Backups/themes-keyboard-narrow' -Directory $ScreenshotDirectory
    foreach ($theme in $UiReviewAppearanceThemes) {
        Select-BackupNavigation DevicesNavItem
        $settings = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Settings'))
        if (-not (Test-UiRegressionElementVisible $settings)) {
            Invoke-BackupControl TogglePaneButton
            $settings = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Settings'))
        }
        $settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $null = Wait-UiRegressionState { Find-BackupControl ModePicker } 'appearance settings'
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-BackupPage
        $null = Wait-BackupSurface Ready
        Show-BackupAction OpenBackupFolderButton
        (Find-BackupControl OpenBackupFolderButton).SetFocus()
        $null = Wait-UiRegressionState { (Find-BackupControl OpenBackupFolderButton).Current.HasKeyboardFocus } 'keyboard focus during manual backup cooldown'
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "backups-$theme.png")
    }
    $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero, 0, 0, 640, 760, 0x0044)
    Show-BackupAction OpenBackupFolderButton
    foreach ($id in @('BackUpNowButton', 'OpenBackupFolderButton')) {
        if (-not (Test-UiRegressionElementWithin (Find-BackupControl $id) (Find-BackupControl BackupsScroll) $script:root)) {
            throw "$id is clipped in the narrow backup page."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-narrow.png')
    Show-BackupAction BackupsBackButton
    Invoke-BackupControl BackupsBackButton
    $null = Wait-UiRegressionState { (Find-BackupControl DatabaseBackupsCard).Current.HasKeyboardFocus } 'Back to Tools restores card focus'
}
catch {
    $failure = $_
    Write-Host $failure
    Write-Host $failure.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-failure.png') }
        catch { Write-Warning "Could not capture backup failure: $_" }
    }
    throw $failure
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed ($null -ne $failure) -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded ($null -eq $failure) } },
        { Stop-UiRegressionApp $script:process },
        { if ($script:process) { $script:process.Dispose() } },
        { Restore-UiRegressionEnvironment $environment },
        { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    )
}
