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

function Set-ImportTheme([string] $Theme) {
    Select-ImportPage Settings
    $combo = Find-ImportId ThemePicker
    $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl $Theme ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
    Start-Sleep -Milliseconds 500
    Select-ImportPage Tools
    Invoke-ImportControl "Import from Fing"
}

function Save-ImportFileChip([string] $Name) {
    Set-ImportScroll 0
    $filePath = Join-Path $ScreenshotDirectory "$Name.png"
    Save-UiReviewWindowScreenshot $process.MainWindowHandle $filePath
    $context = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    try {
        $windowBounds = Get-UiReviewWindowBounds $process.MainWindowHandle
        $fileBounds = (Find-ImportId SelectedFileText).Current.BoundingRectangle
        $bitmap = [System.Drawing.Bitmap]::new($filePath)
        try {
            $x = [int]($fileBounds.Left - $windowBounds.Left - 3)
            $y = [int]($fileBounds.Top - $windowBounds.Top - 1)
            if ($fileBounds.IsEmpty -or $x -lt 0 -or $y -lt 0 -or $x -ge $bitmap.Width -or $y -ge $bitmap.Height) {
                throw "The analyzed filename must be inside the captured window."
            }
            $pixel = $bitmap.GetPixel($x, $y)
            if ([int]$pixel.G -le [int]$pixel.R + 20 -or [int]$pixel.G -le [int]$pixel.B + 20) {
                throw "Successfully analyzed filename must have a clearly green background in $Name."
            }
        }
        finally { $bitmap.Dispose() }
    }
    finally { $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($context) }
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
    if ((Find-ImportId SelectedFileText).Current.HelpText -ne "File analyzed successfully.") {
        throw "The filename success chip must reflect successful analysis."
    }
    $null = Find-ImportControl "Fing import preview" ([System.Windows.Automation.ControlType]::List)
    $null = Find-ImportControl "3   Changes and conflicts" ([System.Windows.Automation.ControlType]::Text)
    $null = Find-ImportControl "People — Review" ([System.Windows.Automation.ControlType]::Text)
    $null = Find-ImportControl "Rooms — Review" ([System.Windows.Automation.ControlType]::Text)
    $null = Find-ImportControl "Private/randomized MACs — Information" ([System.Windows.Automation.ControlType]::Text)
    $null = Find-ImportControl "Device type / OS classification — Review" ([System.Windows.Automation.ControlType]::Text)
    foreach ($category in @("People", "Rooms", "Private/randomized MACs", "Device type / OS classification")) {
        $expander = Find-ImportId "AnalysisDetailsExpander-$category"
        $pattern = $expander.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $pattern.Expand()
        Start-Sleep -Milliseconds 250
        $detail = (Find-ImportId "AnalysisDetails-$category").Current.Name
        $expected = if ($category -eq "Rooms") { "Review speaker" }
            elseif ($category -eq "Private/randomized MACs") { "Review speaker (row 3)" }
            else { "Review controller" }
        if (-not $detail.Contains($expected)) {
            throw "$category analysis details must identify the affected device."
        }
        $pattern.Collapse()
        Start-Sleep -Milliseconds 250
    }
    if ((Find-ImportId PrivateMacNotice-020000000001).Current.Name -notlike "*Import all includes every eligible device*") {
        throw "Private-MAC guidance must explain how selection mode skips an unrecognized device."
    }
    $nameRow = Find-ImportId "ImportFields-020000000001-Name"
    $deviceHeader = Find-ImportId "ImportHeader-020000000001"
    $nameValue = Find-ImportId "ImportValue-020000000001:Name"
    if (-not $nameValue.Current.Name.Contains("1$([char]0xFE0F)$([char]0x20E3)")) {
        throw "Imported name rendering must preserve the full emoji sequence."
    }
    $label = $nameRow.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, "Name"))
    if (-not $label -or $label.Current.ControlType -ne [System.Windows.Automation.ControlType]::Text -or $label.Current.IsKeyboardFocusable) {
        throw "Field chips must expose text labels, not buttons or focusable actions."
    }
    foreach ($category in @("people", "rooms")) {
        $button = Find-ImportControl "Manage $category" ([System.Windows.Automation.ControlType]::Button)
        $heading = Find-ImportControl "$((Get-Culture).TextInfo.ToTitleCase($category)) — Review" ([System.Windows.Automation.ControlType]::Text)
        foreach ($step in 0..20) {
            Set-ImportScroll ($step * 5)
            $bounds = $button.Current.BoundingRectangle
            if (-not $button.Current.IsOffscreen -and -not $heading.Current.IsOffscreen -and
                $bounds.Top -gt $root.Current.BoundingRectangle.Top + 180 -and
                $bounds.Bottom -lt $root.Current.BoundingRectangle.Bottom - 30) { break }
        }
        $buttonBounds = $button.Current.BoundingRectangle
        $headingBounds = $heading.Current.BoundingRectangle
        if ($buttonBounds.IsEmpty -or $headingBounds.IsEmpty -or
            $buttonBounds.Left -lt $headingBounds.Right -or
            $buttonBounds.Top -gt $headingBounds.Top -or
            $buttonBounds.Bottom -lt $headingBounds.Bottom) {
            $scrollState = (Find-ImportId ImportScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).Current
            throw "Manage $category must be a button at the right of its card's heading. Button: $buttonBounds; heading: $headingBounds; vertical view: $($scrollState.VerticalViewSize)%."
        }
    }
    foreach ($step in 0..20) {
        Set-ImportScroll ($step * 5)
        $bounds = $nameRow.Current.BoundingRectangle
        if (-not $nameRow.Current.IsOffscreen -and
            -not $deviceHeader.Current.IsOffscreen -and
            $deviceHeader.Current.BoundingRectangle.Top -gt $root.Current.BoundingRectangle.Top + 180 -and
            $bounds.Top -gt $root.Current.BoundingRectangle.Top + 180 -and
            $bounds.Bottom -lt $root.Current.BoundingRectangle.Bottom - 30) { break }
    }
    $labelBounds = $label.Current.BoundingRectangle
    $valueBounds = $nameValue.Current.BoundingRectangle
    $choiceBounds = (Find-ImportControl "020000000001:Name" ([System.Windows.Automation.ControlType]::ComboBox)).Current.BoundingRectangle
    $valueCenter = $valueBounds.Top + $valueBounds.Height / 2
    $headerBounds = $deviceHeader.Current.BoundingRectangle
    $fieldBounds = $nameRow.Current.BoundingRectangle
    $headerGap = $fieldBounds.Top - $headerBounds.Bottom
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($process.MainWindowHandle) / 96.0
    if ($headerBounds.IsEmpty -or $fieldBounds.IsEmpty -or $headerGap -lt 0 -or $headerGap -gt 12 * $scale) {
        throw "The device header and first detail row must have a compact join. Gap: $headerGap."
    }
    if ($labelBounds.IsEmpty -or $valueBounds.IsEmpty -or $choiceBounds.IsEmpty -or
        [Math]::Abs(($labelBounds.Top + $labelBounds.Height / 2) - $valueCenter) -gt 1.5 -or
        [Math]::Abs(($choiceBounds.Top + $choiceBounds.Height / 2) - $valueCenter) -gt 1.5) {
        throw "Field labels, values, and overwrite controls must be vertically center-aligned."
    }
    if ((Find-ImportId LimitationsText).Current.Name -notlike "*Imported IPs are historical*") {
        throw "Import limitations must be an informational note."
    }
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
        foreach ($step in 0..20) {
            Set-ImportScroll ($step * 5)
            $bounds = $nameRow.Current.BoundingRectangle
            if (-not $nameRow.Current.IsOffscreen -and
                $bounds.Top -gt $root.Current.BoundingRectangle.Top + 180 -and
                $bounds.Bottom -lt $root.Current.BoundingRectangle.Bottom - 30) { break }
        }
        $emojiPath = Join-Path $ScreenshotDirectory "fing-import-name-emoji.png"
        Save-UiReviewWindowScreenshot $process.MainWindowHandle $emojiPath
        $context = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
        try {
            $windowBounds = Get-UiReviewWindowBounds $process.MainWindowHandle
            $bounds = $nameRow.Current.BoundingRectangle
            $bitmap = [System.Drawing.Bitmap]::new($emojiPath)
            try {
                $left = [int][Math]::Floor($bounds.Left - $windowBounds.Left)
                $top = [int][Math]::Floor($bounds.Top - $windowBounds.Top)
                $right = $left + [int][Math]::Min(350, $bounds.Width / 2)
                $bottom = [int][Math]::Ceiling($bounds.Bottom - $windowBounds.Top)
                if ($left -lt 0 -or $top -lt 0 -or $right -gt $bitmap.Width -or $bottom -gt $bitmap.Height) {
                    throw "Emoji name row must be fully inside the captured window."
                }
                $coloredPixels = 0
                for ($y = $top; $y -lt $bottom; $y++) {
                    for ($x = $left; $x -lt $right; $x++) {
                        $pixel = $bitmap.GetPixel($x, $y)
                        $channels = @([int]$pixel.R, [int]$pixel.G, [int]$pixel.B) | Measure-Object -Minimum -Maximum
                        if ($channels.Maximum - $channels.Minimum -gt 40) { $coloredPixels++ }
                    }
                }
                if ($coloredPixels -lt 5) { throw "Name emoji rendered monochrome: only $coloredPixels colored pixels in the name region." }
            }
            finally { $bitmap.Dispose() }
        }
        finally { $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($context) }
        Save-ImportFileChip "fing-import-analyzed-file"
        foreach ($theme in @("Standard Light", "Warm Light", "True Black (OLED)")) {
            Set-ImportTheme $theme
            Save-ImportFileChip "fing-import-analyzed-file-$theme"
        }
        Set-ImportTheme "Standard Dark"
    }
    Set-ImportScroll 0
    (Find-ImportControl "Manage rooms" ([System.Windows.Automation.ControlType]::Button)).
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
    if ((Find-ImportId SelectedFileText).Current.HelpText -ne "File analysis is not current.") {
        throw "Invalidated analysis must reset the filename success state."
    }
    $importButton = Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)
    if ($importButton.Current.IsEnabled) { throw "Returning from management must not authorize a stale analysis." }
    Invoke-ImportControl "Analyze again"
    $null = Find-ImportControl "Rooms — OK" ([System.Windows.Automation.ControlType]::Text)
    if ((Find-ImportId AnalysisCountsText).Current.Name -notlike "*2 warnings") {
        throw "Re-analysis must match the room manually created on its management page."
    }
    Invoke-ImportControl "Select devices"
    if ((Find-ImportControl "Import reviewed Fing changes" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "Selection mode must start with no selected devices."
    }
    Invoke-ImportControl "Select all"
    if ((Find-ImportId ImportButton).Current.Name -ne "Import reviewed Fing changes" -or
        -not (Find-ImportId ImportButton).Current.IsEnabled) {
        throw "Select all must enable batch import."
    }
    Invoke-ImportControl "Deselect all"
    if ((Find-ImportId ImportButton).Current.IsEnabled) { throw "Deselect all must disable batch import." }
    Invoke-ImportControl "Cancel selection"
    $pendingChoice = Find-ImportControl "020000000001:Name" ([System.Windows.Automation.ControlType]::ComboBox)
    $pendingChoice.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl "Replace with Fing" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 350
    Invoke-ImportControl "Import device 020000000002"
    if ((Find-ImportId ImportSummaryText).Current.Name -notlike "Imported 1 new devices*") {
        throw "Individual import must save only one device."
    }
    if ((Find-ImportId AnalysisCountsText).Current.Name -notlike "*2 new*") {
        throw "Remaining preview must refresh after an individual import."
    }
    $pendingChoice = Find-ImportControl "020000000001:Name" ([System.Windows.Automation.ControlType]::ComboBox)
    if ($pendingChoice.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name -ne "Replace with Fing") {
        throw "An individual import must preserve another device's pending overwrite decision."
    }
    $pendingChoice.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    (Find-ImportControl "Keep existing" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 350
    Invoke-ImportControl "Select devices"
    (Find-ImportControl "Select 020000000001" ([System.Windows.Automation.ControlType]::CheckBox)).
        GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Start-Sleep -Milliseconds 200
    Set-ImportScroll 100
    Invoke-ImportControl "Import reviewed Fing changes"
    if ((Find-ImportId ImportSummaryText).Current.Name -notlike "Imported 1 new devices*") {
        throw "Selected import must save only the checked device."
    }
    Invoke-ImportControl "Cancel selection"
    Invoke-ImportControl "Import reviewed Fing changes"
    if ((Find-ImportId ImportHeadingText).Current.Name -ne "Import complete" -or
        (Find-ImportId ImportSummaryText).Current.Name -notlike "Imported 1 new devices*All changes saved locally.") {
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
    $area = [System.Windows.Forms.Screen]::FromHandle($process.MainWindowHandle).WorkingArea
    foreach ($width in (@(1024, [Math]::Min(1280, $area.Width)) | Select-Object -Unique)) {
        if (-not [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero,
                $area.Left, $area.Top, $width, [Math]::Min(800, $area.Height), 0x0044)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        Start-Sleep -Milliseconds 350
        $searchBounds = (Find-ImportControl "Search devices" ([System.Windows.Automation.ControlType]::Edit)).Current.BoundingRectangle
        $statusBounds = $status.Current.BoundingRectangle
        if ($searchBounds.IsEmpty -or $statusBounds.IsEmpty -or $status.Current.IsOffscreen -or
            $statusBounds.Left -lt $searchBounds.Right -or
            [Math]::Abs(($statusBounds.Top + $statusBounds.Height / 2) -
                ($searchBounds.Top + $searchBounds.Height / 2)) -gt 1.5) {
            throw "The device status filter must remain aligned directly beside search at width $width. Search: $searchBounds; status: $statusBounds."
        }
        if ($width -eq 1280) {
            $previousBounds = $statusBounds
            foreach ($filter in @(
                (Find-ImportControl "Filter by person" ([System.Windows.Automation.ControlType]::ComboBox)),
                (Find-ImportControl "Filter by room" ([System.Windows.Automation.ControlType]::ComboBox)),
                (Find-ImportControl "With open ports" ([System.Windows.Automation.ControlType]::CheckBox)))) {
                $bounds = $filter.Current.BoundingRectangle
                if ($bounds.IsEmpty -or $filter.Current.IsOffscreen -or $bounds.Left -lt $previousBounds.Right -or
                    [Math]::Abs(($bounds.Top + $bounds.Height / 2) -
                        ($searchBounds.Top + $searchBounds.Height / 2)) -gt 1.5) {
                    throw "All device filters must share the search/status row when the window is wide enough."
                }
                $previousBounds = $bounds
            }
        }
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "fing-import-device-filters.png")
    }
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
    Invoke-ImportControl "Select devices"
    Invoke-ImportControl "Cancel selection"
    $choice = Find-ImportControl "020000000001:Name" ([System.Windows.Automation.ControlType]::ComboBox)
    if ($choice.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name -ne "Replace with Fing") {
        throw "Switching import modes must preserve overwrite choices."
    }
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
