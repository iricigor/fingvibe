$null = Find-SidebarElement Name FingVibe
$null = Find-SidebarElement Name "LAN scanner"
foreach ($page in @(
    @("Network", "Public IP address"),
    @("Devices", "Search devices"),
    @("Rooms", "Search rooms"),
    @("Tools", "Speed test"),
    @("Settings", "Window backdrop"),
    @("Overview", "Online devices"),
    @("People", "Search people")
)) {
    Select-SidebarPage $page[0] $page[1]
    Assert-SharedNetworkHeader
}
$network = Find-SidebarElement AutomationId NetworkNavItem
$menuBounds = $network.Current.BoundingRectangle
if ([Math]::Abs($menuBounds.Width / $scale - 200) -gt 4) {
    throw "Expanded navigation rows must fit the 216px pane; got $($menuBounds.Width / $scale)px."
}
$settings = Find-SidebarElement Name Settings
$tools = Find-SidebarElement AutomationId ToolsNavItem
$windowBounds = Get-UiReviewWindowBounds $windowHandle
if ($settings.Current.BoundingRectangle.Top -lt $windowBounds.Top + $windowBounds.Height / 2) {
    throw "Settings must remain pinned in the bottom of the sidebar."
}
if ($tools.Current.BoundingRectangle.Bottom -gt $settings.Current.BoundingRectangle.Top -or
    $tools.Current.BoundingRectangle.Top -lt $windowBounds.Top + $windowBounds.Height / 2) {
    throw "Tools must remain pinned directly above Settings."
}
Save-SidebarAppearance "sidebar-expanded" -AssertMatchingSolid
Test-SidebarResizing
