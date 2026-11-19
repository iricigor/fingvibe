param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Device-linking UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath
$null = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path -Parent $AppPath) "FingVibe.Core.dll"))

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LinkReviewAccessibility {
    [StructLayout(LayoutKind.Sequential)] private struct HC { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref HC value, uint flags);
    public static uint GetContrast() {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void SetContrast(uint flags) {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr parameter,
        string setting, uint flags, uint timeout, out UIntPtr result);
    public static void NotifyTextScaleChanged() {
        UIntPtr result;
        if (SendMessageTimeout(new IntPtr(0xffff), 0x001a, UIntPtr.Zero, "Accessibility", 2, 5000, out result) == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

$virtualExplanation = "A virtual device groups changing private MAC addresses automatically, so it can't be linked. You can still name it and assign it to a person or room."
$linkedExplanation = "Linked by you. Edit the shared name, identification, Person, Room and usage category in their own sections."

function Find-Link([string] $Value, [switch] $ByName, [switch] $Optional) {
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $call = Start-UiRegressionCall lookup
    try {
        $condition = [System.Windows.Automation.PropertyCondition]::new($property, $Value)
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $element -and (Show-UiRegressionDeviceTabFor $script:root $Value)) {
            $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        }
    }
    finally { Complete-UiRegressionCall $call }
    if (-not $element -and -not $Optional) { throw "Missing device-linking control '$Value'." }
    return $element
}

function Wait-Link([scriptblock] $Condition, [string] $Description) {
    $call = Start-UiRegressionCall wait
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        do {
            if (& $Condition) { return }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Timed out waiting for $Description."
    }
    finally { Complete-UiRegressionCall $call }
}

function Start-LinkApp {
    $call = Start-UiRegressionCall launch
    try {
        $script:process = Start-Process -FilePath $AppPath -PassThru
        Wait-Link {
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Device-linking app exited: $($script:process.ExitCode)." }
            $script:process.MainWindowHandle -ne [IntPtr]::Zero
        } "app startup"
        Initialize-UiReviewWindow $script:process.MainWindowHandle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
        Wait-Link { Find-Link DevicesNavItem -Optional } "navigation"
    }
    finally { Complete-UiRegressionCall $call }
}

function Stop-LinkApp {
    $call = Start-UiRegressionCall close
    try {
        if ($script:process -and -not $script:process.HasExited) {
            $null = $script:process.CloseMainWindow()
            if (-not $script:process.WaitForExit(5000)) { throw "Device-linking app did not close normally." }
        }
    }
    finally { Complete-UiRegressionCall $call }
}

function Get-LinkRows([string] $Name) {
    $list = Find-Link ResultsList -Optional
    if (-not $list -or $list.Current.IsOffscreen) { return }
    foreach ($row in $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) {
        $cell = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText"))
        if ($cell -and $cell.Current.Name -ceq $Name) { $row }
    }
}

function Show-LinkDevices([string] $Search) {
    $back = Find-Link "Back to devices" -ByName -Optional
    if ($back -and -not $back.Current.IsOffscreen) {
        $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    } else {
        (Find-Link DevicesNavItem).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    Wait-Link { $list = Find-Link ResultsList -Optional; $list -and -not $list.Current.IsOffscreen } "Devices"
    (Find-Link "Search devices" -ByName).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Search)
}

# Opens the only row matching a search (a name or a MAC address) and expects its displayed name.
function Open-LinkDevice([string] $Search, [string] $Name = $Search) {
    Show-LinkDevices $Search
    Wait-Link {
        $list = Find-Link ResultsList -Optional
        $all = if ($list) { @($list.FindAll([System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) } else { @() }
        $all.Count -eq 1 -and @(Get-LinkRows $Name).Count -eq 1
    } "the only '$Name' row for '$Search'"
    $row = @(Get-LinkRows $Name)[0]
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Link { $scroll = Find-Link DeviceDetailsScroll -Optional; $scroll -and -not $scroll.Current.IsOffscreen } "device details"
}

function Show-Link([string] $Id) {
    $call = Start-UiRegressionCall positioning
    try {
        $viewport = Find-Link DeviceDetailsScroll
        $scroll = $viewport.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        foreach ($percent in 0..100) {
            if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
            Start-Sleep -Milliseconds 10
            $control = Find-Link $Id
            $bounds = $control.Current.BoundingRectangle
            $area = $viewport.Current.BoundingRectangle
            $bottom = [Math]::Min($area.Bottom, $script:root.Current.BoundingRectangle.Bottom - 16)
            if (-not $control.Current.IsOffscreen -and $bounds.Height -gt 0 -and
                $bounds.Top -ge $area.Top -and $bounds.Bottom -le $bottom) { return $control }
        }
        throw "Device-linking control '$Id' is clipped or unreachable."
    }
    finally { Complete-UiRegressionCall $call }
}

function Invoke-Link([string] $Id) {
    (Show-Link $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Save-LinkCapture([string] $Name, [string] $Control = "MergeMacAddresses") {
    $null = Show-Link $Control
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

function Get-LinkSection {
    $section = Find-Link MergeMacAddresses -Optional
    if (-not $section) { return $null }
    [pscustomobject]@{
        Header = $section.Current.HelpText
        State = $section.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
        Element = $section
    }
}

function Assert-LinkSection([string] $Header, [string] $State) {
    Wait-Link { $section = Get-LinkSection; $section -and $section.Header -eq $Header } "Merge MAC addresses showing '$Header'"
    $section = Get-LinkSection
    if ($section.State -ne $State) { throw "Merge MAC addresses '$Header' must open $State, not $($section.State)." }
    $identification = (Find-Link "Edit device identification" -ByName).Current.BoundingRectangle
    if ($identification.Top -lt $section.Element.Current.BoundingRectangle.Bottom) {
        throw "Merge MAC addresses must sit directly above Device identification."
    }
}

function Expand-LinkSection {
    $expansion = (Find-Link MergeMacAddresses).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($expansion.Current.ExpandCollapseState -ne "Expanded") { $expansion.Expand() }
}

function Get-LinkPickerItems {
    $list = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "MergeMacPickerList"))
    if (-not $list) { return }
    $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
}

function Open-LinkPicker([string] $Expected) {
    Invoke-Link MergeMacChangeDevice
    Wait-Link { (@(Get-LinkPickerItems).Current.Name -join "|") -like $Expected } "picker items '$Expected'"
    if (-not (Find-Link MergeMacPickerFooter -Optional)) { throw "The picker must explain that virtual devices aren't listed." }
}

function Select-LinkPickerItem([string] $Name) {
    $item = @(Get-LinkPickerItems | Where-Object { $_.Current.Name -like "$Name*" })
    if ($item.Count -ne 1) { throw "Expected one picker item '$Name'; found $($item.Count)." }
    $item[0].SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Link { -not (Find-Link MergeMacPickerList -Optional) } "the picker to close"
}

function Close-LinkPicker {
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Wait-Link { -not (Find-Link MergeMacPickerList -Optional) } "the picker to close"
}

function Select-LinkChoice([string] $Id) {
    (Show-Link $Id).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Link { (Find-Link $Id).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } "choice $Id"
}

function Set-LinkName([string] $Name) {
    (Show-Link MergeMacNameInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
}

function Assert-LinkMerge([bool] $Enabled, [string] $Unresolved) {
    Wait-Link { (Find-Link MergeMacMerge).Current.IsEnabled -eq $Enabled } "Merge as one device enabled=$Enabled"
    if ((Find-Link MergeMacUnresolved).Current.Name -notlike $Unresolved) {
        throw "Unexpected unresolved summary: $((Find-Link MergeMacUnresolved).Current.Name)"
    }
}

function Resolve-LinkDraft {
    Set-LinkName "Link desk"
    Select-LinkChoice MergeMacChoiceDeviceTypeOther
    $person = Show-Link MergeMacChoicePersonThis
    $person.SetFocus()
    # Keyboard: Space selects the focused radio button.
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-Link { (Find-Link MergeMacChoicePersonThis).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } "keyboard person choice"
    Select-LinkChoice MergeMacChoiceRoomOther
    foreach ($field in @("Vendor", "Family", "Model")) {
        $id = "MergeMacChoice${field}Separate"
        $call = Start-UiRegressionCall positioning
        try {
            $choice = Show-UiRegressionScrollTargets -GetViewport { Find-Link DeviceDetailsScroll } `
                -GetTargets { Find-Link $id } -GetWindow { $script:root } `
                -Description "$field Keep separate choice" -BottomMargin 16
        }
        finally { Complete-UiRegressionCall $call }
        $choice.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Wait-Link { (Find-Link $id).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } "$field Keep separate selected"
        $label = if ($field -eq "Vendor") { "Vendor / manufacturer" } else { $field }
        if ((Find-Link "MergeMacResult$field").Current.Name -ne "Linked device ${label}: No shared value") {
            throw "$field must show that no value will be shared."
        }
    }
}

# Keeps this device's value for every difference in the draft.
function Resolve-LinkDraftThis {
    foreach ($field in @("Name", "DeviceType", "OperatingSystem", "Vendor", "Family", "Model", "Icon", "Person", "Room", "UsageCategory")) {
        if (Find-Link "MergeMacChoice${field}This" -Optional) { Select-LinkChoice "MergeMacChoice${field}This" }
    }
    Assert-LinkMerge $true "Every value is chosen*"
}

function Get-SpareMemberCount {
    Get-InventorySqliteValue $database "SELECT json_array_length(data,'$.members') FROM linked_devices WHERE id='$spareId'"
}

# Links made by these checks; the fixture's saved "Link spare" and "Link pair" devices are excluded.
function Get-LinkFilter { "id NOT IN ('$spareId','$pairId')" }
function Get-LinkCount { Get-InventorySqliteValue $database "SELECT COUNT(*) FROM linked_devices WHERE $(Get-LinkFilter)" }

# Possible-match checks (#545/#547) use their own fixture with Match alpha/beta/gamma and two plain records.
function Show-MatchRows {
    Show-LinkDevices "Match "
    Wait-Link { @(Get-MatchRows).Count -eq 3 } "the three synthetic possible-match rows"
    $scroll = (Find-Link TableViewport).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.HorizontallyScrollable) { $scroll.SetScrollPercent(0, -1) }
}

function Get-MatchRows {
    $list = Find-Link ResultsList -Optional
    if (-not $list) { return }
    foreach ($row in $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) {
        $name = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText"))
        if ($name -and $name.Current.Name -like "Match *") { $row }
    }
}

function Find-MatchButton([string] $Name, [switch] $Optional, [switch] $Transient) {
    $row = @(Get-MatchRows | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText")).Current.Name -ceq $Name
    })
    # Rows can be re-realized while focus or the list changes; waits retry instead of failing on that instant.
    if ($row.Count -ne 1 -and $Transient) { return $null }
    if ($row.Count -ne 1) { throw "Expected one '$Name' possible-match row; found $($row.Count)." }
    $button = $row[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceMatchButton"))
    if ($button -and ($button.Current.IsOffscreen -or $button.Current.BoundingRectangle.IsEmpty)) { $button = $null }
    if (-not $button -and -not $Optional) { throw "The '$Name' row has no possible-match icon." }
    return @{ Row = $row[0]; Button = $button }
}

function Assert-MatchButton([string] $Name, [int] $Count) {
    $label = if ($Count -eq 1) { "Review 1 possible matching MAC address" } else { "Review $Count possible matching MAC addresses" }
    Wait-Link { (Find-MatchButton $Name -Optional -Transient).Button.Current.Name -eq $label } "'$Name' icon naming $Count suggestions"
    $button = (Find-MatchButton $Name).Button
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $cell = (Find-MatchButton $Name).Row.Current.BoundingRectangle
    if ($button.Current.BoundingRectangle.Height -gt 24.5 * $scale -or $cell.Height -gt 60 * $scale) {
        throw "The possible-match icon must not change table density."
    }
    return $button
}

function Get-MatchSectionState {
    # The header count TextBlock has no UIA peer inside the Expander header; the page mirrors it in the section HelpText.
    $section = Find-Link MergeMacAddresses -Optional
    $other = Find-Link MergeMacOtherName -Optional
    [pscustomobject]@{
        Count = if ($section) { $section.Current.HelpText } else { "<missing section>" }
        Other = if ($other) { $other.Current.Name } else { "<missing other device>" }
    }
}

function Assert-MatchSection([string] $Count, [string] $Other, [string] $Reason, [string] $Heading) {
    try {
        Wait-Link {
            $state = Get-MatchSectionState
            $state.Count -eq $Count -and $state.Other -eq $Other
        } "Merge MAC addresses showing $Count and $Other"
    }
    catch {
        $state = Get-MatchSectionState
        throw "$($_.Exception.Message) Observed count '$($state.Count)' and other device '$($state.Other)'."
    }
    $expander = Find-Link MergeMacAddresses
    if ($expander.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne "Expanded") {
        throw "Merge MAC addresses must open expanded."
    }
    if ((Find-Link MergeMacReason).Current.Name -notlike "Suggested because $Reason. This does not establish physical identity.") {
        throw "Unexpected suggestion reason: $((Find-Link MergeMacReason).Current.Name)"
    }
    if ((Find-Link MergeMacOtherHeading).Current.Name -ne "Selected other MAC address · suggestion $Heading") {
        throw "Unexpected suggestion position: $((Find-Link MergeMacOtherHeading).Current.Name)"
    }
    # The section reflows after save/error changes; wait for layout to settle before judging its position.
    $script:layout = $null
    try {
        Wait-Link {
            $script:layout = @{
                Summary = (Find-Link DeviceHistoryState).Current.BoundingRectangle
                Identification = (Find-Link "Edit device identification" -ByName).Current.BoundingRectangle
                Section = (Find-Link MergeMacAddresses).Current.BoundingRectangle
            }
            $script:layout.Section.Top -ge $script:layout.Summary.Bottom -and
                $script:layout.Identification.Top -ge $script:layout.Section.Bottom
        } "Merge MAC addresses between the observation summary and Device identification"
    }
    catch {
        throw "Merge MAC addresses must sit after the observation summary and directly above Device identification. Summary=$($script:layout.Summary); section=$($script:layout.Section); identification=$($script:layout.Identification)."
    }
}

function Assert-MatchTooltip($Button, [string[]] $Expected) {
    $helpText = $Button.Current.HelpText
    foreach ($expectedText in $Expected) {
        if ($helpText -notlike "*$expectedText*") {
            throw "The possible-match button must expose '$expectedText' through its accessible hover copy; actual: $helpText"
        }
    }
    $bounds = $Button.Current.BoundingRectangle
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(
        [int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + $bounds.Height / 2))
    try {
        # WinUI ToolTips are transient UIA popup peers on these runners; HelpText and the
        # source-bound ToolTip/handler contract are the stable hover-content assertions.
        Start-Sleep -Milliseconds 600
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "match-row-hover.png")
    }
    finally { [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(0, 0) }
}

function Test-MatchTextScaling {
    # Runs at 200% text scale after the possible-match phase declined Match alpha/beta, so only beta lacks an icon.
    Show-MatchRows
    # Assert-MatchButton's absolute row cap is for 100% text; at 200% density is compared with the icon-free row instead.
    Wait-Link { (Find-MatchButton "Match alpha" -Optional -Transient).Button.Current.Name -eq "Review 1 possible matching MAC address" } `
        "'Match alpha' icon naming 1 suggestion at 200% text scale"
    $alpha = (Find-MatchButton "Match alpha").Button
    if ((Find-MatchButton "Match beta" -Optional).Button) { throw "The declined pair must stay declined at 200% text scale." }
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $iconRow = (Find-MatchButton "Match alpha").Row.Current.BoundingRectangle
    $plainRow = (Find-MatchButton "Match beta" -Optional).Row.Current.BoundingRectangle
    $icon = $alpha.Current.BoundingRectangle
    if ([Math]::Abs($iconRow.Height - $plainRow.Height) -gt $scale) {
        throw "The possible-match icon must not change row density at 200% text scale. Icon row=$iconRow; plain row=$plainRow; scale=$scale."
    }
    if (-not $iconRow.Contains($icon) -or $icon.Width -lt 23.5 * $scale -or $icon.Height -lt 23.5 * $scale) {
        throw "The possible-match icon must stay a whole 24-DIP target at 200% text scale. Row=$iconRow; icon=$icon; scale=$scale."
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "match-icon-text-scale-200.png")
    $alpha.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Assert-MatchSection "1 possible match" "Match gamma" "both records reported the same UPnP device UUID" "1 of 1"
    $window = $script:root.Current.BoundingRectangle
    foreach ($id in @("MergeMacOtherHeading", "MergeMacOtherName", "MergeMacOtherAddresses", "MergeMacReason", "MergeMacDecline")) {
        $control = Show-Link $id
        $bounds = $control.Current.BoundingRectangle
        if ($bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right -or $bounds.Height -lt 24 * $scale) {
            throw "$id must stay readable and unclipped at 200% text scale. Bounds=$bounds; window=$window; scale=$scale."
        }
    }
    $decline = Show-Link MergeMacDecline
    $decline.SetFocus()
    Wait-Link { (Find-Link MergeMacDecline).Current.HasKeyboardFocus } "keyboard focus on Decline suggestion at 200% text scale"
    Save-LinkCapture "match-section-text-scale-200" MergeMacReason
}

function Use-LinkInventory([string] $Path) {
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $Path
    $script:database = [IO.Path]::ChangeExtension($Path, ".sqlite")
}

function Find-LinkChevron([string] $Name = "Link desk") {
    $row = @(Get-LinkRows $Name)
    if ($row.Count -ne 1) { return $null }
    $row[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceMacExpansionButton"))
}

function Find-LinkedLine([string] $Pattern) {
    $row = @(Get-LinkRows "Link desk")
    if ($row.Count -ne 1) { return $null }
    @($row[0].FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceMacExpansionLabel")) |
        Where-Object { $_.Current.Name -like $Pattern -and -not $_.Current.IsOffscreen })[0]
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-link-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixture "inventory.json"
$database = [IO.Path]::ChangeExtension($inventory, ".sqlite")
$snapshot = Join-Path $fixture "snapshot.json"
$previous = @{}
$script:process = $null
$lock = $null
$contrast = $null
$scaleKey = $null
$originalScale = $null
$originalKind = $null
$phase = $null
$failed = $false
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "linking/fixture" $ScreenshotDirectory
    $time = [DateTimeOffset]::UtcNow.AddDays(-1)
    $person = [Guid]::NewGuid().ToString()
    $room = [Guid]::NewGuid().ToString()
    function New-LinkObservation([string] $Address, [string] $Vendor, [bool] $Present = $false, [object[]] $Reported = @()) {
        @{
            networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = $Address
            hostname = $null; vendor = $Vendor; ports = @(); latency = 1; probeDuration = "00:00:00.001"
            classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Fixture"; operatingSystemEvidence = "Fixture" }
            firstSeen = $time.ToString("o"); lastSeen = $time.AddMinutes(11).ToString("o")
            lastChecked = $time.AddMinutes(13).ToString("o"); present = $Present
            reportedValues = @($Reported | ForEach-Object { @{ kind = $_[0]; value = $_[1]; lastReceivedAt = $time.AddMinutes(11).ToString("o") } })
        }
    }
    # Synthetic records: Wi-Fi, dock and declined share a UPnP UUID (kind 4); plain has no evidence; two private MACs form a virtual device.
    $uuid = @(, @(4, "uuid-link-fixture"))
    $spareUuid = @(, @(4, "uuid-spare-fixture"))
    $oldPrivate = New-LinkObservation "127.0.0.7" "Private"
    $currentPrivate = New-LinkObservation "127.0.0.8" "Private" $true
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "001122BB0001" = @{ mac = "001122BB0001"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.2" "Example" -Reported $uuid) }
            "001122BB0002" = @{ mac = "001122BB0002"; imported = @{ brand = "Board vendor"; family = "Motherboard"; model = "Board model" }; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.3" "Example" -Reported $uuid) }
            "001122BB0003" = @{ mac = "001122BB0003"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.4" "Example" -Reported $uuid) }
            "001122BB0004" = @{ mac = "001122BB0004"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.5" "Example") }
            "D0C9070000A1" = @{ mac = "D0C9070000A1"; imported = @{}; scanHistory = @(); observations = @($oldPrivate) }
            "D0C9070000A2" = @{ mac = "D0C9070000A2"; imported = @{}; scanHistory = @(); observations = @($currentPrivate) }
            # #582: "Link spare" and "Link pair" are saved linked devices; Spare candidate shares a UPnP UUID with spare A.
            "001122BB0005" = @{ mac = "001122BB0005"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.11" "Example" -Reported $spareUuid) }
            "001122BB0006" = @{ mac = "001122BB0006"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.12" "Example") }
            "001122BB0007" = @{ mac = "001122BB0007"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.13" "Example" -Reported $spareUuid) }
            "001122BB0008" = @{ mac = "001122BB0008"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.14" "Example") }
            "001122BB0009" = @{ mac = "001122BB0009"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.15" "Example") }
        }
        names = @{ "001122BB0001" = "Link desk Wi-Fi"; "001122BB0002" = "Link desk dock"; "001122BB0003" = "Link declined"; "001122BB0004" = "Link plain"
            "001122BB0005" = "Link spare A"; "001122BB0006" = "Link spare B"; "001122BB0007" = "Spare candidate"
            "001122BB0008" = "Link pair A"; "001122BB0009" = "Link pair B" }
        classifications = @{ "001122BB0001" = @{ type = 1; brand = "Wi-Fi vendor"; family = "Adapter"; model = "Wi-Fi model" }; "001122BB0002" = @{ type = 2 } }
        peopleRooms = @{
            people = @(@{ id = $person; name = "Link person"; shortName = "LP" })
            rooms = @(@{ id = $room; name = "Link room"; shortName = "LR" })
            assignments = @{ "001122BB0001" = @{ personId = $person }; "001122BB0002" = @{ roomId = $room } }
        }
        virtualDevices = @(@{
            id = [Guid]::NewGuid().ToString(); networkId = "ui-review-network"; subnet = "127.0.0.1/32"
            prefix = "D0C907"; number = 1; lastActiveMac = "D0C9070000A2"; lastChecked = $time.AddMinutes(13).ToString("o")
            present = $true; name = "Link virtual"; scanHistory = @()
            history = @(@{ mac = "D0C9070000A1"; observation = $oldPrivate; inferred = $true },
                @{ mac = "D0C9070000A2"; observation = $currentPrivate; inferred = $true })
        })
        discoveryBaselines = @()
    }
    @{ version = 4; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding utf8
    # Saved linked devices are created through the store, as the app saves them.
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new($inventory)
    $loaded = $store.LoadMetadataAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
    function New-LinkChoices([string] $Name) {
        $none = [NullString]::Value
        [FingVibe.Core.Models.LinkedDeviceChoices]::new($Name,
            [FingVibe.Core.Models.DeviceClassificationOverride]::new($null, $null, $null, $none, $none, $none), $null, $null)
    }
    $linkedFixture = $loaded.LinkDevices("001122BB0005", "001122BB0006", (New-LinkChoices "Link spare"), $time)
    $linkedFixture = $linkedFixture.LinkDevices("001122BB0008", "001122BB0009", (New-LinkChoices "Link pair"), $time.AddMinutes(1))
    $saved = $store.SaveAsync($linkedFixture, $loaded.Revision, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $spareId = $saved.FindLinkedDevice("001122BB0005").Id.ToString("D")
    $pairId = $saved.FindLinkedDevice("001122BB0008").Id.ToString("D")
    $store = $null
    # Possible matches: alpha and gamma share a UPnP UUID (kind 4); alpha and beta share an mDNS/NetBIOS name (kinds 1, 2).
    $matchData = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "001122AA0001" = @{ mac = "001122AA0001"; imported = @{}; scanHistory = @()
                observations = @(New-LinkObservation "127.0.0.2" "Example" -Reported @(@(1, "kitchen-display.local"), @(4, "uuid-match-fixture"))) }
            "001122AA0002" = @{ mac = "001122AA0002"; imported = @{}; scanHistory = @()
                observations = @(New-LinkObservation "127.0.0.3" "Example" -Reported @(, @(2, "KITCHEN-DISPLAY"))) }
            "001122AA0003" = @{ mac = "001122AA0003"; imported = @{}; scanHistory = @()
                observations = @(New-LinkObservation "127.0.0.4" "Example" -Reported @(, @(4, "uuid-match-fixture"))) }
            "001122334455" = @{ mac = "001122334455"; imported = @{}; scanHistory = @(); observations = @(New-LinkObservation "127.0.0.5" "Example") }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "Other imported" }; observations = @(); scanHistory = @() }
        }
        names = @{ "001122334455" = "Other plain"; "001122AA0001" = "Match alpha"; "001122AA0002" = "Match beta"; "001122AA0003" = "Match gamma" }
        classifications = @{}
        peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @(); discoveryBaselines = @()
    }
    $matchInventory = Join-Path $fixture "match-inventory.json"
    @{ version = 4; data = $matchData } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $matchInventory -Encoding utf8
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = $time.AddMinutes(13).ToString("o"); results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding utf8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"

    $phase = Step-UiRegressionPhase $phase "linking/section-states" $ScreenshotDirectory
    Start-LinkApp
    Open-LinkDevice "Link plain"
    Assert-LinkSection "No suggestions" "Collapsed"
    Save-LinkCapture "link-no-suggestions"
    Expand-LinkSection
    Wait-Link { (Find-Link MergeMacChangeDevice -Optional).Current.Name -eq "Choose device" } "Choose device..."
    Open-LinkPicker "Other devices|Link declined*|Link desk dock*|Link desk Wi-Fi*"
    if (@(Get-LinkPickerItems).Current.Name -match "Link virtual|Suggested") { throw "The picker must exclude virtual devices and empty groups." }
    (Find-Link MergeMacPickerSearch).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("dock")
    Wait-Link { (@(Get-LinkPickerItems).Current.Name -join "|") -like "Other devices|Link desk dock*" } "search to find only the dock"
    Close-LinkPicker
    Open-LinkDevice "Link virtual"
    Assert-LinkSection "Not available for virtual devices" "Collapsed"
    Expand-LinkSection
    Wait-Link { (Find-Link MergeMacExplanation -Optional).Current.Name -eq $virtualExplanation } "the virtual-device explanation"
    if (Find-Link MergeMacChangeDevice -Optional) { throw "Virtual devices must not offer linking." }
    Save-LinkCapture "link-virtual-unavailable" MergeMacExplanation

    # #583: a saved linked device's History card lists every member with its confirmation and restored values.
    $phase = Step-UiRegressionPhase $phase "linking/history-card" $ScreenshotDirectory
    Open-LinkDevice "Link pair"
    Wait-Link { (Find-Link VirtualDeviceHistoryTitle -Optional).Current.Name -eq "Linked device" } "the linked-device history card"
    $memberHistory = (Find-Link "MAC and address history" -ByName).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($memberHistory.Current.ExpandCollapseState -ne "Expanded") { $memberHistory.Expand() }
    Wait-Link {
        $text = (Find-Link VirtualDeviceHistory -Optional).Current.Name
        $text -like "00-11-22-BB-00-0? · Confirmed by you on *" -and $text -like "*00-11-22-BB-00-08 · Confirmed by you on *" -and
            $text -like "*00-11-22-BB-00-09 · Confirmed by you on *" -and $text -like "*127.0.0.14 · Previous connection*" -and
            $text -like "*Saved values Unlink restores: name Link pair A,*" -and $text -like "*Saved values Unlink restores: name Link pair B,*" -and
            $text -notlike "*Inferred*"
    } "every linked member in MAC and address history"

    $phase = Step-UiRegressionPhase $phase "linking/compare-cancel" $ScreenshotDirectory
    Open-LinkDevice "Link desk Wi-Fi"
    Assert-LinkSection "2 possible matches" "Expanded"
    Wait-Link { (Find-Link MergeMacOtherHeading).Current.Name -eq "Selected other MAC address · suggestion 1 of 2" } "first suggestion"
    Open-LinkPicker "Suggested|Link desk dock*Same device ID*|Link declined*Same device ID*|Other devices|Link pair*2 MAC addresses|Link plain*"
    Select-LinkPickerItem "Link declined"
    Wait-Link { (Find-Link MergeMacOtherName).Current.Name -eq "Link declined" } "the second suggestion"
    Invoke-Link MergeMacDecline
    Assert-LinkSection "1 possible match" "Expanded"
    Wait-Link { (Find-Link MergeMacOtherName).Current.Name -eq "Link desk dock" } "the remaining suggestion"
    Open-LinkPicker "Suggested|Link desk dock*|Other devices|Link declined*Declined|Link pair*2 MAC addresses|Link plain*"
    Close-LinkPicker
    Assert-LinkMerge $false "7 differences need a choice*"
    foreach ($id in @("MergeMacChoiceNameThis", "MergeMacChoiceNameOther", "MergeMacChoiceDeviceTypeThis", "MergeMacChoiceDeviceTypeOther",
        "MergeMacChoicePersonThis", "MergeMacChoiceRoomOther", "MergeMacNameInput", "MergeMacSeparateRecords")) {
        $null = Find-Link $id
    }
    if (Find-Link MergeMacChoiceOperatingSystemThis -Optional) { throw "Matching values must not ask for a choice." }
    if ((Find-Link MergeMacResultDeviceType).Current.Name -ne "Linked device Device type: Choose a value") {
        throw "Unresolved values must say they need a choice: $((Find-Link MergeMacResultDeviceType).Current.Name)"
    }
    Select-LinkChoice MergeMacChoiceVendorSeparate
    Select-LinkChoice MergeMacChoiceVendorOther
    if ((Find-Link MergeMacChoiceVendorSeparate).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected -or
        (Find-Link MergeMacResultVendor).Current.Name -ne "Linked device Vendor / manufacturer: Board vendor") {
        throw "Choosing a source must replace Keep separate in the same radio group."
    }
    Save-LinkCapture "link-comparison-unresolved" MergeMacUnresolved
    Resolve-LinkDraft
    Assert-LinkMerge $true "Every value is chosen*"
    if ((Find-Link MergeMacResultRoom).Current.Name -ne "Linked device Room: Link room") { throw "The chosen room must be the linked value." }
    Invoke-Link MergeMacCancel
    Assert-LinkMerge $false "7 differences need a choice*"
    if ((Find-Link MergeMacNameInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) {
        throw "Cancel must discard the typed name."
    }
    if ((Get-LinkCount) -ne 0) { throw "Cancel must not save a linked device." }

    $phase = Step-UiRegressionPhase $phase "linking/failed-save-merge" $ScreenshotDirectory
    Resolve-LinkDraft
    $lock = [IO.FileStream]::new("$inventory.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Invoke-Link MergeMacMerge
    Wait-Link { Find-Link MergeMacError -Optional } "visible link failure"
    Assert-LinkSection "1 possible match" "Expanded"
    Assert-LinkMerge $true "Every value is chosen*"
    if ((Find-Link MergeMacNameInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "Link desk") {
        throw "A failed save must keep the draft."
    }
    if ((Get-LinkCount) -ne 0) { throw "A failed save must not link the devices." }
    Save-LinkCapture "link-save-error" MergeMacError
    $lock.Dispose()
    $lock = $null
    Invoke-Link MergeMacMerge
    # The dock still shares a UPnP UUID with "Link declined" (only the Wi-Fi pair was declined), so the new linked
    # device opens with a mixed header and that suggestion selected.
    Assert-LinkSection "2 MAC addresses · 1 possible match" "Expanded"
    Wait-Link { (Find-Link MergeMacExplanation -Optional).Current.Name -eq $linkedExplanation } "the linked explanation"
    Wait-Link { (Find-Link MergeMacOtherName -Optional).Current.Name -eq "Link declined" } "the linked device's suggestion"
    if ((Find-Link MergeMacOtherHeading).Current.Name -ne "Selected other MAC address · suggestion 1 of 1" -or
        (Find-Link MergeMacChangeDevice).Current.Name -ne "Change device") {
        throw "A linked device's suggestion must be reviewed like any other."
    }
    Save-LinkCapture "link-linked-mixed-header" MergeMacReason
    $memberText = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $members = @((Find-Link MergeMacAddresses).FindAll([System.Windows.Automation.TreeScope]::Descendants, $memberText) |
        Where-Object { $_.Current.Name -like "00-11-22-BB-00-0? · 127.0.0.? · Example · Offline · linked *" })
    if ($members.Count -ne 2 -or $members[0].Current.Name -notlike "00-11-22-BB-00-01 · 127.0.0.2 *· Shown in Devices" -or
        $members[1].Current.Name -like "*Shown in Devices") {
        throw "The linked section must list each MAC with its IP, adapter vendor, status and date linked: $($members.Current.Name -join ' | ')"
    }
    if (Find-Link MergeMacError -Optional) { throw "A successful link must clear the previous error." }
    foreach ($id in @("MergeMacUnlink001122BB0001", "MergeMacUnlink001122BB0002")) {
        if ((Show-Link $id).Current.Name -notlike "Unlink 00-11-22-BB-00-0?") {
            throw "Each linked MAC must have an accessible Unlink action: $id"
        }
    }
    # Declining it for the linked device records the pair for every member; only Add MAC address... remains.
    Invoke-Link MergeMacDecline
    Assert-LinkSection "2 MAC addresses" "Expanded"
    Wait-Link { (Find-Link MergeMacChangeDevice -Optional).Current.Name -eq "Add MAC address" } "Add MAC address..."
    if (Find-Link MergeMacMerge -Optional) { throw "A linked device without a chosen record must not offer Merge." }
    if ((Get-InventorySqliteValue $database "SELECT group_concat(id) FROM declined_matches") -ne "001122BB0001|001122BB0003,001122BB0002|001122BB0003") {
        throw "Declining a linked device's suggestion must decline every current pair."
    }
    if ((Get-LinkCount) -ne 1 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.name') FROM linked_devices WHERE $(Get-LinkFilter)") -ne "Link desk" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.identification.type') FROM linked_devices WHERE $(Get-LinkFilter)") -ne 2 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$') FROM names WHERE id='001122BB0001'") -ne "Link desk Wi-Fi" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.type') FROM classifications WHERE id='001122BB0001'") -ne 1) {
        throw "Linking must save shared values atomically and keep each member's own values."
    }
    if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM linked_devices WHERE $(Get-LinkFilter) AND json_extract(data,'$.identification.brand') IS NULL AND json_extract(data,'$.identification.family') IS NULL AND json_extract(data,'$.identification.model') IS NULL") -ne 1) {
        throw "Keep separate must persist no shared vendor, family or model."
    }
    Save-LinkCapture "link-linked" MergeMacExplanation

    $phase = Step-UiRegressionPhase $phase "linking/one-row" $ScreenshotDirectory
    # Eight rows (five records, two saved linked devices and one virtual device) become seven: the new pair counts once.
    Show-LinkDevices "Link desk"
    Wait-Link { @(Get-LinkRows "Link desk").Count -eq 1 -and (Find-Link "Showing 1 of 7 devices" -ByName -Optional) } `
        "one linked-device row counted once"
    $chevron = Find-LinkChevron
    if ($chevron.Current.Name -ne "Show 1 more MAC address") { throw "Unexpected chevron name: $($chevron.Current.Name)" }
    $chevron.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-Link { Find-LinkedLine "Linked MAC address: 00-11-22-BB-00-02, 127.0.0.3, Example, Offline*" } "the linked MAC line"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "link-one-row-expanded.png")
    Show-LinkDevices "127.0.0.3"
    Wait-Link { @(Get-LinkRows "Link desk").Count -eq 1 -and (Find-LinkedLine "Linked MAC address: 00-11-22-BB-00-02*") } `
        "search by a member IP finding and expanding the row"
    if ((Find-LinkChevron).Current.IsEnabled) { throw "A search match must keep the row expanded." }
    Show-LinkDevices ""
    Wait-Link { Find-Link "Showing 7 devices" -ByName -Optional } "the unfiltered total counting the linked device once"

    $phase = Step-UiRegressionPhase $phase "linking/shared-edit-restart" $ScreenshotDirectory
    Open-LinkDevice "00-11-22-BB-00-02" "Link desk"
    Assert-LinkSection "2 MAC addresses" "Collapsed"
    Invoke-Link UsageCategoryEdit
    $null = Show-Link UsageCategoryPicker
    Set-UiReviewAppearanceChoice -Root $script:root -Picker UsageCategoryPicker -Choice Guest
    Invoke-Link UsageCategorySave
    Wait-Link { (Find-Link UsageCategoryEffective).Current.Name -like "Guest | Manual override*" } "shared Guest category"
    Stop-LinkApp
    Start-LinkApp
    Open-LinkDevice "00-11-22-BB-00-01" "Link desk"
    Assert-LinkSection "2 MAC addresses" "Collapsed"
    Invoke-Link DeviceClassificationEditButton
    foreach ($field in @("Brand", "Family", "Model")) {
        $input = Show-Link "Device${field}Input"
        if ($input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) {
            throw "Unshared $field must remain blank after restart, without member fallback."
        }
    }
    Invoke-Link DeviceClassificationCancelButton
    $null = Show-Link UsageCategoryEffective
    Wait-Link { (Find-Link UsageCategoryEffective).Current.Name -like "Guest | Manual override*" } "the shared category on the other member after restart"
    if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM devices WHERE id='001122BB0002' AND json_extract(data,'$.usageCategoryOverride') IS NOT NULL") -ne 0) {
        throw "Shared edits must not overwrite a member's own usage category."
    }

    $phase = Step-UiRegressionPhase $phase "linking/high-contrast" $ScreenshotDirectory
    $contrast = [LinkReviewAccessibility]::GetContrast()
    [LinkReviewAccessibility]::SetContrast($contrast -bor 1)
    Start-Sleep -Seconds 2
    if (([LinkReviewAccessibility]::GetContrast() -band 1) -eq 0) { throw "High contrast did not activate." }
    Expand-LinkSection
    Save-LinkCapture "link-linked-high-contrast" MergeMacExplanation
    Open-LinkDevice "Link plain"
    Assert-LinkSection "No suggestions" "Collapsed"
    Save-LinkCapture "link-no-suggestions-high-contrast"
    [LinkReviewAccessibility]::SetContrast($contrast)
    $contrast = $null
    Start-Sleep -Seconds 1

    $phase = Step-UiRegressionPhase $phase "linking/match-suggestions" $ScreenshotDirectory
    Stop-LinkApp
    Use-LinkInventory $matchInventory
    Start-LinkApp
    Open-LinkDevice "Other plain"
    Assert-LinkSection "No suggestions" "Collapsed"
    Show-MatchRows
    $alpha = Assert-MatchButton "Match alpha" 2
    $null = Assert-MatchButton "Match gamma" 1
    $beta = Assert-MatchButton "Match beta" 1
    $help = $alpha.Current.HelpText
    $strongest = $help.IndexOf("Match gamma (127.0.0.4). Same device ID (UPnP device UUID).")
    if ($strongest -lt 0 -or $help.IndexOf("Match beta (127.0.0.3). Same discovered name.") -lt $strongest) {
        throw "Row explanations must name each counterpart and reason, strongest first: $help"
    }
    Assert-MatchTooltip $beta @("Possible matching MAC address: Match alpha (127.0.0.2). Same discovered name.",
        "Click to review in Device Details.")
    (Find-MatchButton "Match beta").Row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
    Wait-Link { (Find-MatchButton "Match beta" -Optional -Transient).Button.Current.HasKeyboardFocus } "keyboard focus on the possible-match icon"
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Assert-MatchSection "1 possible match" "Match alpha" "the discovered names match" "1 of 1"
    $section = (Find-Link MergeMacAddresses).Current
    $viewport = (Find-Link DeviceDetailsScroll).Current.BoundingRectangle
    if ($section.IsOffscreen -or $section.BoundingRectangle.Top -lt $viewport.Top -or $section.BoundingRectangle.Top -ge $viewport.Bottom) {
        throw "Opening a suggestion from Devices must bring Merge MAC addresses into view."
    }
    if (-not (Find-Link MergeMacChangeDevice -Optional)) { throw "Change device... must stay available to choose another device." }
    Save-LinkCapture "match-section-single" MergeMacReason
    Show-MatchRows
    (Assert-MatchButton "Match alpha" 2).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Assert-MatchSection "2 possible matches" "Match gamma" "both records reported the same UPnP device UUID" "1 of 2"
    Open-LinkPicker "Suggested|Match gamma*Same device ID*|Match beta*Same discovered name*|Other devices|Other imported*|Other plain*"
    Select-LinkPickerItem "Match beta"
    Wait-Link { (Find-Link MergeMacOtherHeading).Current.Name -like "*suggestion 2 of 2" } "the second suggestion"
    Save-LinkCapture "match-section-change-device" MergeMacReason
    $expansion = (Find-Link MergeMacAddresses).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expansion.Collapse()
    Invoke-Link UsageCategoryEdit
    $null = Show-Link UsageCategoryPicker
    Set-UiReviewAppearanceChoice -Root $script:root -Picker UsageCategoryPicker -Choice Personal
    Invoke-Link UsageCategorySave
    Wait-Link { (Find-Link UsageCategoryEffective).Current.Name -like "Personal | Manual override*" } "a saved category refreshing the page"
    Start-Sleep -Milliseconds 300
    $expansion = (Find-Link MergeMacAddresses).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($expansion.Current.ExpandCollapseState -ne "Collapsed") { throw "A refresh must not reopen a collapsed section." }
    $expansion.Expand()
    Wait-Link { (Find-Link MergeMacOtherHeading).Current.Name -like "*suggestion 2 of 2" } "the retained second suggestion"
    $lock = [IO.FileStream]::new("$matchInventory.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Invoke-Link MergeMacDecline
    Wait-Link { Find-Link MergeMacError -Optional } "visible decline failure"
    $state = Get-MatchSectionState
    if ($state.Count -ne "2 possible matches" -or $state.Other -ne "Match beta") { throw "A failed decline must keep the suggestion." }
    Save-LinkCapture "match-decline-error" MergeMacError
    $lock.Dispose()
    $lock = $null
    Invoke-Link MergeMacDecline
    Assert-MatchSection "1 possible match" "Match gamma" "both records reported the same UPnP device UUID" "1 of 1"
    if (Find-Link MergeMacError -Optional) { throw "A successful decline must clear the previous error." }
    if ((Get-InventorySqliteValue $database "SELECT group_concat(id) FROM declined_matches") -ne "001122AA0001|001122AA0002") {
        throw "The declined pair must be saved in the inventory."
    }
    Show-MatchRows
    $null = Assert-MatchButton "Match alpha" 1
    $null = Assert-MatchButton "Match gamma" 1
    if ((Find-MatchButton "Match beta" -Optional).Button) { throw "Declining must remove the icon from both records." }
    Stop-LinkApp
    Start-LinkApp
    Show-MatchRows
    $null = Assert-MatchButton "Match alpha" 1
    if ((Find-MatchButton "Match beta" -Optional).Button) { throw "A declined pair must stay declined after restart." }
    Open-LinkDevice "Match gamma"
    Assert-MatchSection "1 possible match" "Match alpha" "both records reported the same UPnP device UUID" "1 of 1"
    $contrast = [LinkReviewAccessibility]::GetContrast()
    [LinkReviewAccessibility]::SetContrast($contrast -bor 1)
    Start-Sleep -Seconds 2
    if (([LinkReviewAccessibility]::GetContrast() -band 1) -eq 0) { throw "High contrast did not activate." }
    Save-LinkCapture "match-section-high-contrast" MergeMacReason
    Show-MatchRows
    $null = Assert-MatchButton "Match alpha" 1
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "match-icon-high-contrast.png")
    [LinkReviewAccessibility]::SetContrast($contrast)
    $contrast = $null
    Start-Sleep -Seconds 1

    $phase = Step-UiRegressionPhase $phase "linking/text-scaling" $ScreenshotDirectory
    $appDirectory = Split-Path -Parent $AppPath
    Add-Type -Path (Join-Path $appDirectory 'WinRT.Runtime.dll')
    Add-Type -Path (Join-Path $appDirectory 'Microsoft.Windows.SDK.NET.dll')
    $settings = [Windows.UI.ViewManagement.UISettings]::new()
    $originalFactor = $settings.TextScaleFactor
    $scaleKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $originalScale = $scaleKey.GetValue('TextScaleFactor', $null)
    $originalKind = if ($null -ne $originalScale) { $scaleKey.GetValueKind('TextScaleFactor') } else { $null }
    Stop-LinkApp
    $scaleKey.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
    [LinkReviewAccessibility]::NotifyTextScaleChanged()
    Wait-Link { [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01 } "effective Windows text scale of 200 percent"
    Start-LinkApp
    Test-MatchTextScaling
    Stop-LinkApp
    Use-LinkInventory $inventory
    Start-LinkApp
    Open-LinkDevice "Link plain"
    Expand-LinkSection
    Open-LinkPicker "Other devices|Link declined*"
    Select-LinkPickerItem "Link declined"
    Wait-Link { (Find-Link MergeMacOtherHeading).Current.Name -eq "Selected other MAC address · chosen manually" } "a manual choice"
    if (Find-Link MergeMacReason -Optional) { throw "A manually chosen device must omit the suggestion reason." }
    if (Find-Link MergeMacDecline -Optional) { throw "Only suggestions can be declined." }
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $window = $script:root.Current.BoundingRectangle
    foreach ($id in @("MergeMacChoiceNameThis", "MergeMacChoiceNameOther", "MergeMacChoiceVendorSeparate", "MergeMacNameInput", "MergeMacMerge", "MergeMacCancel")) {
        $bounds = (Show-Link $id).Current.BoundingRectangle
        if ($bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right -or $bounds.Height -lt 16 * $scale) {
            throw "$id must stay readable and unclipped at 200% text scale. Bounds=$bounds; window=$window; scale=$scale."
        }
    }
    $separate = Show-Link MergeMacChoiceVendorSeparate
    $separate.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-Link { (Find-Link MergeMacChoiceVendorSeparate).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } "keyboard Keep separate choice at 200% text scale"
    Save-LinkCapture "link-comparison-text-scale-200" MergeMacMerge
    $cancel = Show-Link MergeMacCancel
    $cancel.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-Link { (Find-Link MergeMacChangeDevice -Optional).Current.Name -eq "Choose device" } "Cancel to clear the manual choice"
    if ((Get-LinkCount) -ne 1) { throw "Cancel must not change saved links." }

    $phase = Step-UiRegressionPhase $phase "linking/unlink-failed-save-and-success" $ScreenshotDirectory
    Open-LinkDevice "00-11-22-BB-00-01" "Link desk"
    Expand-LinkSection
    Invoke-Link MergeMacUnlink001122BB0002
    Wait-Link { (Find-Link MergeMacUnlinkPrompt -Optional).Current.Name -like "Unlink 00-11-22-BB-00-02?*shared edits stay with the remaining device*" } "the inline unlink confirmation"
    if ((Show-Link MergeMacUnlinkConfirm).Current.Name -ne "Unlink" -or
        (Show-Link MergeMacUnlinkCancel).Current.Name -ne "Cancel unlink") {
        throw "The inline unlink confirmation must expose clear Unlink and Cancel actions."
    }
    $cancelUnlink = Show-Link MergeMacUnlinkCancel
    $cancelUnlink.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-Link { -not (Find-Link MergeMacUnlinkConfirmation -Optional) } "keyboard Cancel to keep the link"
    if ((Get-LinkCount) -ne 1) { throw "Cancel unlink must not remove the linked device." }

    Invoke-Link MergeMacUnlink001122BB0002
    Wait-Link { Find-Link MergeMacUnlinkConfirmation -Optional } "the unlink confirmation again"
    $lock = [IO.FileStream]::new("$inventory.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Invoke-Link MergeMacUnlinkConfirm
    Wait-Link { Find-Link MergeMacError -Optional } "visible unlink failure"
    if ((Get-LinkCount) -ne 1 -or -not (Find-Link MergeMacUnlinkConfirmation -Optional)) {
        throw "A failed unlink save must keep both the link and its confirmation."
    }
    Save-LinkCapture "unlink-save-error" MergeMacError
    $lock.Dispose()
    $lock = $null
    Invoke-Link MergeMacUnlinkConfirm
    Assert-LinkSection "No suggestions" "Expanded"
    Wait-Link { -not (Find-Link MergeMacUnlinkConfirmation -Optional) -and (Get-LinkCount) -eq 0 } "the link to be removed"

    if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM declined_matches") -ne 3 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$') FROM names WHERE id='001122BB0001'") -ne "Link desk" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$') FROM names WHERE id='001122BB0002'") -ne "Link desk dock" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.type') FROM classifications WHERE id='001122BB0001'") -ne 2 -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM classifications WHERE id='001122BB0002' AND json_extract(data,'$.type')=2") -ne 1 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.usageCategoryOverride') FROM devices WHERE id='001122BB0001'") -ne 3 -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM devices WHERE id='001122BB0002' AND json_extract(data,'$.usageCategoryOverride') IS NOT NULL") -ne 0 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.personId') FROM assignments WHERE id='001122BB0001'") -ne $person -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.roomId') FROM assignments WHERE id='001122BB0001'") -ne $room -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM assignments WHERE id='001122BB0002' AND json_extract(data,'$.personId') IS NOT NULL") -ne 0 -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.roomId') FROM assignments WHERE id='001122BB0002'") -ne $room) {
        throw "Unlink must atomically transfer shared values to the remaining MAC and preserve the detached MAC values."
    }
    if ((Get-InventorySqliteValue $database "SELECT json_extract(data,'$.brand') FROM classifications WHERE id='001122BB0001'") -ne "Wi-Fi vendor" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.family') FROM classifications WHERE id='001122BB0001'") -ne "Adapter" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.model') FROM classifications WHERE id='001122BB0001'") -ne "Wi-Fi model" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.imported.brand') FROM devices WHERE id='001122BB0002'") -ne "Board vendor") {
        throw "Unlink must preserve each NIC's unshared identification."
    }
    Save-LinkCapture "link-unlinked" MergeMacAddresses
    Show-LinkDevices "Link desk"
    Wait-Link {
        @(Get-LinkRows "Link desk").Count -eq 1 -and @(Get-LinkRows "Link desk dock").Count -eq 1
    } "separate member rows after unlink"
    Stop-LinkApp
    Start-LinkApp
    Open-LinkDevice "00-11-22-BB-00-02" "Link desk dock"
    # The dock's pair with "Link declined" was declined for the whole linked device, so it has no suggestions.
    Assert-LinkSection "No suggestions" "Collapsed"
    if ((Get-LinkCount) -ne 0) { throw "The unlinked state must survive restart." }
    Open-LinkDevice "00-11-22-BB-00-01" "Link desk"
    Assert-LinkSection "No suggestions" "Collapsed"

    $phase = Step-UiRegressionPhase $phase "linking/add-combine-unlink" $ScreenshotDirectory
    $pairLinkedAt = Get-InventorySqliteValue $database "SELECT json_extract(data,'$.members[0].linkedAt') FROM linked_devices WHERE id='$pairId'"
    Open-LinkDevice "Link spare"
    Assert-LinkSection "2 MAC addresses · 1 possible match" "Expanded"
    Wait-Link { (Find-Link MergeMacOtherName -Optional).Current.Name -eq "Spare candidate" } "the record suggested to the linked device"
    if ((Find-Link MergeMacReason).Current.Name -notlike "Suggested because both records reported the same UPnP device UUID.*") {
        throw "A linked device's suggestion must give the member's reason: $((Find-Link MergeMacReason).Current.Name)"
    }
    Save-LinkCapture "link-mixed-header" MergeMacReason
    Resolve-LinkDraftThis
    Invoke-Link MergeMacCancel
    Assert-LinkMerge $false "*a choice before merging."
    if ((Get-SpareMemberCount) -ne 2) { throw "Cancel must not add the record." }
    Resolve-LinkDraftThis
    $lock = [IO.FileStream]::new("$inventory.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Invoke-Link MergeMacMerge
    Wait-Link { Find-Link MergeMacError -Optional } "visible add failure"
    Assert-LinkMerge $true "Every value is chosen*"
    if ((Get-SpareMemberCount) -ne 2) { throw "A failed save must not add the record." }
    $lock.Dispose()
    $lock = $null
    Invoke-Link MergeMacMerge
    Assert-LinkSection "3 MAC addresses" "Expanded"
    Wait-Link { (Find-Link MergeMacChangeDevice -Optional).Current.Name -eq "Add MAC address" } "Add MAC address... after adding a record"
    if ((Get-SpareMemberCount) -ne 3) { throw "Adding a record must keep the linked device's identity." }
    Save-LinkCapture "link-three-macs" MergeMacChangeDevice

    # Choosing a linked device adds all of its MACs; the open device's identity and every linked date survive.
    Open-LinkPicker "Other devices|*Link pair*2 MAC addresses*"
    if (@(Get-LinkPickerItems).Current.Name -match "Link spare|Spare candidate") {
        throw "The picker must not offer the linked device's own MAC addresses."
    }
    Select-LinkPickerItem "Link pair"
    Wait-Link {
        (Find-Link MergeMacOtherHeading -Optional).Current.Name -eq "Selected other MAC address · chosen manually" -and
            (Find-Link MergeMacOtherName).Current.Name -eq "Link pair"
    } "the chosen linked device"
    Resolve-LinkDraftThis
    Assert-LinkMerge $true "Every value is chosen*"
    Invoke-Link MergeMacMerge
    Assert-LinkSection "5 MAC addresses" "Expanded"
    if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM linked_devices") -ne 1 -or (Get-SpareMemberCount) -ne 5 -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM linked_devices, json_each(linked_devices.data,'$.members') WHERE linked_devices.id='$spareId' AND json_extract(json_each.value,'$.linkedAt')='$pairLinkedAt'") -ne 2) {
        throw "Combining must keep the open linked device and every member's linked date."
    }
    Show-LinkDevices "Link "
    Wait-Link { @(Get-LinkRows "Link spare").Count -eq 1 -and @(Get-LinkRows "Link pair").Count -eq 0 } "one row for the combined device"
    if ((Find-LinkChevron "Link spare").Current.Name -ne "Show 4 more MAC addresses") { throw "The combined row must list its other MACs." }

    Open-LinkDevice "Link spare"
    Expand-LinkSection
    Invoke-Link MergeMacUnlink001122BB0009
    Wait-Link {
        (Find-Link MergeMacUnlinkPrompt -Optional).Current.Name -like "Unlink 00-11-22-BB-00-09?*shared edits stay with the linked device and its other MAC addresses*"
    } "the larger-device unlink confirmation"
    Invoke-Link MergeMacUnlinkConfirm
    Assert-LinkSection "4 MAC addresses" "Expanded"
    if ((Get-SpareMemberCount) -ne 4 -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM declined_matches WHERE id LIKE '%001122BB0009%'") -ne 4) {
        throw "Unlinking from a larger device must keep it and decline the MAC against every remaining member."
    }
    Save-LinkCapture "link-unlinked-from-five" MergeMacAddresses
    Show-LinkDevices "Link pair B"
    Wait-Link { @(Get-LinkRows "Link pair B").Count -eq 1 } "the detached MAC's own row and name"
    $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
    Write-Host "Device linking, shared editing, group suggestions, adding, combining and unlinking with Cancel, failure retention, keyboard, restart, high contrast and text scaling passed."
}
catch {
    $failed = $true
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "linking-failure.png") }
        catch { Write-Warning "Could not capture linking failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $false } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name "DeviceLinking.Ui" },
        { if ($lock) { $lock.Dispose() } },
        { if ($null -ne $contrast) { [LinkReviewAccessibility]::SetContrast($contrast) } },
        { if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id } },
        {
            if ($scaleKey) {
                if ($null -eq $originalScale) { $scaleKey.DeleteValue('TextScaleFactor', $false) }
                else { $scaleKey.SetValue('TextScaleFactor', $originalScale, $originalKind) }
                [LinkReviewAccessibility]::NotifyTextScaleChanged()
                $scaleKey.Dispose()
            }
        },
        {
            foreach ($key in $previous.Keys) {
                if ([string]::IsNullOrEmpty($previous[$key])) { Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
            }
        },
        { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    )
}
