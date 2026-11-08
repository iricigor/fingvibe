$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
& {
    $sidebarParseErrors = $null
    $sidebarAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "SidebarNavigation.Tests.ps1"), [ref]$null, [ref]$sidebarParseErrors)
    if ($sidebarParseErrors) { throw ($sidebarParseErrors.Message -join "; ") }
    $nativeHelper = $sidebarAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq "Add-Type"
    }, $true)
    if (-not $nativeHelper) { throw "Missing sidebar native input helper." }
    Invoke-Expression $nativeHelper.Extent.Text
    $save = $sidebarAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Save-SidebarAppearance"
    }, $true)
    if (-not $save) { throw "Missing sidebar screenshot helper." }
    Invoke-Expression $save.Extent.Text
    $ScreenshotDirectory = $env:TEMP
    $windowHandle = [IntPtr]::new(1)
    $captures = [System.Collections.Generic.List[string]]::new()
    function Focus-SidebarWindow {}
    function Start-Sleep { param([int] $Milliseconds) }
    function Find-SidebarElement { throw "Narrow Settings captures must not require visible navigation items." }
    function Get-UiReviewWindowBounds { throw "Background comparison bounds are not needed for a layout capture." }
    function Save-UiReviewWindowScreenshot {
        param($WindowHandle, [string] $Path)
        $captures.Add($Path)
    }
    Save-SidebarAppearance "settings-layout-640"
    if ($captures.Count -ne 1) { throw "The narrow Settings screenshot was not captured exactly once." }
}
& {
    . (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
    $item = [pscustomobject]@{ Current = [pscustomobject]@{ Name = "Colorful"; IsOffscreen = $false } }
    $itemSelection = [pscustomobject]@{}
    $itemSelection | Add-Member ScriptMethod Select {}
    $item | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $itemSelection }
    $selectionInfo = [pscustomobject]@{}
    $selectionInfo | Add-Member ScriptMethod GetSelection { return ,@($item) }
    foreach ($method in $selectionInfo.PSObject.Methods | Where-Object MemberType -eq ScriptMethod) {
        if (-not [System.Windows.Automation.SelectionPattern+SelectionPatternInformation].GetMethod($method.Name)) {
            throw "Selection mock uses an API not present in .NET UI Automation: $($method.Name)."
        }
    }
    $selection = [pscustomobject]@{ Current = $selectionInfo }
    $expand = [pscustomobject]@{}
    $expand | Add-Member ScriptMethod Expand {}
    $expand | Add-Member ScriptMethod Collapse {}
    $combo = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false } }
    $combo | Add-Member ScriptMethod GetCurrentPattern {
        param($Pattern)
        if ($Pattern -eq [System.Windows.Automation.SelectionPattern]::Pattern) { return $selection }
        return $expand
    }
    $appearanceRoot = [pscustomobject]@{}
    $appearanceRoot | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        if ($Condition -is [System.Windows.Automation.AndCondition]) { return $item }
        return $combo
    }
    Set-UiReviewAppearanceChoice -Root $appearanceRoot -Picker ThemePicker -Choice Colorful
}
Add-Type -TypeDefinition @"
using System;
public static class UiReviewNativeWindow
{
    public static uint GetDpiForWindow(IntPtr window) { return 96; }
}
"@
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "AdditionalServices.Ui.Tests.ps1"), [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join "; ") }
foreach ($name in @("Wait-ServiceState", "Select-ServicePage", "Show-ServiceScanSection", "Show-ServiceCardFootnotes")) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing UI helper $name." }
    Invoke-Expression $definition.Extent.Text
}

function Start-Sleep { param([int] $Milliseconds) }
$script:selections = 0
$selection = [pscustomobject]@{}
$selection | Add-Member ScriptMethod Select { $script:selections += 1 }
$navItem = [pscustomobject]@{}
$navItem | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $selection }
$root = [pscustomobject]@{}
$root | Add-Member ScriptMethod FindFirst {
    param($Scope, $Condition)
    if ($Condition -isnot [System.Windows.Automation.AndCondition]) {
        throw "Polling must not shadow the caller's automation condition."
    }
    return $navItem
}
Select-ServicePage Devices
if ($script:selections -ne 1) { throw "Navigation was not selected exactly once." }

$process = [pscustomobject]@{ MainWindowHandle = [IntPtr]::new(1) }
$script:fixtureScrollPercent = 100
$script:fixtureScrollCalls = 0
$script:fixtureButtonTop = 930
$script:fixtureHeadingBottom = 1326
$script:fixtureButtonPeer = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(312, 130, 160, 32)
} }
$script:fixtureHeadingPeer = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(312, 496, 600, 30)
} }
$scroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticalScrollPercent = 100 } }
$scroll | Add-Member ScriptMethod SetScrollPercent {
    param($Horizontal, $Vertical)
    $script:fixtureScrollPercent = $Vertical
    $script:fixtureScrollCalls += 1
    $this.Current.VerticalScrollPercent = $Vertical
    $script:fixtureButtonPeer.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(312, $script:fixtureButtonTop - $Vertical * 8, 160, 32)
    $script:fixtureHeadingPeer.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(312, $script:fixtureHeadingBottom - 30 - $Vertical * 8, 600, 30)
}
$scrollElement = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(312, 190, 680, 1500)
} }
$scrollElement | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
function Find-ServiceControl {
    param([string] $Value, [switch] $ByName)
    switch ($Value) {
        "DeviceDetailsScroll" { return $scrollElement }
        "DevicePortScanButton" { return $script:fixtureButtonPeer }
        "DeviceIncludeUdpCheckBox" { return $script:fixtureHeadingPeer }
        default { throw "Unexpected mock control $Value." }
    }
}
function Get-UiReviewWindowBounds {
    param([IntPtr] $WindowHandle)
    return [System.Drawing.Rectangle]::new(0, 0, 1024, 720)
}
Show-ServiceScanSection
if ($script:fixtureScrollPercent -ne 91 -or $script:fixtureHeadingPeer.Current.BoundingRectangle.Bottom -gt 602) {
    throw "Offscreen automation bounds were mistaken for a visible physical viewport."
}
$script:fixtureButtonTop += 10
$script:fixtureHeadingBottom += 10
Show-ServiceScanSection
if ($script:fixtureScrollPercent -ne 92) { throw "Scrolling did not adapt precisely to changing results." }
$scroll.SetScrollPercent(-1, 0)
Show-ServiceScanSection
if ($script:fixtureScrollPercent -ne 92) { throw "The narrow visible range was skipped by coarse scroll steps." }
$script:fixtureHeadingBottom = $script:fixtureButtonTop + 344
$scroll.SetScrollPercent(-1, 85)
Show-ServiceScanSection -ExtraSpace 24
if ($script:fixtureScrollPercent -ne 89) { throw "Early-result preparation did not reserve the next endpoint row." }
$script:fixtureHeadingBottom += 24
$callsBeforeCapture = $script:fixtureScrollCalls
Show-ServiceScanSection
if ($script:fixtureScrollCalls -ne $callsBeforeCapture + 1) {
    throw "The early-result capture searched the viewport instead of using its prepared position."
}

$script:footnoteNetworkBottom = 900
$script:footnoteAssignmentBottom = 960
$script:footnoteScrollPercent = -1
$script:footnoteNetworkPeer = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(312, 880, 520, 20)
} }
$script:footnoteAssignmentPeer = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(852, 920, 360, 40)
} }
$script:footnoteScroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticallyScrollable = $true } }
$script:footnoteScroll | Add-Member ScriptMethod SetScrollPercent {
    param($Horizontal, $Vertical)
    $script:footnoteScrollPercent = $Vertical
    $offset = $Vertical * 8
    $script:footnoteNetworkPeer.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(
        312, $script:footnoteNetworkBottom - 20 - $offset, 520, 20)
    $script:footnoteAssignmentPeer.Current.BoundingRectangle = [System.Drawing.RectangleF]::new(
        852, $script:footnoteAssignmentBottom - 40 - $offset, 360, 40)
}
$script:footnoteScrollElement = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [System.Drawing.RectangleF]::new(312, 190, 900, 1500)
} }
$script:footnoteScrollElement | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $script:footnoteScroll }
function Find-ServiceControl {
    param([string] $Value, [switch] $ByName)
    switch ($Value) {
        "DeviceDetailsScroll" { return $script:footnoteScrollElement }
        "DeviceAddressSourceText" { return $script:footnoteNetworkPeer }
        "DeviceAssignmentStatusText" { return $script:footnoteAssignmentPeer }
        default { throw "Unexpected mock control $Value." }
    }
}
Show-ServiceCardFootnotes
if ($script:footnoteScrollPercent -ne 36 -or $script:footnoteAssignmentPeer.Current.BoundingRectangle.Bottom -gt 672) {
    throw "Card footnotes were judged against the automation viewport instead of the physical window."
}
$script:footnoteAssignmentBottom = 2000
$failure = $null
try { Show-ServiceCardFootnotes } catch { $failure = $_.Exception.Message }
if ($failure -notlike "*physical details viewport*") {
    throw "Unreachable card footnotes must fail with physical viewport diagnostics."
}
Write-Host "Additional service UI helper regression checks passed without desktop automation."
