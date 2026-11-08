$ErrorActionPreference = "Stop"

function Read-UsageTestAst([string] $Name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $Name), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "; ") }
    return $ast
}

$devices = Read-UsageTestAst "DevicesList.Ui.Tests.ps1"
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
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-Usage"
    }, $true)
    Invoke-Expression $helper.Extent.Text
    $state = @{ Shown = $false; Effective = "Saved effective category: Permanent | Auto - limited evidence" }
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
    $state.Effective = "Saved effective category: Unavailable | Query failed"
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
