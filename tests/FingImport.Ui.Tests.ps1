param(
    [Parameter(Mandatory)][string] $AppPath,
    [string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ImportReviewKeyboard
{
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void AllowForeground()
    {
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }
}
"@
$previousReview = $env:FINGVIBE_UI_REVIEW
$previousSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-import-ui-$([Guid]::NewGuid()).json"
$process = $null

function Find-ImportControl([string] $Name, [System.Windows.Automation.ControlType] $Type) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing import control: $Name."
}

function Find-ImportId([string] $Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element) { throw "Missing import automation ID: $Id." }
    return $element
}

function Invoke-ImportControl([string] $Name) {
    (Find-ImportControl $Name ([System.Windows.Automation.ControlType]::Button)).
        GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 350
}

function Select-ImportPage([string] $Name) {
    (Find-ImportControl $Name ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 400
}

function Set-ImportScroll([double] $Percent) {
    (Find-ImportId ImportScroll).GetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, $Percent)
    Start-Sleep -Milliseconds 300
}

try {
    # A nonexistent isolated snapshot plus UI-review mode prevents real inventory/snapshot writes.
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $fixture
    $process = Start-Process -FilePath $AppPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "Import review app exited with code $($process.ExitCode)." }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw "Import review app did not open a window." }
    if ($ScreenshotDirectory) {
        [ImportReviewKeyboard]::AllowForeground()
        Initialize-UiReviewWindow $process.MainWindowHandle
    }
    else {
        $null = [UiReviewNativeWindow]::ShowWindow($process.MainWindowHandle, 9)
        $area = [System.Windows.Forms.Screen]::FromHandle($process.MainWindowHandle).WorkingArea
        if (-not [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero,
                $area.Left, $area.Top, [Math]::Min(1280, $area.Width), [Math]::Min(800, $area.Height), 0x0044)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    Select-ImportPage Tools
    Invoke-ImportControl "Import from Fing"
    $null = Find-ImportControl "Browse Fing export" ([System.Windows.Automation.ControlType]::Button)
    $help = Find-ImportId ExportHelpExpander
    if ($help.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
        throw "Export help must be collapsed by default."
    }
    if ((Find-ImportId AnalysisCountsText).Current.Name -notlike "3 devices in export*3 new*") {
        throw "Synthetic import was not analyzed without local observations."
    }
    $null = Find-ImportControl "Fing import preview" ([System.Windows.Automation.ControlType]::List)
    Set-ImportScroll 100
    $importButton = Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)
    $summaryBounds = (Find-ImportId ImportSummaryText).Current.BoundingRectangle
    if (-not $importButton.Current.IsEnabled -or $importButton.Current.IsOffscreen -or
        $importButton.Current.BoundingRectangle.Left -lt $summaryBounds.Right) {
        throw "Eligible Import must be right-aligned beside the summary, not below it."
    }
    if ($ScreenshotDirectory) {
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "fing-import-ready.png")
    }
    Set-ImportScroll 0
    (Find-ImportControl "Manage rooms →" ([System.Windows.Automation.ControlType]::Hyperlink)).
        GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 400
    $null = Find-ImportControl "Search rooms" ([System.Windows.Automation.ControlType]::Edit)
    Invoke-ImportControl "Add room"
    (Find-ImportControl "Full name" ([System.Windows.Automation.ControlType]::Edit)).
        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Missing review room")
    (Find-ImportControl "Short name" ([System.Windows.Automation.ControlType]::Edit)).
        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("MR")
    Invoke-ImportControl "Save"
    $null = Find-ImportControl "Missing review room" ([System.Windows.Automation.ControlType]::Text)
    Select-ImportPage Tools
    $importButton = Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)
    if ($importButton.Current.IsEnabled) { throw "Returning from management must not authorize a stale analysis." }
    Invoke-ImportControl "Analyze again"
    if ((Find-ImportId WarningsText).Current.Name -like "*Location 'Missing review room' is missing*") {
        throw "Re-analysis must match the room manually created on its management page."
    }
    Set-ImportScroll 100
    Invoke-ImportControl "Import reviewed Fing changes"
    if ((Find-ImportId ImportHeadingText).Current.Name -ne "Import complete" -or
        (Find-ImportId ImportSummaryText).Current.Name -notlike "Imported 3 new devices*All changes saved locally.") {
        throw "The completion report must reflect the committed synthetic inventory."
    }
    if ((Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "The committed preview must not be reusable."
    }
    Select-ImportPage Devices
    if ((Find-ImportId ResultCountText).Current.Name -ne "3 devices" -or
        (Find-ImportId InventoryCountsText).Current.Name -notlike "0 Online*0 Offline*3 Fing Only") {
        throw "Imported-only records must not inflate online counts or disappear from Devices."
    }
    $status = Find-ImportControl "Filter by device status" ([System.Windows.Automation.ControlType]::ComboBox)
    $status.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl "Offline" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    if ((Find-ImportId ResultCountText).Current.Name -ne "0 of 3 devices") {
        throw "Fing Only must not be classified as Offline by filtering."
    }
    Select-ImportPage Tools
    Invoke-ImportControl "Import from Fing"
    Invoke-ImportControl "Analyze again"
    if ((Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "An unchanged export must not enable Import after re-analysis."
    }
    $choice = Find-ImportControl "020000000001:Name" ([System.Windows.Automation.ControlType]::ComboBox)
    $choice.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl "Replace with Fing" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 400
    if (-not (Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "Explicit replacement must refresh the preview and enable the eligible name change."
    }
    Set-ImportScroll 100
    Invoke-ImportControl "Import reviewed Fing changes"
    if ((Find-ImportId ImportSummaryText).Current.Name -notlike "Imported 0 new devices and 1 fields.*") {
        throw "Explicit replacement must apply only the analyzed name change."
    }
    Select-ImportPage Devices
    $status = Find-ImportControl "Filter by device status" ([System.Windows.Automation.ControlType]::ComboBox)
    $status.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl "All statuses" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $search = Find-ImportControl "Search devices" ([System.Windows.Automation.ControlType]::Edit)
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Review custom name")
    Start-Sleep -Milliseconds 250
    if ((Find-ImportId ResultCountText).Current.Name -ne "0 of 3 devices") {
        throw "The reviewed replacement did not remove the prior user name."
    }
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Review workstation")
    Start-Sleep -Milliseconds 250
    if ((Find-ImportId ResultCountText).Current.Name -ne "1 of 3 devices") {
        throw "The reviewed imported name was not displayed."
    }
    Write-Host "Fing import preview, management return, completion, inventory, and status UI checks passed."
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $previousReview
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $previousSnapshot
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
}
