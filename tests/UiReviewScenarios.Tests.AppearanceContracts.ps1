# Page contracts: review appearance selection.
& {
    . (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
    $choices = [System.Collections.Generic.List[string]]::new()
    function Set-UiReviewAppearanceChoice {
        param($Root, [string] $Picker, [string] $Choice)
        $choices.Add("$Picker=$Choice")
    }
    $expectedChoices = @(
        @("ModePicker=Light", "ThemePicker=Standard"),
        @("ModePicker=Light", "ThemePicker=Warm"),
        @("ModePicker=Light", "ThemePicker=Colorful"),
        @("ModePicker=Dark", "ThemePicker=Standard"),
        @("ModePicker=Dark", "ThemePicker=True Black (OLED)"),
        @("ModePicker=Dark", "ThemePicker=Colorful")
    )
    Assert-Equal $UiReviewAppearanceThemes.Count 6 "Every appearance variant has UI coverage"
    for ($index = 0; $index -lt $UiReviewAppearanceThemes.Count; $index++) {
        $choices.Clear()
        Set-UiReviewTheme -Root ([pscustomobject]@{}) -Theme $UiReviewAppearanceThemes[$index]
        Assert-Equal $choices $expectedChoices[$index] "Select mode before its theme"
    }
    Assert-Throws { Set-UiReviewTheme -Root ([pscustomobject]@{}) -Theme "Unknown" } "*Cannot validate argument*"
}

& {
    function Get-StatusBadgeLuminance([string] $Color) {
        $channels = @(1, 3, 5 | ForEach-Object {
            $value = [Convert]::ToInt32($Color.Substring($_, 2), 16) / 255.0
            if ($value -le 0.04045) { $value / 12.92 }
            else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
        })
        return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
    }
    [xml] $devices = Get-Content (Join-Path $PSScriptRoot '..\src\FingVibe.App\Views\DevicesPageView.xaml') -Raw
    $statusCell = $devices.SelectSingleNode("//*[local-name()='Grid' and @*[local-name()='Name']='DeviceStatusCell']")
    $badges = @($statusCell.SelectNodes("*[local-name()='Border']"))
    Assert-Equal $statusCell.GetAttribute('ToolTipService.ToolTip') '{x:Bind StatusContext, Mode=OneWay}' "Status evidence help refreshes with reused scan rows"
    foreach ($case in @(
        @('IsOffline', 'StatusChoiceOfflineBrush', 'OfflineRowBadgeBackgroundBrush'),
        @('IsFingOnly', 'StatusChoiceFingOnlyBrush', 'FingOnlyRowBadgeBackgroundBrush'),
        @('IsHistorical', 'ScannerOfflineForegroundBrush', 'ScannerOfflineBackgroundBrush')
    )) {
        $badge = @($badges | Where-Object Visibility -eq "{x:Bind $($case[0]), Mode=OneWay}")
        Assert-Equal $badge.Count 1 "$($case[0]) has one badge"
        Assert-Equal $badge[0].Background "{ThemeResource $($case[2])}" "$($case[0]) badge background"
        Assert-Equal $badge[0].StackPanel.Ellipse.Fill "{ThemeResource $($case[1])}" "$($case[0]) badge dot"
        Assert-Equal $badge[0].StackPanel.TextBlock.Foreground "{ThemeResource $($case[1])}" "$($case[0]) badge text"
        Assert-Equal $badge[0].StackPanel.TextBlock.Text '{x:Bind StatusLabel, Mode=OneWay}' "Refresh status labels with reused scan rows"
    }
    Assert-Equal $badges[-1].Visibility '{x:Bind IsHistorical, Mode=OneWay}' "Neutral historical badge refreshes when a scan confirms current evidence"
    $onlineBadge = @($badges | Where-Object Visibility -eq '{x:Bind IsOnline, Mode=OneWay}')
    Assert-Equal $onlineBadge.Count 1 "Online badge refreshes with reused scan rows"
    Assert-Equal $onlineBadge[0].StackPanel.TextBlock.Text '{x:Bind StatusLabel, Mode=OneWay}' "Online label refreshes after status changes"
    foreach ($theme in @('Light', 'Dark', 'HighContrast')) {
        $dictionary = $devices.SelectSingleNode("//*[local-name()='ResourceDictionary' and @*[local-name()='Key']='$theme']")
        foreach ($key in @('OfflineRowBadgeBackgroundBrush', 'FingOnlyRowBadgeBackgroundBrush')) {
            $brush = $dictionary.SelectSingleNode("*[local-name()='SolidColorBrush' and @*[local-name()='Key']='$key']")
            if (-not $brush) { throw "$theme lacks $key." }
            if ($theme -eq 'HighContrast') {
                Assert-Equal $brush.Color '{ThemeResource SystemColorWindowColor}' "High contrast badge background uses system colors"
            }
        }
        if ($theme -eq 'HighContrast') {
            foreach ($key in @('StatusChoiceOfflineBrush', 'StatusChoiceFingOnlyBrush')) {
                $brush = $dictionary.SelectSingleNode("*[local-name()='SolidColorBrush' and @*[local-name()='Key']='$key']")
                Assert-Equal $brush.Color '{ThemeResource SystemColorWindowTextColor}' "High contrast status text uses system colors"
            }
        } else {
            foreach ($case in @(
                @('StatusChoiceOfflineBrush', 'OfflineRowBadgeBackgroundBrush'),
                @('StatusChoiceFingOnlyBrush', 'FingOnlyRowBadgeBackgroundBrush')
            )) {
                $foreground = $dictionary.SelectSingleNode("*[local-name()='SolidColorBrush' and @*[local-name()='Key']='$($case[0])']")
                $background = $dictionary.SelectSingleNode("*[local-name()='SolidColorBrush' and @*[local-name()='Key']='$($case[1])']")
                $fg = Get-StatusBadgeLuminance $foreground.Color
                $bg = Get-StatusBadgeLuminance $background.Color
                $contrast = ([Math]::Max($fg, $bg) + 0.05) / ([Math]::Min($fg, $bg) + 0.05)
                if ($contrast -lt 4.5) { throw "$theme $($case[0]) badge text contrast is $contrast; expected at least 4.5:1." }
            }
        }
    }
}
