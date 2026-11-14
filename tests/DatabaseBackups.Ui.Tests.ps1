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

function Expand-BackupCopies {
    Show-BackupAction CompletedBackupsExpander
    (Find-BackupControl CompletedBackupsExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Wait-UiRegressionState {
        $rows = Find-BackupControl BackupRows
        if (-not $rows) { return $false }
        $bounds = $rows.Current.BoundingRectangle
        $section = (Find-BackupControl CompletedBackupsExpander).Current.BoundingRectangle
        $summary = (Find-BackupControl BackupCount).Current.BoundingRectangle
        -not $bounds.IsEmpty -and $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and
            $bounds.Top -ge $summary.Bottom -and $bounds.Bottom -le $section.Bottom
    } 'fully laid-out completed backup contents'
    Show-BackupAction BackupRows
}

function Assert-BackupButtonColor([string] $Capture, [string] $Outcome) {
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $button = (Find-BackupControl BackUpNowButton).Current.BoundingRectangle
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $image = [System.Drawing.Bitmap]::new($Capture)
    try {
        $pixel = $image.GetPixel([int]($button.Left - $window.Left + 6 * $scale),
            [int]($button.Top - $window.Top + 6 * $scale))
        $matches = if ($Outcome -eq 'success') { $pixel.G -gt $pixel.R + 5 -and $pixel.G -gt $pixel.B + 5 }
            else { $pixel.R -gt $pixel.G + 5 -and $pixel.R -gt $pixel.B + 5 }
        if (-not $matches) { throw "Disabled $Outcome button did not retain its muted outcome color: $pixel." }
    }
    finally { $image.Dispose() }
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
    if ((Find-BackupControl BackUpNowButton).Current.Name -ne 'No database to back up' -or (Test-Path $database)) {
        throw 'Missing inventory must be explicit and must not create an empty database.'
    }
    if ((Find-BackupControl BackupPolicyExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed -or (Find-BackupControl BackupStatusText)) {
        throw 'Policy must start collapsed and the redundant backup-status line must not be rendered.'
    }
    (Find-BackupControl BackupPolicyExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Wait-UiRegressionState {
        $policy = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'Keeps the latest seven backups plus the newest copy from each of the last seven backup days. Daily copies survive days without backups. Backups are scheduled 15 seconds after startup loading or a successfully saved scan. Failed or interrupted copies never replace a good backup.'))
        Test-UiRegressionElementVisible $policy
    } 'disclosed backup policy'
    (Find-BackupControl BackupPolicyExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
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
        (Find-BackupControl BackUpNowButton).Current.Name -eq 'Creating backup...' -and
            -not (Find-BackupControl BackUpNowButton).Current.IsEnabled
    } 'indeterminate running backup and disabled manual action'
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-running.png')
    Select-BackupNavigation DevicesNavItem
    Open-BackupPage
    $null = Wait-BackupSurface Empty
    if ((Find-BackupControl BackUpNowButton).Current.Name -ne 'Creating backup...') {
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
    Assert-BackupButtonColor (Join-Path $ScreenshotDirectory 'backups-completed-collapsed.png') success
    $title = (Find-BackupControl CompletedBackupsTitle).Current.BoundingRectangle
    $summary = (Find-BackupControl BackupCount).Current.BoundingRectangle
    $policy = (Find-BackupControl BackupPolicyExpander).Current.BoundingRectangle
    if ([Math]::Abs(($title.Top + $title.Bottom - $summary.Top - $summary.Bottom) / 2) -gt 2 -or
        $summary.Left -lt $title.Right -or $policy.Top -le $title.Bottom -or
        (Find-BackupControl BackupLastSuccess).Current.BoundingRectangle.Top -le $policy.Bottom -or
        -not (Test-UiRegressionElementWithin (Find-BackupControl BackupCount) (Find-BackupControl CompletedBackupsExpander) $script:root)) {
        throw 'Wide automatic-backup section must show title/summary on one row, then policy and last success.'
    }
    Expand-BackupCopies
    $copies = @(Get-ChildItem (Join-Path $fixture 'Backups') -Filter '*.sqlite')
    if ($copies.Count -ne 1 -or
        (Get-InventorySqliteValue $copies[0].FullName 'PRAGMA integrity_check') -ne 'ok') {
        throw 'The displayed completed copy must be independently readable.'
    }

    $phase = Step-UiRegressionPhase $phase 'Backups/error-last-success' -Directory $ScreenshotDirectory
    # Fake time covers both one-minute boundaries; new app sessions exercise the outcomes without desktop delays.
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
        (Find-BackupControl BackUpNowButton).Current.IsEnabled -or
        (Find-BackupControl BackUpNowButton).Current.Name -ne 'Backup failed') {
        throw 'A later failure must keep the last successful copy visible.'
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-error.png')
    Assert-BackupButtonColor (Join-Path $ScreenshotDirectory 'backups-error.png') failure
    Select-BackupNavigation DevicesNavItem
    Open-BackupPage
    $null = Wait-BackupSurface Error
    if ((Find-BackupControl BackUpNowButton).Current.Name -ne 'Backup failed' -or
        (Find-BackupControl BackUpNowButton).Current.IsEnabled) {
        throw 'Navigation must preserve failed manual outcome and cooldown.'
    }
    Remove-Item -LiteralPath $lock
    Stop-UiRegressionApp $script:process
    $script:process.Dispose()
    $script:process = $null
    Start-BackupApp
    Open-BackupPage
    $null = Wait-BackupSurface Ready
    $before = (ConvertFrom-UiRegressionSurfaceStatus (Find-BackupControl BackupsScroll).Current.ItemStatus).Request
    Invoke-BackupControl BackUpNowButton
    $null = Wait-BackupSurface Ready $before
    Expand-BackupCopies
    $daily = @(Wait-UiRegressionState {
        $markers = @($script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'BackupDailyText')))
        if ($markers.Count -eq 2 -and (Test-UiRegressionElementVisible $markers[0]) -and
            (Test-UiRegressionElementVisible $markers[1])) { return $markers }
    } 'two visible completed-backup daily markers')
    if ($daily.Count -ne 2 -or $daily[0].Current.Name -ne 'Yes' -or $daily[1].Current.Name -ne 'No') {
        throw 'Only the newest same-day backup must be marked as the daily recovery point.'
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-expanded-daily.png')
    $created = @($script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'BackupCreatedText')))
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $image = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory 'backups-expanded-daily.png'))
    try {
        $colors = @($created | ForEach-Object {
            $bounds = $_.Current.BoundingRectangle
            $image.GetPixel([int]($bounds.Left - $window.Left - 6 * $scale),
                [int](($bounds.Top + $bounds.Bottom) / 2 - $window.Top)).ToArgb()
        })
        if ($colors.Count -ne 2 -or $colors[0] -eq $colors[1]) {
            throw 'Completed backups must show visible alternating row backgrounds.'
        }
    }
    finally { $image.Dispose() }

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
        Expand-BackupCopies
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
    Show-BackupAction CompletedBackupsExpander
    $title = (Find-BackupControl CompletedBackupsTitle).Current.BoundingRectangle
    $summary = (Find-BackupControl BackupCount).Current.BoundingRectangle
    if ($summary.Top -lt $title.Bottom) {
        throw 'Narrow completed-backup header must stack its summary below the title.'
    }
    Show-BackupAction BackupRows
    foreach ($marker in @($script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'BackupDailyText')))) {
        if (-not (Test-UiRegressionElementWithin $marker (Find-BackupControl BackupsScroll) $script:root)) {
            throw 'Daily column is clipped in the narrow backup table.'
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'backups-narrow-expanded.png')
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
