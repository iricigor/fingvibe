param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $Version,
    [ValidateSet("Release", "PullRequest", "Test", "Development")]
    [string] $BuildKind = "Development",
    [int] $PullRequestNumber,
    [string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($BuildKind -eq "PullRequest" -and $PullRequestNumber -le 0) {
    throw "PullRequest builds require a positive PullRequestNumber."
}
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BuildIdentityReviewKeyboard
{
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public static void Tap(byte key)
    {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
}
"@
$previousReview = $env:FINGVIBE_UI_REVIEW
$env:FINGVIBE_UI_REVIEW = "1"

function Find-Element {
    param([string] $Name, [System.Windows.Automation.ControlType] $Type)
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -eq $element) { throw "Missing $Type element: $Name" }
    return $element
}

function Invoke-Button {
    param([string] $Name)
    $element = Find-Element $Name ([System.Windows.Automation.ControlType]::Button)
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
    Start-Sleep -Milliseconds 300
}

function Select-Page {
    param([string] $Name)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $elements = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    foreach ($element in $elements) {
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref] $pattern)) {
            $pattern.Select()
            Start-Sleep -Milliseconds 300
            return
        }
    }
    throw "Missing selectable page: $Name"
}

$label = switch ($BuildKind) {
    "Release" { "Official release" }
    "PullRequest" { "PR #$PullRequestNumber - Test build" }
    "Test" { "TEST - Non-release build" }
    default { "DEV - Local build" }
}
$marker = switch ($BuildKind) {
    "Release" { "" }
    "PullRequest" { " - PR #$PullRequestNumber" }
    "Test" { " - TEST" }
    default { " - DEV" }
}
$title = "FingVibe LAN Scanner - v$Version$marker"
$ribbonName = "Acknowledge $label; hide ribbon until the app closes"
$process = $null
try {
    foreach ($activation in @("invoke", "keyboard")) {
        $process = Start-Process -FilePath $AppPath -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $process.Refresh()
            if ($process.HasExited) { throw "App exited with code $($process.ExitCode)." }
        } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
        if ($process.MainWindowHandle -eq 0) { throw "App did not open a window." }
        [BuildIdentityReviewKeyboard]::Tap(0x12)
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $null = [UiReviewNativeWindow]::SetForegroundWindow($process.MainWindowHandle)
            Start-Sleep -Milliseconds 100
        } while ([UiReviewNativeWindow]::GetForegroundWindow() -ne $process.MainWindowHandle `
            -and [DateTime]::UtcNow -lt $deadline)
        Initialize-UiReviewWindow -WindowHandle $process.MainWindowHandle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        if ($root.Current.Name -ne $title) { throw "Incorrect title: $($root.Current.Name)" }
        $null = Find-Element "v$Version - $label" ([System.Windows.Automation.ControlType]::Text)

        if ($BuildKind -ne "Release") {
            $ribbon = Find-Element $ribbonName ([System.Windows.Automation.ControlType]::Button)
            if ($ribbon.Current.IsOffscreen) { throw "Ribbon is not visible on launch." }
            Select-Page "Tools"
            $null = Find-Element $ribbonName ([System.Windows.Automation.ControlType]::Button)
            Select-Page "Overview"

            if ($ScreenshotDirectory -and $activation -eq "invoke") {
                $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
                Save-UiReviewWindowScreenshot -WindowHandle $process.MainWindowHandle `
                    -Path (Join-Path $ScreenshotDirectory "$BuildKind-overview.png")
            }

            $bounds = Get-UiReviewWindowBounds -WindowHandle $process.MainWindowHandle
            $null = [UiReviewNativeWindow]::SetWindowPos(
                $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 480, 0x0044)
            Start-Sleep -Milliseconds 400
            $scan = Find-Element "Scan LAN" ([System.Windows.Automation.ControlType]::Button)
            if ($scan.Current.IsOffscreen) { throw "Scan control is hidden at 640x480." }
            $versionElement = Find-Element "v$Version - $label" ([System.Windows.Automation.ControlType]::Text)
            if ($versionElement.Current.IsOffscreen) { throw "Version is not visible at 640x480." }
            if ($activation -eq "keyboard") {
                $ribbon.SetFocus()
                [System.Windows.Forms.SendKeys]::SendWait(" ")
                Start-Sleep -Milliseconds 300
            } else {
                Invoke-Button $ribbonName
            }
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $ribbonName)
            $remaining = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($null -ne $remaining -and -not $remaining.Current.IsOffscreen) {
                throw "Ribbon remains visible after acknowledgment."
            }
            if ($root.Current.Name -ne $title) { throw "Acknowledgment changed the title." }
        } else {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "BuildRibbon")
            $ribbon = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($null -ne $ribbon -and -not $ribbon.Current.IsOffscreen) {
                throw "Official release shows a ribbon."
            }
        }

        Invoke-Button "About FingVibe"
        $null = Find-Element "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
        $null = Find-Element "v$Version" ([System.Windows.Automation.ControlType]::Text)
        $null = Find-Element $label ([System.Windows.Automation.ControlType]::Text)
        Invoke-Button "Back to Tools"
        Invoke-Button "About FingVibe"
        $null = Find-Element "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
        Select-Page "Overview"
        Invoke-Button "About FingVibe"
        $null = Find-Element "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
        Stop-Process -Id $process.Id
        $process.WaitForExit()
        $process = $null
    }
    Write-Host "$BuildKind title, version, ribbon lifetime, keyboard acknowledgment, narrow layout, and About navigation passed."
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $previousReview
}
