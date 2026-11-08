Switch-SidebarPane
$compactWidth = (Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale
if ($compactWidth -ge 80) { throw "Closing the expanded pane must leave a compact icon rail." }
Select-SidebarPage Network "Public IP address"
$network = Find-SidebarElement AutomationId NetworkNavItem
$network.SetFocus()
[SidebarReviewKeyboard]::Tap(0x28)
[SidebarReviewKeyboard]::Tap(0x0D)
$null = Find-SidebarElement Name "Search devices"
Start-Sleep -Milliseconds 350
Save-SidebarAppearance "sidebar-compact"
Switch-SidebarPane

foreach ($width in @(800, 640)) {
    Set-SidebarWindowWidth $width
    Switch-SidebarPane
    $null = Find-SidebarElement Name "LAN scanner"
    Resize-SidebarPane @(280)
    Assert-SidebarPaneWidth 280
    Resize-SidebarPane @(216)
    Save-SidebarAppearance "sidebar-overlay-$width" -AssertMatchingSolid
    Select-SidebarPage People "Search people"
    if ($width -eq 640 -and (Find-SidebarElement AutomationId NavigationResizeGrip -Optional)) {
        throw "A closed minimal-mode pane must not leave a resize divider over page content."
    }
}
Write-Host "Sidebar navigation, expanded/compact/overlay layouts, and matching solid backgrounds in all six themes passed; material captures saved."
