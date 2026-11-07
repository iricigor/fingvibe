param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "SQL editor UI checks require a disposable GitHub-hosted desktop."
}
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

function Find-SqlControl([string] $Id, [switch] $Optional) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -and -not $Optional) { throw "Missing SQL editor control '$Id'." }
    return $element
}

function Wait-SqlState([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Wait-SqlControl([string] $Id, [switch] $Visible, [switch] $Enabled, [int] $Seconds = 10) {
    Wait-SqlState {
        $control = Find-SqlControl $Id -Optional
        $control -and (-not $Visible -or -not $control.Current.IsOffscreen) -and
            (-not $Enabled -or $control.Current.IsEnabled)
    } "SQL control '$Id' readiness" $Seconds
}

function Invoke-SqlControl([string] $Id) {
    (Find-SqlControl $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-SqlTools {
    (Find-SqlControl ToolsNavItem).GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-SqlControl SqlEditorCard -Visible -Enabled
    Invoke-SqlControl SqlEditorCard
    Wait-SqlControl SqlText -Visible -Enabled
}

function Start-SqlQuery([string] $Sql) {
    (Find-SqlControl SqlText).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue($Sql)
    Invoke-SqlControl RunButton
}

function Assert-SqlResult([string] $Pattern) {
    Wait-SqlState {
        $status = Find-SqlControl QueryStatus -Optional
        $run = Find-SqlControl RunButton -Optional
        $status -and $run -and $status.Current.Name -like $Pattern -and $run.Current.IsEnabled
    } "SQL result '$Pattern'"
}

function Save-SqlCapture([string] $Name, [double] $Scroll = 0) {
    $pattern = (Find-SqlControl SqlPageScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($pattern.Current.VerticallyScrollable) { $pattern.SetScrollPercent(-1, $Scroll) }
    Start-Sleep -Milliseconds 200
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

$previous = @{}
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-sql-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixtureDirectory "inventory.json"
$database = [IO.Path]::ChangeExtension($inventory, ".sqlite")
$script:process = $null
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    @{
        version = 4
        data = @{
            revision = [Guid]::NewGuid().ToString()
            devices = @{
                "001122334455" = @{
                    mac = "001122334455"; imported = @{ name = "Synthetic SQL device"; model = "Review model" }
                    observations = @(); scanHistory = @()
                }
            }
            names = @{}; classifications = @{}
            peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
            virtualDevices = @(); discoveryBaselines = @()
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $inventory -Encoding utf8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixtureDirectory "unused-snapshot.json"
    $script:process = Start-Process -FilePath $AppPath -PassThru
    Wait-SqlState {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "SQL editor app exited: $($script:process.ExitCode)." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    } "SQL editor app window" 30
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    Wait-SqlState { (Test-Path -LiteralPath $database) -and (Find-SqlControl ToolsNavItem -Optional) } "fixture migration"
    Start-Sleep -Milliseconds 500
    $fingerprint = Get-InventoryFingerprint $database
    Select-SqlTools

    Start-SqlQuery "SELECT imported_name, imported_model, imported_os FROM r_devices;"
    Assert-SqlResult "1 row, 3 columns;*Complete."
    foreach ($column in @("imported_name", "imported_model", "imported_os")) {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $column)
        Wait-SqlState {
            $results = Find-SqlControl ResultScroll -Optional
            $results -and $results.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        } "result header '$column' preserving the returned SQL column name"
    }
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Synthetic SQL device")
    Wait-SqlState {
        $rows = Find-SqlControl ResultRows -Optional
        $rows -and $rows.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
    } "persisted synthetic inventory rendered in the result table"
    Save-SqlCapture "sql-results" 25
    Save-SqlCapture "sql-editor"

    Start-SqlQuery "DELETE FROM devices;"
    Assert-SqlResult "Error*not authorized*"
    Save-SqlCapture "sql-readonly-error"
    Start-SqlQuery "SELECT missing_column FROM r_devices;"
    Assert-SqlResult "Error*no such column*"
    Start-SqlQuery "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1001) SELECT i FROM n;"
    Assert-SqlResult "1,000 rows, 1 column;*Truncated*"
    Save-SqlCapture "sql-row-limit" 25
    Start-SqlQuery "SELECT zeroblob(600000) AS oversized;"
    Assert-SqlResult "0 rows, 1 column;*1 MiB*"
    Start-SqlQuery "SELECT hex(zeroblob(3000)) AS long_value;"
    Assert-SqlResult "1 row, 1 column;*Cell previews are limited*"

    $expensive = "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n) SELECT sum(i) FROM n;"
    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    Invoke-SqlControl CancelButton
    Assert-SqlResult "Cancelled*"
    Save-SqlCapture "sql-cancelled"
    Start-SqlQuery $expensive
    Assert-SqlResult "Error*5-second execution limit*"

    (Find-SqlControl SchemaExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Wait-SqlState {
        $columns = Find-SqlControl SchemaColumns -Optional
        $columns -and $columns.Current.Name.Contains("device_id")
    } "schema browser reporting columns"
    $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
        0, 0, 640, 800, 0x0044)
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    Save-SqlCapture "sql-narrow-schema" 100
    Save-SqlCapture "sql-narrow-editor"
    foreach ($id in @("SqlText", "RunButton", "CancelButton")) {
        $bounds = (Find-SqlControl $id).Current.BoundingRectangle
        $window = $script:root.Current.BoundingRectangle
        if ($bounds.IsEmpty -or $bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right) {
            throw "Required SQL control '$id' is horizontally clipped at narrow width."
        }
    }
    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    (Find-SqlControl OverviewNavItem).GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    Select-SqlTools
    Assert-SqlResult "Cancelled*"
    if ((Get-InventoryFingerprint $database) -cne $fingerprint) { throw "Queries changed the persisted fixture." }

    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $null = $script:process.CloseMainWindow()
    if (-not $script:process.WaitForExit(3000)) { throw "Window close did not cancel SQL promptly." }
    if ((Get-InventoryFingerprint $database) -cne $fingerprint) { throw "Window close changed the persisted fixture." }
    Write-Host "SQL editor native results/errors/limits/schema/narrow layout/cancellation/lifecycle passed ($($clock.ElapsedMilliseconds) ms close)."
}
finally {
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
