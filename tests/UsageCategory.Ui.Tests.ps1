param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Usage-category UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
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
}
'@

function Find-Usage([string] $Value, [switch] $ByName, [switch] $Optional) {
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new($property, $Value))
    if (-not $element -and -not $Optional) { throw "Missing usage-category control '$Value'." }
    return $element
}

function Wait-Usage([scriptblock] $Condition, [string] $Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Start-UsageApp {
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

function Stop-UsageApp {
    if ($script:process -and -not $script:process.HasExited) {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) { throw "Usage-category app did not close normally." }
    }
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
    Wait-Usage { (Find-Usage ResultCountText).Current.Name -match '^Showing 1 (device|of \d+ devices)$' } "one selected fixture device"
    $row = (Find-Usage ResultsList).FindFirst([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Usage {
        $scroll = Find-Usage DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "device details"
}

function Show-Usage([string] $Id) {
    $viewport = Find-Usage DeviceDetailsScroll
    $scroll = $viewport.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    foreach ($percent in 0..100) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 10
        $control = Find-Usage $Id
        $bounds = $control.Current.BoundingRectangle
        $area = $viewport.Current.BoundingRectangle
        if (-not $control.Current.IsOffscreen -and $bounds.Height -gt 0 -and
            $bounds.Top -ge $area.Top -and $bounds.Bottom -le $area.Bottom) { return $control }
    }
    throw "Usage control '$Id' is clipped or unreachable."
}

function Choose-Usage([string] $Choice) {
    $null = Show-Usage UsageCategoryPicker
    Set-UiReviewAppearanceChoice -Root $script:root -Picker UsageCategoryPicker -Choice $Choice
}

function Invoke-Usage([string] $Id) {
    (Show-Usage $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Assert-Usage([string] $Category, [string] $Source) {
    $null = Show-Usage UsageCategoryEffective
    try {
        Wait-Usage { (Find-Usage UsageCategoryEffective).Current.Name -like "Saved effective category: $Category | $Source*" } "$Category / $Source"
    }
    catch {
        $effective = (Find-Usage UsageCategoryEffective).Current.Name
        $evidence = (Find-Usage UsageCategoryEvidence).Current.Name
        throw "Expected $Category / $Source; actual effective='$effective'; evidence='$evidence'. $($_.Exception.Message)"
    }
}

function Save-UsageCapture([string] $Name, [string] $Control = "UsageCategoryPicker") {
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
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
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
    Start-UsageApp
    Open-UsageDevice
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
    Stop-UsageApp
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
    Wait-Usage { (Find-Usage UsageCategoryEditStatus).Current.Name -eq "No unsaved category changes." } "completed conflict reload"
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
    Write-UsageSql "UPDATE inventory SET revision='$([Guid]::NewGuid())';"
    Invoke-Usage UsageCategoryRefresh
    Wait-Usage { (Find-Usage UsageCategoryEffective).Current.Name -like "*Unavailable*could not be loaded*" } "stale-evidence error"
    if ((Find-Usage UsageCategoryEvidence).Current.Name -like "*12 of 14*") { throw "Failed refresh must not present old inference as current." }
    Save-UsageCapture "usage-evidence-error" UsageCategoryEffective
    Stop-UsageApp
    Start-UsageApp
    Open-UsageDevice "Concurrent name"
    Assert-Usage Permanent "Auto"
    Open-UsageDevice "Usage imported"
    Assert-Usage Unclassified "Auto - no eligible scans"
    if ((Find-Usage UsageCategoryEvidence).Current.Name -match '%') { throw "No evidence must not fabricate a percentage." }
    Save-UsageCapture "usage-no-evidence"
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        (Find-Usage "Settings" -ByName).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Wait-Usage { -not (Find-Usage ModePicker).Current.IsOffscreen } "Settings"
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-UsageDevice "Concurrent name"
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        foreach ($width in @($bounds.Width, 640)) {
            if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
                $bounds.Left, $bounds.Top, $width, $bounds.Height, 0x0044)) { throw "Unable to resize the category review window." }
            Start-Sleep -Milliseconds 300
            foreach ($id in @("UsageCategoryPicker", "UsageCategorySave", "UsageCategoryCancel", "UsageCategoryRefresh")) {
                $control = Show-Usage $id
                $area = $script:root.Current.BoundingRectangle
                if (-not $area.Contains($control.Current.BoundingRectangle)) { throw "$id is clipped." }
            }
            Choose-Usage Personal
            Save-UsageCapture "usage-$($theme.Replace(' ', '-'))-$width" UsageCategorySave
            Invoke-Usage UsageCategoryCancel
        }
        $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height, 0x0044)
    }
    $contrast = [UsageReviewContrast]::Get()
    [UsageReviewContrast]::Set($contrast -bor 1)
    Start-Sleep -Seconds 2
    if (([UsageReviewContrast]::Get() -band 1) -eq 0) { throw "High contrast did not activate." }
    Choose-Usage Personal
    Save-UsageCapture "usage-high-contrast" UsageCategorySave
    $picker = Show-Usage UsageCategoryPicker
    $picker.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DOWN}{DOWN}{ENTER}")
    $selection = $picker.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    if ($selection.Count -ne 1 -or $selection[0].Current.Name -ne "Personal") { throw "Keyboard category selection failed." }
    Invoke-Usage UsageCategoryCancel
    Assert-Usage Permanent "Auto"
    [UsageReviewContrast]::Set($contrast)
    $contrast = $null
    Write-Host "Usage-category inference, Save/Cancel, failed draft, restart, conflict reload, unavailable/no evidence, themes, contrast and narrow keyboard-accessible controls passed."
}
catch {
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "usage-failure.png")
        }
        catch { Write-Warning "Could not capture usage failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($null -ne $contrast) { [UsageReviewContrast]::Set($contrast) }
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
