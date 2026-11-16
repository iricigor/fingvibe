$ErrorActionPreference = "Stop"

function Assert-ActivityGridGlyph($Cell, [string] $Expected) {
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, "$($Cell.Current.AutomationId)-Glyph")
    $glyph = [Windows.Automation.TreeWalker]::new($condition).GetFirstChild($Cell)
    if (-not $glyph -or $glyph.Current.Name -cne $Expected -or $glyph.Current.IsOffscreen -or
        $glyph.Current.BoundingRectangle.Width -le 0 -or $glyph.Current.BoundingRectangle.Height -le 0 -or
        -not $Cell.Current.BoundingRectangle.Contains($glyph.Current.BoundingRectangle)) {
        throw "Activity glyph '$Expected' must be actual visible text contained by '$($Cell.Current.AutomationId)'; got '$($glyph.Current.Name)'."
    }
    return $glyph
}

function Initialize-ActivityGridAppearance {
    if ($env:GITHUB_ACTIONS -ne "true") { throw "Activity appearance checks require a disposable GitHub Actions desktop." }
    if ("ActivityGridReviewAppearance" -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ActivityGridReviewAppearance {
    [StructLayout(LayoutKind.Sequential)] private struct HC { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref HC value, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, UIntPtr parameter, string value, uint flags, uint timeout, out UIntPtr result);
    public static uint GetContrast() {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void SetContrast(uint flags) {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void NotifyTextScale() {
        UIntPtr result;
        if (SendMessageTimeout(new IntPtr(0xffff), 0x001a, UIntPtr.Zero, "Accessibility", 2, 2000, out result) == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}

function Invoke-ActivityGridHighContrast([scriptblock] $Check) {
    Initialize-ActivityGridAppearance
    $original = [ActivityGridReviewAppearance]::GetContrast()
    $failed = $true
    try {
        [ActivityGridReviewAppearance]::SetContrast($original -bor 1)
        $null = Wait-UiRegressionState -Description "Activity high contrast enabled" -Condition {
            ([ActivityGridReviewAppearance]::GetContrast() -band 1) -ne 0
        }
        Start-Sleep -Seconds 2
        $null = & $Check
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @({
            [ActivityGridReviewAppearance]::SetContrast($original)
            $null = Wait-UiRegressionState -Description "Activity high contrast restored" -Condition {
                [ActivityGridReviewAppearance]::GetContrast() -eq $original
            }
        })
    }
}

function Invoke-ActivityGridLargeText([string] $AppPath, [scriptblock] $Check) {
    Initialize-ActivityGridAppearance
    Add-Type -Path (Join-Path (Split-Path $AppPath) "WinRT.Runtime.dll")
    Add-Type -Path (Join-Path (Split-Path $AppPath) "Microsoft.Windows.SDK.NET.dll")
    $settings = [Windows.UI.ViewManagement.UISettings]::new()
    $originalScale = $settings.TextScaleFactor
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Microsoft\Accessibility")
    $originalValue = $key.GetValue("TextScaleFactor", $null)
    $originalKind = if ($null -ne $originalValue) { $key.GetValueKind("TextScaleFactor") } else { $null }
    $failed = $true
    try {
        $key.SetValue("TextScaleFactor", 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [ActivityGridReviewAppearance]::NotifyTextScale()
        $null = Wait-UiRegressionState -Description "Activity effective 200 percent text scale" -Condition {
            [Math]::Abs($settings.TextScaleFactor - 2) -lt .01
        }
        $null = & $Check
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @({
            if ($null -eq $originalValue) { $key.DeleteValue("TextScaleFactor", $false) }
            else { $key.SetValue("TextScaleFactor", $originalValue, $originalKind) }
            [ActivityGridReviewAppearance]::NotifyTextScale()
            $null = Wait-UiRegressionState -Description "Activity text scale restored" -Condition {
                [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt .01
            }
        }, { $key.Dispose() })
    }
}
