$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")

function Read-UsageTestAst([string] $Name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $Name), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "; ") }
    return $ast
}

$devices = Read-UsageTestAst "UiRegression\Devices.Filters.Helpers.ps1"
$usage = Read-UsageTestAst "UsageCategory.Ui.Tests.ps1"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not [System.Windows.Automation.SelectionPattern+SelectionPatternInformation].GetMethod("GetSelection") -or
    $usage.Extent.Text.Contains(".GetCurrentSelection()")) {
    throw "Native selection checks must use the supported Current.GetSelection UI Automation API."
}
& {
    $helper = $devices.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Set-DeviceFilterChoice"
    }, $true)
    Invoke-Expression $helper.Extent.Text
    $calls = [System.Collections.Generic.List[object]]::new()
    function Find-DeviceElement { throw "Checkbox filters must not use the ComboBox/ListItem path." }
    function Set-DeviceFilterChecks([string] $Id, [string[]] $Labels) {
        $calls.Add(@{ Id = $Id; Labels = $Labels })
    }
    foreach ($id in @("InventoryStatusFilter", "TypeFilter", "OperatingSystemFilter", "VendorFilter",
        "PersonFilter", "RoomFilter", "PortsFilter", "UsageCategoryFilter")) {
        Set-DeviceFilterChoice $id Unclassified
        if ($calls[-1].Id -ne $id -or $calls[-1].Labels.Count -ne 1 -or $calls[-1].Labels[0] -ne "Unclassified") {
            throw "$id did not select the requested checkbox."
        }
        Set-DeviceFilterChoice $id "All categories"
        if ($calls[-1].Labels.Count -ne 0) { throw "$id did not clear its selection." }
    }
}
& {
    $helper = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Find-UsageIndicator"
    }, $true)
    if (-not $helper -or -not $helper.Extent.Text.Contains('[System.Windows.Automation.TreeWalker]::new($condition)')) {
        throw "The raw-only decorative usage indicator must be found through a filtered tree walker."
    }
    Invoke-Expression $helper.Extent.Text.Replace('[System.Windows.Automation.TreeWalker]::new($condition)', 'New-UsageWalkerDouble $condition')
    $state = @{ Cell = [pscustomobject]@{ Id = "current-usage-cell" }; Icon = [pscustomobject]@{ Id = "raw-icon" }; Calls = 0 }
    function New-UsageWalkerDouble($Condition) {
        if ($Condition.Property -ne [System.Windows.Automation.AutomationElement]::AutomationIdProperty -or
            $Condition.Value -ne "DeviceUsageCategoryIndicator") {
            throw "The raw walker must filter only the existing usage indicator identity."
        }
        $walker = [pscustomobject]@{}
        $walker | Add-Member ScriptMethod GetFirstChild {
            param($Cell)
            if ($Cell -ne $state.Cell) { throw "Icon lookup must be confined to the currently selected usage cell." }
            $state.Calls++
            return $state.Icon
        }
        return $walker
    }
    function Find-Usage { throw "The raw icon must not use the control-view lookup." }
    if ((Find-UsageIndicator $state.Cell) -ne $state.Icon -or $state.Calls -ne 1) {
        throw "A raw-only usage indicator must be returned from its own cell."
    }
    $state.Icon = $null
    if (Find-UsageIndicator $state.Cell) { throw "An absent/collapsed icon must not be replaced by another row's indicator." }
    $assertion = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-UsageCell"
    }, $true)
    if ($assertion.Extent.Text.Contains('Find-Usage DeviceUsageCategoryIndicator') -or
        [regex]::Matches($assertion.Extent.Text, 'Find-UsageIndicator \$cell').Count -ne 2) {
        throw "Normal and narrow usage geometry must both reacquire the current cell's raw-only icon."
    }
}
& {
    $helper = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-Usage"
    }, $true)
    Invoke-Expression $helper.Extent.Text
    $state = @{ Shown = $false; Effective = "Permanent | Auto - limited evidence" }
    function Show-Usage([string] $Id) {
        if ($Id -ne "UsageCategoryEffective") { throw "Wrong assertion viewport." }
        $state.Shown = $true
    }
    function Find-Usage([string] $Id) {
        if (-not $state.Shown) { throw "Realize the editor before inspecting accessible text." }
        return [pscustomobject]@{ Current = [pscustomobject]@{ Name = $state.Effective } }
    }
    function Wait-Usage([scriptblock] $Condition, [string] $Description) {
        if (-not (& $Condition)) { throw "Timed out waiting for $Description." }
    }
    Assert-Usage Permanent "Auto - limited evidence"
    $state.Effective = "Unavailable | Query failed"
    $failed = $false
    try { Assert-Usage Permanent "Auto - limited evidence" }
    catch {
        if ($_.Exception.Message -notlike "*actual effective='*Unavailable*Query failed*") { throw }
        $failed = $true
    }
    if (-not $failed) { throw "Wrong native category must fail, not pass after scrolling." }
}
& {
    $helper = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Show-Usage"
    }, $true)
    Invoke-Expression $helper.Extent.Text
    function Start-Sleep { param([int] $Milliseconds) }
    $script:root = [pscustomobject]@{ Current = [pscustomobject]@{
        BoundingRectangle = [System.Drawing.RectangleF]::new(0, 0, 1280, 800) } }
    $state = @{ Percent = -1; BaseBottom = 1000 }
    $control = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [System.Drawing.RectangleF]::new(852, 960, 360, 40) } }
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticallyScrollable = $true } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Vertical)
        $state.Percent = $Vertical
        $control.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(
            852, $state.BaseBottom - 40 - $Vertical * 8, 360, 40)
    }
    $viewport = [pscustomobject]@{ Current = [pscustomobject]@{
        BoundingRectangle = [System.Drawing.RectangleF]::new(250, 107, 1000, 733) } }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    function Find-Usage([string] $Id) {
        if ($Id -eq "DeviceDetailsScroll") { return $viewport }
        return $control
    }
    $null = Show-Usage UsageCategorySave
    if ($state.Percent -ne 27 -or $control.Current.BoundingRectangle.Bottom -gt 784) {
        throw "Usage controls were judged against the automation viewport instead of the physical window."
    }
    $state.BaseBottom = 2000
    $failure = $null
    try { $null = Show-Usage UsageCategorySave } catch { $failure = $_.Exception.Message }
    if ($failure -notlike "*clipped or unreachable*") { throw "A control beyond the physical window must not be reported visible." }
}
& {
    $helper = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Find-UsageRow"
    }, $true)
    Invoke-Expression $helper.Extent.Text
    $state = @{ List = $null }
    function Find-Usage([string] $Id, [switch] $ByName, [switch] $Optional) {
        if ($Id -ne "ResultsList" -or $ByName -or -not $Optional) { throw "Row lookup must poll the Devices list optionally." }
        return $state.List
    }
    function New-UsageRowDouble([string] $Id, $Name) {
        $cell = if ($null -ne $Name) { [pscustomobject]@{ Current = [pscustomobject]@{ Name = $Name } } }
        $row = [pscustomobject]@{ Id = $Id; Cell = $cell }
        $row | Add-Member ScriptMethod FindFirst {
            param($Scope, $Condition)
            if ($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or $Condition.Value -ne "DeviceNameText") { return $null }
            return $this.Cell
        }
        return $row
    }
    function New-UsageListDouble($Rows, [switch] $Offscreen) {
        $list = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = [bool] $Offscreen }; Rows = @($Rows) }
        $list | Add-Member ScriptMethod FindAll {
            param($Scope, $Condition)
            if ($Scope -ne [System.Windows.Automation.TreeScope]::Children -or
                $Condition.Value -ne [System.Windows.Automation.ControlType]::ListItem.Id) { return , @() }
            return , @($this.Rows)
        }
        return $list
    }
    $concurrent = New-UsageRowDouble "concurrent" "Concurrent name"
    $imported = New-UsageRowDouble "imported" "Usage imported"
    $state.List = New-UsageListDouble @($concurrent)
    if ((Find-UsageRow "Concurrent name").Id -ne "concurrent") { throw "The only row with the requested device name must be returned." }
    if (Find-UsageRow "Usage imported") { throw "A stale row from the previous filter must not be opened." }
    if (Find-UsageRow "concurrent name") { throw "Device names must match exactly." }
    $state.List = New-UsageListDouble @($concurrent, $imported)
    if (Find-UsageRow "Concurrent name") { throw "An unfiltered list must not be mistaken for the filtered result." }
    $state.List = New-UsageListDouble @()
    if (Find-UsageRow "Concurrent name") { throw "A list that is still rebuilding has no row to open." }
    $state.List = New-UsageListDouble @($concurrent) -Offscreen
    if (Find-UsageRow "Concurrent name") { throw "A hidden Devices list has no row to open." }
    $state.List = $null
    if (Find-UsageRow "Concurrent name") { throw "A missing Devices list has no row to open." }
    $state.List = New-UsageListDouble @((New-UsageRowDouble "unnamed" $null))
    if (Find-UsageRow "Concurrent name") { throw "A row without a device name cell must not match." }

    $open = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Open-UsageDevice"
    }, $true)
    if ($open.Extent.Text -notmatch 'Wait-Usage \{ Find-UsageRow \$Name \}' -or $open.Extent.Text.Contains("ResultCountText")) {
        throw "Opening a device must wait for its own row, not for a result count that can describe the previous filter."
    }
}
& {
    $find = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Find-UsageSettings"
    }, $true)
    $select = $usage.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Select-UsageSettings"
    }, $true)
    Invoke-Expression $find.Extent.Text
    Invoke-Expression $select.Extent.Text
    $state = @{ Item = $null; Polls = 0; ReadyAfter = 1; GoneAfter = [int]::MaxValue; Selected = 0; SelectedAtPoll = -1; Picker = $null; ShowsAfterSelect = $true }
    $script:root = [pscustomobject]@{}
    $script:root | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        $parts = @($Condition.GetConditions())
        $nameId = [System.Windows.Automation.AutomationElement]::NameProperty.ProgrammaticName
        $typeId = [System.Windows.Automation.AutomationElement]::ControlTypeProperty.ProgrammaticName
        $name = @($parts | Where-Object { $_.Property.ProgrammaticName -eq $nameId })
        $type = @($parts | Where-Object { $_.Property.ProgrammaticName -eq $typeId })
        if ($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or $parts.Count -ne 2 -or $name.Count -ne 1 -or
            $type.Count -ne 1 -or $name[0].Value -ne "Settings" -or $type[0].Value -ne [System.Windows.Automation.ControlType]::ListItem.Id) {
            return $null
        }
        return $state.Item
    }
    function New-UsageSettingsDouble([switch] $Offscreen) {
        $selection = [pscustomobject]@{}
        $selection | Add-Member ScriptMethod Select {
            $state.Selected++
            $state.SelectedAtPoll = $state.Polls
            if ($state.ShowsAfterSelect) {
                $state.Picker = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false } }
            }
        }
        $item = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = [bool] $Offscreen } }
        $item | Add-Member ScriptMethod GetCurrentPattern {
            param($PatternId)
            if ($PatternId -ne [System.Windows.Automation.SelectionItemPattern]::Pattern) { throw "Settings must be selected through SelectionItemPattern." }
            return $selection
        }.GetNewClosure()
        return $item
    }

    $state.Item = New-UsageSettingsDouble
    if ((Find-UsageSettings) -ne $state.Item) { throw "The on-screen Settings navigation item must be found by name and list-item type." }
    $state.Item = $null
    if (Find-UsageSettings) { throw "A collapsed navigation pane exposes no Settings item." }
    $state.Item = New-UsageSettingsDouble -Offscreen
    if (Find-UsageSettings) { throw "An off-screen Settings item must not be selected." }

    function Wait-Usage([scriptblock] $Condition, [string] $Description) {
        for ($attempt = 0; $attempt -lt 5; $attempt++) { if (& $Condition) { return } }
        throw "Timed out waiting for $Description."
    }
    function Find-UsageSettings {
        $state.Polls++
        if ($state.Polls -lt $state.ReadyAfter -or $state.Polls -gt $state.GoneAfter) { return $null }
        return $state.Item
    }
    function Find-Usage([string] $Id, [switch] $ByName, [switch] $Optional) {
        if ($Id -ne "ModePicker" -or $ByName -or -not $Optional) { throw "The Settings page must be polled through its optional appearance picker." }
        return $state.Picker
    }
    $state.Item = New-UsageSettingsDouble
    $state.ReadyAfter = 3
    Select-UsageSettings
    if ($state.Selected -ne 1 -or $state.SelectedAtPoll -lt 3) {
        throw "Settings must be selected once, only after the collapsed navigation pane exposes it."
    }

    $state.Polls = 0; $state.Selected = 0; $state.Picker = $null; $state.ReadyAfter = 99
    $failure = $null
    try { Select-UsageSettings } catch { $failure = $_.Exception.Message }
    if ($failure -notlike "*Settings navigation item*" -or $state.Selected -ne 0) {
        throw "A navigation pane that never returns must time out without selecting anything."
    }

    $state.Polls = 0; $state.Selected = 0; $state.Picker = $null; $state.ReadyAfter = 1; $state.GoneAfter = 1
    $failure = $null
    try { Select-UsageSettings } catch { $failure = $_.Exception.Message }
    if ($failure -notlike "*disappeared before it could be selected*" -or $state.Selected -ne 0) {
        throw "An item that vanishes after the wait must be reported, not dereferenced."
    }

    $state.Polls = 0; $state.Selected = 0; $state.Picker = $null; $state.ReadyAfter = 1; $state.GoneAfter = [int]::MaxValue; $state.ShowsAfterSelect = $false
    $failure = $null
    try { Select-UsageSettings } catch { $failure = $_.Exception.Message }
    if ($failure -ne "Timed out waiting for Settings." -or $state.Selected -ne 1) {
        throw "A Settings page that never appears must be reported after the item was selected."
    }

    if ($usage.Extent.Text.Contains('Find-Usage "Settings"')) {
        throw "Settings must be reached through Select-UsageSettings, which waits for the navigation pane to return after a resize."
    }
}

# Execute only the synthetic fixture construction, never the UI script's startup or desktop helpers.
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-usage-script-$([Guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $inventory = Join-Path $fixture "inventory.json"
    $snapshot = Join-Path $fixture "snapshot.json"
    $database = Join-Path $fixture "inventory.sqlite"
    $source = $usage.Extent.Text
    $start = $source.IndexOf('    $time =')
    $end = $source.IndexOf('    $env:FINGVIBE_UI_REVIEW =', $start)
    if ($start -lt 0 -or $end -lt $start) { throw "Missing native usage fixture construction." }
    Invoke-Expression $source.Substring($start, $end - $start)
    $bin = Join-Path $PSScriptRoot "FingVibe.Core.Tests\bin\Release\net8.0"
    $null = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $bin "runtimes\win-x64\native\e_sqlite3.dll"))
    foreach ($name in @("FingVibe.Core.dll", "SQLitePCLRaw.core.dll", "SQLitePCLRaw.provider.e_sqlite3.dll",
        "SQLitePCLRaw.batteries_v2.dll", "Microsoft.Data.Sqlite.dll")) {
        $null = [Reflection.Assembly]::LoadFrom((Join-Path $bin $name))
    }
    [SQLitePCL.Batteries_V2]::Init()
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new($database)
    $saved = $store.LoadMetadataAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
    foreach ($zone in @([TimeZoneInfo]::Utc, [TimeZoneInfo]::Local)) {
        $request = [FingVibe.Core.Models.AnalyticsEvidenceRequest]::new(
            "ui-review-network", "127.0.0.1/32", [DateTimeOffset]::UtcNow, 7, $zone, $saved.Revision, $null)
        $evidence = $store.QueryAnalyticsAsync($request, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $results = [FingVibe.Core.Models.DeviceUsageClassifier]::Classify($evidence, [Threading.CancellationToken]::None)
        $normal = $results[[FingVibe.Core.Models.LogicalDeviceId]::Mac("001122334455")]
        $imported = $results[[FingVibe.Core.Models.LogicalDeviceId]::Mac("001122334466")]
        if ($normal.Category.ToString() -ne "Permanent" -or $normal.Total.Responded -ne 12 -or
            $normal.Total.Eligible -ne 14 -or -not $normal.LimitedEvidence -or
            $imported.Category.ToString() -ne "Unclassified" -or $imported.Total.Eligible -ne 0) {
            throw "Native fixture must migrate/query/classify as 12/14 Permanent (limited) and imported Unclassified."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Usage native checkbox dispatch, visible assertions, failure diagnostics and exact migrated classifier fixture passed without desktop automation."
