function Get-UiReviewDeviceTab {
    param([Parameter(Mandatory)] $Root, [ValidateSet("Overview", "History")] [string] $Tab)
    $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "Device${Tab}Tab"))
    if (-not $element) { throw "Missing Device Details $Tab tab." }
    return $element
}

function Select-UiReviewDeviceTab {
    param([Parameter(Mandatory)] $Root, [ValidateSet("Overview", "History")] [string] $Tab)
    $element = Get-UiReviewDeviceTab -Root $Root -Tab $Tab
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (-not $pattern.Current.IsSelected) { $pattern.Select() }
    $id = if ($Tab -eq "History") { "DeviceHistoryScroll" } else { "DeviceDetailsScroll" }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $viewport = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
        if ($pattern.Current.IsSelected -and $viewport -and -not $viewport.Current.IsOffscreen) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Device Details $Tab tab did not expose its viewport."
}

function Get-UiReviewDeviceDetailsScrollId {
    param([Parameter(Mandatory)] $Root)
    $history = Get-UiReviewDeviceTab -Root $Root -Tab History
    if ($history.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) {
        return "DeviceHistoryScroll"
    }
    return "DeviceDetailsScroll"
}
