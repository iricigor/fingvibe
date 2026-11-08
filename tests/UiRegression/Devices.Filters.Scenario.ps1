Test-ExpandableDeviceFilters
Assert-FilterPresentation InventoryStatusFilter Status
Assert-FilterPresentation PersonFilter Person
Assert-FilterPresentation RoomFilter Room
Set-DeviceFilterChoice InventoryStatusFilter Online
Assert-FilterPresentation InventoryStatusFilter Status Online
$null = Save-DeviceCapture "devices-selected-status-filter"
Set-DeviceFilterChoice InventoryStatusFilter Unknown
Assert-FilterPresentation InventoryStatusFilter Status Unknown
if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 0 of 80 devices") {
    throw "Unknown remains a meaningful status filter."
}
Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
Assert-FilterPresentation InventoryStatusFilter Status
Set-DeviceFilterChoice PersonFilter Unassigned
Assert-FilterPresentation PersonFilter Person Unassigned
Set-DeviceFilterChoice PersonFilter "All people"
Set-DeviceFilterChoice RoomFilter Unassigned
Assert-FilterPresentation RoomFilter Room Unassigned
Set-DeviceFilterChoice RoomFilter "All rooms"
if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") { throw "All options must reset filters." }
Test-FilterChips
