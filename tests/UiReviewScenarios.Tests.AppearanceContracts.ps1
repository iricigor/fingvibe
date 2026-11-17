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
