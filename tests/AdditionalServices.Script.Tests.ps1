$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
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
foreach ($name in @("Wait-ServiceState", "Select-ServicePage", "Show-ServiceScanSection")) {
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
        "UDP observations (silence is not an open or closed port)" { return $script:fixtureHeadingPeer }
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
Write-Host "Additional service UI helper regression checks passed without desktop automation."
