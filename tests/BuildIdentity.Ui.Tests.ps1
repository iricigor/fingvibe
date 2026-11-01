param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $Version,
    [ValidateSet("Release", "PullRequest", "Test", "Development")]
    [string] $BuildKind = "Development",
    [int] $PullRequestNumber,
    [string] $BuildTimestamp,
    [string] $BuildCommit,
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
    [StructLayout(LayoutKind.Sequential)]
    private struct HIGHCONTRAST
    {
        public uint Size;
        public uint Flags;
        public IntPtr Scheme;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);

    public static uint GetHighContrastFlags()
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }

    public static void SetHighContrastFlags(uint flags)
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);

    public static void Click(int x, int y)
    {
        if (!SetCursorPos(x, y))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }

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

function Assert-RibbonText {
    $window = $script:root.Current.BoundingRectangle
    foreach ($text in @($script:ribbonText, $script:compactTimestamp)) {
        $element = Find-Element $text ([System.Windows.Automation.ControlType]::Text)
        $rectangle = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $rectangle.IsEmpty -or -not $window.Contains($rectangle)) {
            throw "Ribbon text is offscreen or clipped by the window: $text ($rectangle)."
        }
    }
}

function Select-Page {
    param([string] $Name)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $elements = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($element in $elements) {
            $pattern = $null
            if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref] $pattern)) {
                $pattern.Select()
                Start-Sleep -Milliseconds 300
                return
            }
        }
        if ($attempt -eq 1) { break }
        $toggleCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "TogglePaneButton")
        $toggle = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $toggleCondition)
        if ($null -eq $toggle) { throw "Navigation toggle is unavailable for page: $Name" }
        $toggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 300
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
$ribbonText = switch ($BuildKind) {
    "PullRequest" { "PR #$PullRequestNumber - TEST BUILD" }
    "Test" { "TEST BUILD" }
    default { "DEV BUILD" }
}
$compactTimestamp = "Build time unavailable"
$fullTimestamp = "Build time unavailable"
if ($BuildTimestamp) {
    $timestampFormats = @(0..7 | ForEach-Object {
        "yyyy-MM-dd'T'HH:mm:ss" + $(if ($_ -eq 0) { "" } else { "." + ("f" * $_) }) + "'Z'"
    })
    $timestamp = [DateTimeOffset]::ParseExact($BuildTimestamp,
        [string[]]$timestampFormats,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    $compactTimestamp = "Built " + $timestamp.ToString("MMM d, HH:mm 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
    $fullTimestamp = "Built " + $timestamp.ToString("MMM d, yyyy, HH:mm:ss.FFFFFFF 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
}
$ribbonName = "Acknowledge $label; $fullTimestamp; hide ribbon until the app closes"
$commitText = if ($BuildCommit) { "Commit: $BuildCommit" } else { "Commit not recorded for this build." }
$highContrastFlags = $null
$process = $null
try {
    foreach ($activation in @("invoke", "mouse", "keyboard")) {
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
            Assert-RibbonText
            $expectedTooltip = "v$Version - $label`n$fullTimestamp`n$commitText`nAcknowledge this build (hide ribbon until the app closes)"
            if ($ribbon.Current.HelpText -ne $expectedTooltip) {
                throw "Ribbon tooltip does not contain full build identity and dismissal guidance."
            }
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
            Assert-RibbonText
            if ($ScreenshotDirectory -and $activation -eq "invoke") {
                Save-UiReviewWindowScreenshot -WindowHandle $process.MainWindowHandle `
                    -Path (Join-Path $ScreenshotDirectory "$BuildKind-narrow.png")
            }
            # Only the disposable CI desktop may change the user's system-wide contrast setting.
            if ($env:GITHUB_ACTIONS -eq "true" -and $activation -eq "invoke") {
                $highContrastFlags = [BuildIdentityReviewKeyboard]::GetHighContrastFlags()
                [BuildIdentityReviewKeyboard]::SetHighContrastFlags($highContrastFlags -bor 1)
                Start-Sleep -Seconds 2
                if (([BuildIdentityReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) {
                    throw "High contrast did not activate on the CI desktop."
                }
                Assert-RibbonText
                if ($ScreenshotDirectory) {
                    Save-UiReviewWindowScreenshot -WindowHandle $process.MainWindowHandle `
                        -Path (Join-Path $ScreenshotDirectory "$BuildKind-narrow-high-contrast.png")
                }
                [BuildIdentityReviewKeyboard]::SetHighContrastFlags($highContrastFlags)
                $highContrastFlags = $null
                Start-Sleep -Seconds 2
            }
            if ($activation -eq "keyboard") {
                $ribbon.SetFocus()
                [System.Windows.Forms.SendKeys]::SendWait(" ")
                Start-Sleep -Milliseconds 300
            } elseif ($activation -eq "mouse") {
                $text = Find-Element $compactTimestamp ([System.Windows.Automation.ControlType]::Text)
                $rectangle = $text.Current.BoundingRectangle
                [BuildIdentityReviewKeyboard]::Click(
                    [int]($rectangle.Left + $rectangle.Width / 2), [int]($rectangle.Top + $rectangle.Height / 2))
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
        $null = Find-Element $fullTimestamp ([System.Windows.Automation.ControlType]::Text)
        $null = Find-Element $commitText ([System.Windows.Automation.ControlType]::Text)
        if ($ScreenshotDirectory -and $activation -eq "invoke") {
            $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
            Save-UiReviewWindowScreenshot -WindowHandle $process.MainWindowHandle `
                -Path (Join-Path $ScreenshotDirectory "$BuildKind-about.png")
        }
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
    Write-Host "$BuildKind title, version, visible timestamp, tooltip, ribbon lifetime, mouse/keyboard acknowledgment, narrow layout, and About navigation passed."
}
finally {
    if ($null -ne $highContrastFlags) { [BuildIdentityReviewKeyboard]::SetHighContrastFlags($highContrastFlags) }
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $previousReview
}
