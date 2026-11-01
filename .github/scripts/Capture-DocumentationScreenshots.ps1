param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") {
    throw "Documentation desktop automation is restricted to GitHub Actions."
}
. (Join-Path $PSScriptRoot "UiReviewScreenshot.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DocumentationCaptureKeyboard
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
$env:FINGVIBE_UI_REVIEW = "1"
$env:FINGVIBE_UI_REVIEW_SNAPSHOT = $null
$process = $null
$captures = [System.Collections.Generic.List[object]]::new()

function Find-CaptureElement {
    param([string] $Value, [switch] $Id)
    $property = if ($Id) {
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty
    } else {
        [System.Windows.Automation.AutomationElement]::NameProperty
    }
    $condition = [System.Windows.Automation.PropertyCondition]::new($property, $Value)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $elements = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($element in $elements) {
            if (-not $element.Current.IsOffscreen) { return $element }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Required documentation control is missing or offscreen: $Value."
}

function Invoke-CaptureButton {
    param([string] $Name)
    $element = Find-CaptureElement $Name
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 400
}

function Assert-CaptureVisible {
    param([string[]] $Names = @(), [string[]] $Ids = @())
    $window = $script:root.Current.BoundingRectangle
    foreach ($name in $Names) {
        $element = Find-CaptureElement $name
        $bounds = $element.Current.BoundingRectangle
        if ($bounds.IsEmpty -or -not $window.Contains($bounds)) {
            throw "Documentation control is clipped: $name ($bounds)."
        }
    }
    foreach ($id in $Ids) {
        $element = Find-CaptureElement $id -Id
        $bounds = $element.Current.BoundingRectangle
        if ($bounds.IsEmpty -or -not $window.Contains($bounds)) {
            throw "Documentation control is clipped: $id ($bounds)."
        }
    }
}

function Save-DocumentationCapture {
    param([string] $FileName)
    $buttons = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button))
    foreach ($button in $buttons) {
        if ($button.Current.Name -like "Acknowledge *hide ribbon until the app closes" -and
            -not $button.Current.IsOffscreen) {
            throw "The test-build ribbon is still visible."
        }
    }
    $path = Join-Path $ScreenshotDirectory $FileName
    Save-UiReviewWindowScreenshot $process.MainWindowHandle $path
    $bounds = Get-UiReviewWindowBounds $process.MainWindowHandle
    $captures.Add([ordered]@{
        file = $FileName
        width = $bounds.Width
        height = $bounds.Height
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        windowTitle = $process.MainWindowTitle
    })
}

try {
    $process = Start-Process -FilePath $AppPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) { throw "App exited with code $($process.ExitCode)." }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw "The app did not open a window." }
    [DocumentationCaptureKeyboard]::AllowForeground()
    Initialize-UiReviewWindow $process.MainWindowHandle
    $area = [System.Windows.Forms.Screen]::FromHandle($process.MainWindowHandle).WorkingArea
    if ($area.Width -lt 1800 -or $area.Height -lt 1340) {
        throw "A hosted desktop of at least 1800x1340 is required; available: $area."
    }
    if (-not [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle,
            [IntPtr]::Zero, $area.Left, $area.Top, 1800, 1340, 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 750
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $buttons = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button))
    foreach ($button in $buttons) {
        if ($button.Current.Name -like "Acknowledge *hide ribbon until the app closes" -and
            -not $button.Current.IsOffscreen) {
            $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Milliseconds 400
        }
    }
    (Find-CaptureElement "Tools").GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 400

    Invoke-CaptureButton "Network troubleshooting"
    $checkpoints = @("Loopback", "LocalAddress", "Gateway", "RouterWan", "Hop2",
        "CloudflarePing", "CloudflareDns", "GooglePing", "GoogleDns")
    Assert-CaptureVisible -Names @("Connection and checks", "Network path and status",
        "Run network troubleshooting", "Ready / not tested",
        "UI-review mode: WAN settings are not loaded or saved, and network probes are disabled.") `
        -Ids @($checkpoints | ForEach-Object { "DiagramAddress$_" })
    $diagram = Find-CaptureElement "DiagramScroll" -Id
    $scroll = $null
    if ($diagram.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref] $scroll) -and
        $scroll.Current.HorizontallyScrollable) {
        throw "The complete network diagram must fit without horizontal scrolling."
    }
    Save-DocumentationCapture "network-troubleshooting.png"
    Invoke-CaptureButton "Back to Tools"

    Invoke-CaptureButton "Speed test"
    Assert-CaptureVisible -Names @("Start Cloudflare speed test") -Ids @("DownloadGauge", "UploadGauge")
    Save-DocumentationCapture "speed-test.png"
    Invoke-CaptureButton "Back to Tools"

    Invoke-CaptureButton "Import from Fing"
    Assert-CaptureVisible -Names @("Browse Fing export", "Analyze again") -Ids @("SelectedFileText")
    $file = Find-CaptureElement "SelectedFileText" -Id
    if ($file.Current.Name -ne "Synthetic Fing export.xlsx") {
        throw "The import capture must use the built-in synthetic export."
    }
    Save-DocumentationCapture "fing-import.png"
    Invoke-CaptureButton "Back to Tools"

    Invoke-CaptureButton "About FingVibe"
    Assert-CaptureVisible -Names @("FingVibe LAN Scanner") `
        -Ids @("VersionText", "BuildKindText", "BuildTimestampText", "CommitText")
    Save-DocumentationCapture "about.png"
    [ordered]@{
        run = $env:GITHUB_RUN_ID
        attempt = $env:GITHUB_RUN_ATTEMPT
        captureRevision = $env:GITHUB_SHA
        reviewMode = $true
        captures = $captures.ToArray()
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ScreenshotDirectory "capture-manifest.json")
}
finally {
    if ($process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force }
    }
    $env:FINGVIBE_UI_REVIEW = $previousReview
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $previousSnapshot
}
