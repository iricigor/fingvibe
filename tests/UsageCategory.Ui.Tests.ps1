param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Usage-category UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class UsageReviewContrast {
    [StructLayout(LayoutKind.Sequential)] private struct HC { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref HC value, uint flags);
    public static uint Get() {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void Set(uint flags) {
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

function Find-Usage([string] $Value, [switch] $ByName, [switch] $Optional) {
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $call = Start-UiRegressionCall lookup
    try {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new($property, $Value))
        if (-not $element -and (Show-UiRegressionDeviceTabFor $script:root $Value)) {
            $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new($property, $Value))
        }
        if (-not $element -and $Value -in @("UsageCategoryEvidence", "UsageCategoryWindow", "UsageCategoryRefresh", "UsageCategorySampling")) {
            $details = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "UsageCategoryDetails"))
            if ($details) {
                $details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
                $element = Wait-UiRegressionState -Description "disclosed usage control '$Value'" -Condition {
                    $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.PropertyCondition]::new($property, $Value))
                }
            }
        }
    }
    finally { Complete-UiRegressionCall $call }
    if (-not $element -and -not $Optional) { throw "Missing usage-category control '$Value'." }
    return $element
}

function Wait-Usage([scriptblock] $Condition, [string] $Description) {
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

function Start-UsageApp {
    $call = Start-UiRegressionCall launch
    try {
        $script:process = Start-Process -FilePath $AppPath -PassThru
        Wait-Usage {
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Usage-category app exited: $($script:process.ExitCode)." }
            $script:process.MainWindowHandle -ne [IntPtr]::Zero
        } "app startup"
        Initialize-UiReviewWindow $script:process.MainWindowHandle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
        Wait-Usage { Find-Usage DevicesNavItem -Optional } "navigation"
    }
    finally { Complete-UiRegressionCall $call }
}

function Stop-UsageApp {
    $call = Start-UiRegressionCall close
    try {
        if ($script:process -and -not $script:process.HasExited) {
            $null = $script:process.CloseMainWindow()
            if (-not $script:process.WaitForExit(5000)) { throw "Usage-category app did not close normally." }
        }
    }
    finally { Complete-UiRegressionCall $call }
}

function Find-UsageRow([string] $Name) {
    $list = Find-Usage ResultsList -Optional
    if (-not $list -or $list.Current.IsOffscreen) { return $null }
    $rows = $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
    if ($rows.Count -ne 1) { return $null }
    $cell = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText"))
    if ($cell -and $cell.Current.Name -ceq $Name) { return $rows[0] }
    return $null
}

function Find-UsageIndicator($Cell) {
    # The decorative icon is raw-only; FindFirst excludes it from the control view.
    $call = Start-UiRegressionCall lookup
    try {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceUsageCategoryIndicator")
        $walker = [System.Windows.Automation.TreeWalker]::new($condition)
        return $walker.GetFirstChild($Cell)
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-UsageCell([string] $Name, [string] $Category, [bool] $Indicator, [switch] $Narrow,
    [switch] $Scaled, [string] $Capture) {
    (Find-Usage DevicesNavItem).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Usage {
        $list = Find-Usage ResultsList -Optional
        $list -and -not $list.Current.IsOffscreen
    } "Devices table"
    (Find-Usage "Search devices" -ByName).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
    Wait-Usage { Find-UsageRow $Name } "the '$Name' row for its usage badge"
    $viewport = Find-Usage TableViewport
    $scroll = $viewport.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.HorizontallyScrollable) { $scroll.SetScrollPercent(100, -1) }
    Wait-Usage {
        $cell = Find-Usage UsageCategoryCell -Optional
        $cell -and -not $cell.Current.IsOffscreen -and $cell.Current.Name -like "Usage category: $Category.*"
    } "visible $Category badge"
    $cell = Find-Usage UsageCategoryCell
    $text = Find-Usage DeviceUsageCategoryText
    $icon = Find-UsageIndicator $cell
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96.0
    $maximumHeight = if ($Scaled) { 48 } else { 24 }
    $area = $cell.Current.BoundingRectangle
    $label = $text.Current.BoundingRectangle
    $hasIcon = $icon -and -not $icon.Current.IsOffscreen -and $icon.Current.BoundingRectangle.Width -gt 0
    if ($text.Current.Name -ne $Category -or [bool]$hasIcon -ne $Indicator -or
        [Math]::Abs($area.Width / $scale - 138) -gt 1 -or $area.Height / $scale -gt $maximumHeight -or
        -not $area.Contains($label)) {
        throw "The $Category badge must fit the 150-DIP default with its expected indicator and unchanged one-line height. Text='$($text.Current.Name)'; expectedIndicator=$Indicator; actualIndicator=$([bool]$hasIcon); cell=$area; text=$label; scale=$scale; maximumHeight=$maximumHeight."
    }
    if ($Scaled -and $label.Height / $scale -lt 24) {
        throw "The badge must honor the actual Windows text scale rather than disabling scaling."
    }
    $header = (Find-Usage UsageCategorySortButton).Current.BoundingRectangle
    if ([Math]::Abs($header.Width - $area.Width) -gt $scale) { throw "Usage header and cell widths must stay aligned. Header=$header; cell=$area; scale=$scale." }
    if ($Indicator) {
        $indicatorBounds = $icon.Current.BoundingRectangle
        $gap = ($indicatorBounds.Left - $label.Right) / $scale
        if (-not $area.Contains($indicatorBounds) -or $gap -lt 12 -or $gap -gt 14 -or
            [Math]::Abs(($indicatorBounds.Top + $indicatorBounds.Height / 2) -
                ($label.Top + $label.Height / 2)) -gt $scale) {
            throw "The usage indicator must be immediately outside its badge and vertically centered. Cell=$area; text=$label; icon=$indicatorBounds; gap=$gap; scale=$scale."
        }
    }
    if ($Capture) { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture.png") }
    if ($Narrow) {
        $grip = Find-Usage "Resize Usage category column" -ByName
        $grip.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait("{LEFT 11}")
        Wait-Usage { [Math]::Abs((Find-Usage UsageCategoryCell).Current.BoundingRectangle.Width / $scale - 50) -le 1 } "62-DIP manual usage width"
        $cell = Find-Usage UsageCategoryCell
        $text = Find-Usage DeviceUsageCategoryText
        if (-not $cell.Current.BoundingRectangle.Contains($text.Current.BoundingRectangle)) {
            throw "The badge text must trim inside a manually narrowed column."
        }
        $icon = Find-UsageIndicator $cell
        if ($Indicator -and (-not $icon -or $icon.Current.IsOffscreen -or
            -not $cell.Current.BoundingRectangle.Contains($icon.Current.BoundingRectangle))) {
            throw "Narrowing the column must retain its indicator beside the trimmed badge."
        }
        if ($Capture) {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-narrow.png")
        }
    }
    $cell.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Usage { Find-Usage UsageCategoryCellDetailsText -Optional } "keyboard-opened usage explanation"
    if ((Find-Usage UsageCategoryCellDetailsText).Current.Name -ne $cell.Current.HelpText -or
        $cell.Current.HelpText -notlike "*Usage estimates depend on when scans run*") {
        throw "Every badge, even without an icon or when trimmed, must expose its complete accessible explanation."
    }
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    if ($Narrow) {
        $grip = Find-Usage "Resize Usage category column" -ByName
        $grip.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait("{RIGHT 11}")
        Wait-Usage { [Math]::Abs((Find-Usage UsageCategoryCell).Current.BoundingRectangle.Width / $scale - 138) -le 1 } "restored 150-DIP usage width"
    }
    Open-UsageDevice $Name
}

function Test-UsageTextScaling {
    $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
    $originalScale = $settings.TextScaleFactor
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $originalValue = $key.GetValue('TextScaleFactor', $null)
    $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
    $failed = $true
    try {
        Stop-UsageApp
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [UsageReviewContrast]::NotifyTextScaleChanged()
        Wait-Usage { [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01 } "effective Windows text scale of 200 percent"
        Start-UsageApp
        Assert-UsageCell "Concurrent name" Permanent $true -Narrow -Scaled -Capture "usage-badge-text-scale-200"
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
            { Stop-UsageApp },
            {
                if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                [UsageReviewContrast]::NotifyTextScaleChanged()
                Wait-Usage { [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01 } "restored Windows text scale"
            },
            { $key.Dispose() }
        )
    }
}

function Find-UsageSettings {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $item = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($item -and -not $item.Current.IsOffscreen) { return $item }
    return $null
}

function Select-UsageSettings {
    # A resize returns before XAML lays out again, and the navigation pane stays collapsed until it does.
    Wait-Usage { Find-UsageSettings } "the Settings navigation item"
    $item = Find-UsageSettings
    if (-not $item) { throw "The Settings navigation item disappeared before it could be selected." }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Usage {
        $picker = Find-Usage ModePicker -Optional
        $picker -and -not $picker.Current.IsOffscreen
    } "Settings"
}

function Open-UsageDevice([string] $Name = "Usage laptop") {
    $back = Find-Usage "Back to devices" -ByName -Optional
    if ($back -and -not $back.Current.IsOffscreen) {
        $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    } else {
        (Find-Usage DevicesNavItem).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    Wait-Usage {
        $list = Find-Usage ResultsList -Optional
        $list -and -not $list.Current.IsOffscreen
    } "Devices"
    (Find-Usage "Search devices" -ByName).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
    # The result count can still describe the previous filter, and every filter change rebuilds the rows.
    Wait-Usage { Find-UsageRow $Name } "the only '$Name' device row"
    $row = Find-UsageRow $Name
    if (-not $row) { throw "The '$Name' device row disappeared before it could be opened." }
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Usage {
        $scroll = Find-Usage DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "device details"
}

function Show-Usage([string] $Id) {
    $call = Start-UiRegressionCall positioning
    try {
        $viewport = Find-Usage DeviceDetailsScroll
        $scroll = $viewport.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        foreach ($percent in 0..100) {
            if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
            Start-Sleep -Milliseconds 10
            $control = Find-Usage $Id
            $bounds = $control.Current.BoundingRectangle
            $area = $viewport.Current.BoundingRectangle
            # The scroll viewer's automation bounds can extend past the physical window frame.
            $bottom = [Math]::Min($area.Bottom, $script:root.Current.BoundingRectangle.Bottom - 16)
            if (-not $control.Current.IsOffscreen -and $bounds.Height -gt 0 -and
                $bounds.Top -ge $area.Top -and $bounds.Bottom -le $bottom) { return $control }
        }
        throw "Usage control '$Id' is clipped or unreachable."
    }
    finally { Complete-UiRegressionCall $call }
}

function Choose-Usage([string] $Choice) {
    if (-not (Find-Usage UsageCategoryPicker -Optional)) { Invoke-Usage UsageCategoryEdit }
    $null = Show-Usage UsageCategoryPicker
    Set-UiReviewAppearanceChoice -Root $script:root -Picker UsageCategoryPicker -Choice $Choice
}

function Invoke-Usage([string] $Id) {
    (Show-Usage $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Assert-Usage([string] $Category, [string] $Source) {
    $null = Show-Usage UsageCategoryEffective
    try {
        Wait-Usage { (Find-Usage UsageCategoryEffective).Current.Name -like "$Category | $Source*" } "$Category / $Source"
    }
    catch {
        $effective = (Find-Usage UsageCategoryEffective).Current.Name
        $evidence = (Find-Usage UsageCategoryEvidence).Current.Name
        throw "Expected $Category / $Source; actual effective='$effective'; evidence='$evidence'. $($_.Exception.Message)"
    }
}

function Save-UsageCapture([string] $Name, [string] $Control = "UsageCategoryEffective") {
    $null = Show-Usage $Control
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

function Write-UsageSql([string] $Sql) {
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try { $command.CommandText = $Sql; $null = $command.ExecuteNonQuery() }
        finally { $command.Dispose() }
    } finally { $connection.Dispose() }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-usage-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixture "inventory.json"
$database = [IO.Path]::ChangeExtension($inventory, ".sqlite")
$snapshot = Join-Path $fixture "snapshot.json"
$previous = @{}
$script:process = $null
$lock = $null
$contrast = $null
$phase = $null
$failed = $false
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "usage/fixture" $ScreenshotDirectory
    $time = [DateTimeOffset]::UtcNow.AddDays(-1)
    $person = [Guid]::NewGuid().ToString()
    $room = [Guid]::NewGuid().ToString()
    $observation = @{
        networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = "127.0.0.1"
        hostname = "usage-laptop"; vendor = "Example"; ports = @(); latency = 1; probeDuration = "00:00:00.001"
        classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Fixture"; operatingSystemEvidence = "Fixture" }
        firstSeen = $time.ToString("o"); lastSeen = $time.AddMinutes(11).ToString("o")
        lastChecked = $time.AddMinutes(13).ToString("o"); present = $false
    }
    $history = @(0..13 | ForEach-Object {
        @{ completedAt = $time.AddMinutes($_).ToString("o"); networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = ($_ -lt 12) }
    })
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "001122334455" = @{ mac = "001122334455"; imported = @{}; observations = @($observation); scanHistory = $history }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "Usage imported" }; observations = @(); scanHistory = @() }
        }
        names = @{ "001122334455" = "Usage laptop" }; classifications = @{}
        peopleRooms = @{
            people = @(@{ id = $person; name = "Fixture person"; shortName = "FP" })
            rooms = @(@{ id = $room; name = "Fixture room"; shortName = "FR" })
            assignments = @{ "001122334455" = @{ personId = $person; roomId = $room } }
        }
        virtualDevices = @(); discoveryBaselines = @()
    }
    @{ version = 4; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding utf8
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = $time.AddMinutes(13).ToString("o"); results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding utf8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    # Earlier checks in the same PowerShell 7 process can leave this variable defined but empty, which the app would read as the network id.
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $phase = Step-UiRegressionPhase $phase "usage/save-cancel-failure" $ScreenshotDirectory
    Start-UsageApp
    Assert-UsageCell "Usage laptop" Permanent $true -Narrow -Capture "usage-provisional-badge"
    if (Find-Usage UsageCategoryPicker -Optional) { throw "Read mode must not expose the category editor." }
    Assert-Usage Permanent "Auto - limited evidence"
    if ((Find-Usage UsageCategoryEvidence).Current.Name -notlike "*12 of 14 eligible scans responded (86%)*") {
        throw "The native editor must expose exact F1 evidence and rounded display."
    }
    Save-UsageCapture "usage-automatic"
    Choose-Usage Personal
    Save-UsageCapture "usage-unsaved" UsageCategorySave
    Invoke-Usage UsageCategoryCancel
    Assert-Usage Permanent "Auto"
    Choose-Usage Personal
    $lock = [IO.FileStream]::new("$inventory.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Invoke-Usage UsageCategorySave
    Wait-Usage { (Find-Usage UsageCategorySave).Current.Name -eq "Retry save" } "retained failed-save draft"
    Assert-Usage Permanent "Auto"
    Save-UsageCapture "usage-save-error" UsageCategoryError
    $lock.Dispose()
    $lock = $null
    Invoke-Usage UsageCategorySave
    Assert-Usage Personal "Manual override"
    Choose-Usage Unclassified
    Invoke-Usage UsageCategorySave
    Assert-Usage Unclassified "Manual override"
    Assert-UsageCell "Usage laptop" Unclassified $true -Capture "usage-manual-unclassified-badge"
    Choose-Usage Personal
    Invoke-Usage UsageCategorySave
    Assert-Usage Personal "Manual override"
    Stop-UsageApp
    $phase = Step-UiRegressionPhase $phase "usage/restart-conflict" $ScreenshotDirectory
    Start-UsageApp
    Open-UsageDevice
    Assert-Usage Personal "Manual override"
    Choose-Usage Guest
    Write-UsageSql "UPDATE names SET data='`"Concurrent name`"' WHERE id='001122334455'; UPDATE inventory SET revision='$([Guid]::NewGuid())';"
    Invoke-Usage UsageCategorySave
    Wait-Usage { (Find-Usage UsageCategoryEditStatus).Current.Name -like "Reload the saved category*" } "concurrent edit rejection"
    if ((Find-Usage UsageCategorySave).Current.IsEnabled) { throw "Conflict must require reload, not blind retry." }
    Save-UsageCapture "usage-concurrent-conflict" UsageCategoryError
    Invoke-Usage UsageCategoryReload
    Wait-Usage { -not (Find-Usage UsageCategoryPicker -Optional) } "completed conflict reload returning to read mode"
    Assert-Usage Personal "Manual override"
    Choose-Usage Automatic
    Invoke-Usage UsageCategorySave
    Assert-Usage Permanent "Auto"
    if ((Get-InventorySqliteValue $database "SELECT json_extract(data,'$') FROM names WHERE id='001122334455'") -ne "Concurrent name" -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.personId') FROM assignments WHERE id='001122334455'") -ne $person -or
        (Get-InventorySqliteValue $database "SELECT json_extract(data,'$.roomId') FROM assignments WHERE id='001122334455'") -ne $room -or
        (Get-InventorySqliteValue $database "SELECT COUNT(*) FROM scan_history") -ne 14) {
        throw "Category edits changed unrelated metadata or history."
    }
    $phase = Step-UiRegressionPhase $phase "usage/evidence-unavailable" $ScreenshotDirectory
    Write-UsageSql "UPDATE inventory SET revision='$([Guid]::NewGuid())';"
    Invoke-Usage UsageCategoryRefresh
    Wait-Usage { (Find-Usage UsageCategoryEffective).Current.Name -like "*Unavailable*could not be loaded*" } "stale-evidence error"
    if ((Find-Usage UsageCategoryEvidence).Current.Name -like "*12 of 14*") { throw "Failed refresh must not present old inference as current." }
    Save-UsageCapture "usage-evidence-error" UsageCategoryEffective
    Stop-UsageApp
    Start-UsageApp
    Open-UsageDevice "Concurrent name"
    Choose-Usage Personal
    Assert-Usage Permanent "Auto"
    Open-UsageDevice "Usage imported"
    Assert-Usage Unclassified "Auto - no eligible scans"
    Assert-UsageCell "Usage imported" Unclassified $false -Narrow -Capture "usage-unclassified-badge"
    if ((Find-Usage UsageCategoryEvidence).Current.Name -match '%') { throw "No evidence must not fabricate a percentage." }
    Save-UsageCapture "usage-no-evidence"
    $phase = Step-UiRegressionPhase $phase "usage/themes-narrow" $ScreenshotDirectory
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        Select-UsageSettings
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Assert-UsageCell "Concurrent name" Permanent $true -Capture "usage-badge-$($theme.Replace(' ', '-'))"
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        foreach ($width in @($bounds.Width, 640)) {
            if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
                $bounds.Left, $bounds.Top, $width, $bounds.Height, 0x0044)) { throw "Unable to resize the category review window." }
            Start-Sleep -Milliseconds 300
            Choose-Usage Personal
            foreach ($id in @("UsageCategoryPicker", "UsageCategorySave", "UsageCategoryCancel", "UsageCategoryRefresh")) {
                $control = Show-Usage $id
                $area = $script:root.Current.BoundingRectangle
                if (-not $area.Contains($control.Current.BoundingRectangle)) { throw "$id is clipped." }
            }
            Save-UsageCapture "usage-$($theme.Replace(' ', '-'))-$width" UsageCategorySave
            Invoke-Usage UsageCategoryCancel
        }
        $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height, 0x0044)
    }
    $phase = Step-UiRegressionPhase $phase "usage/high-contrast-keyboard" $ScreenshotDirectory
    $contrast = [UsageReviewContrast]::Get()
    [UsageReviewContrast]::Set($contrast -bor 1)
    Start-Sleep -Seconds 2
    if (([UsageReviewContrast]::Get() -band 1) -eq 0) { throw "High contrast did not activate." }
    Choose-Usage Personal
    Save-UsageCapture "usage-high-contrast" UsageCategorySave
    $picker = Show-Usage UsageCategoryPicker
    $picker.SetFocus()
    # On a closed ComboBox the arrow keys change the selection immediately, while Enter would only open its list.
    [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DOWN}{DOWN}{DOWN}")
    Wait-Usage {
        $selection = $picker.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        $selection.Count -eq 1 -and $selection[0].Current.Name -eq "Guest"
    } "keyboard category selection"
    Invoke-Usage UsageCategoryCancel
    Assert-Usage Permanent "Auto"
    Assert-UsageCell "Concurrent name" Permanent $true -Capture "usage-badge-high-contrast"
    [UsageReviewContrast]::Set($contrast)
    $contrast = $null
    $phase = Step-UiRegressionPhase $phase "usage/text-scaling" $ScreenshotDirectory
    Test-UsageTextScaling
    $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
    Write-Host "Usage-category inference, Save/Cancel, failed draft, restart, conflict reload, unavailable/no evidence, themes, contrast and narrow keyboard-accessible controls passed."
}
catch {
    $failed = $true
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "usage-failure.png")
        }
        catch { Write-Warning "Could not capture usage failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $false } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name "UsageCategory.Ui" },
        { if ($lock) { $lock.Dispose() } },
        { if ($null -ne $contrast) { [UsageReviewContrast]::Set($contrast) } },
        { if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id } },
        {
            foreach ($key in $previous.Keys) {
                if ([string]::IsNullOrEmpty($previous[$key])) { Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
            }
        },
        { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    )
}
