Start-SidebarApp
$area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
$availableWidth = [int] [Math]::Floor($area.Width / $scale)
$expandedWidth = [Math]::Min($ExpandedWindowWidth, $availableWidth)
if ($expandedWidth -lt 1024) { throw "Expanded sidebar checks require a desktop at least 1024 logical pixels wide." }
Write-Host "Testing expanded navigation at $expandedWidth logical pixels, within the available $availableWidth."
Set-SidebarWindowWidth $expandedWidth
