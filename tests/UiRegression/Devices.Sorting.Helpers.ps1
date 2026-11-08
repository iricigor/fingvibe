function Invoke-DeviceSort([string] $ButtonId, [string] $GlyphId, [bool] $Ascending) {
    (Find-DeviceElement $ButtonId).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 350
    $expected = if ($Ascending) { [string][char]0x2191 } else { [string][char]0x2193 }
    if ((Find-DeviceElement $GlyphId).Current.Name -ne $expected) {
        throw "'$ButtonId' did not show the expected sort direction."
    }
}

function Assert-SortedFixture([string] $Column, [bool] $Ascending, [object[]] $ExpectedRows) {
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $ExpectedRows) { $ordered.Add($item) }
    $ordered.Sort([System.Comparison[object]] {
        param($left, $right)
        if ($Column -in @("Person", "Room")) {
            $missing = [string]::IsNullOrEmpty($left[$Column]).CompareTo([string]::IsNullOrEmpty($right[$Column]))
            if ($missing -ne 0) { return $missing }
        }
        $comparison = if ($Column -eq "OpenPorts") {
            $left.OpenPorts.CompareTo($right.OpenPorts)
        } else {
            [string]::Compare($left[$Column], $right[$Column], [StringComparison]::OrdinalIgnoreCase)
        }
        if ($comparison -eq 0) {
            $comparison = [string]::Compare($left.Mac, $right.Mac, [StringComparison]::Ordinal)
        }
        if (-not $Ascending) { $comparison = -$comparison }
        return $comparison
    })
    $scroll = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Start-Sleep -Milliseconds 350
    $rows = @(Get-DeviceRows)
    if ($rows.Count -lt 4) { throw "Sorting fixture must realize at least four rows." }
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $address = ($rows[$index].Current.HelpText -split "`n" |
            Where-Object { $_.StartsWith("IP address: ") }) -replace "^IP address: ", ""
        if ($address -ne $ordered[$index].Address) {
            throw "$Column ascending=${Ascending}: row $index is '$address', expected '$($ordered[$index].Address)'."
        }
    }
}

function Test-DeviceColumnSorting {
    Set-DeviceWidth 1880
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Set-DeviceFilterChoice CompactRowsSwitch Standard
    Select-DevicePage DevicesNavItem
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue("127.0.0.1")
    $expected = @($results | Where-Object { $_.address -eq "127.0.0.1" -or $_.address -match "^127\.0\.0\.1[0-9]$" } |
        ForEach-Object { @{
            Address = $_.address; Name = $_.deviceName; Vendor = $_.vendorName
            OpenPorts = $_.openPorts.Count; Mac = $_.macAddress; Person = ""; Room = ""; LastSeen = ""
        } })
    foreach ($merged in @($false, $true)) {
        Select-DevicePage Settings
        foreach ($label in @("Combine Name and Type", "Combine Vendor and OS", "Combine Person and Room")) {
            Set-ColumnOption $label $merged
        }
        Select-DevicePage DevicesNavItem
        foreach ($column in @("Name", "Vendor", "OpenPorts", "Person", "Room")) {
            $prefix = if ($merged -and $column -in @("Person", "Room")) { "Merged$column" } else { $column }
            foreach ($ascending in @($true, $false)) {
                Invoke-DeviceSort "${prefix}SortButton" "${prefix}SortGlyph" $ascending
                Assert-SortedFixture $column $ascending $expected
            }
        }
    }

    # Assignment edits must reorder an already-active sort without selecting it again.
    $search.SetValue("Fixture device 01")
    Start-Sleep -Milliseconds 350
    $row = @(Get-DeviceRows)[0]
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x0D)
    Start-Sleep -Milliseconds 350
    $detailsScroll = (Find-DeviceElement DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($detailsScroll.Current.VerticallyScrollable) { $detailsScroll.SetScrollPercent(-1, 0) }
    Set-DeviceFilterChoice DevicePersonPicker "UI · UI review person"
    Set-DeviceFilterChoice DeviceRoomPicker "UI · UI review room"
    Select-DevicePage DevicesNavItem
    $search.SetValue("127.0.0.1")
    $first = $expected | Where-Object { $_.Address -eq "127.0.0.1" }
    $first.Person = "UI review person"
    $first.Room = "UI review room"
    Assert-SortedFixture Room $false $expected
    if ((Find-DeviceElement MergedRoomSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Assignment updates lost the selected sort direction."
    }
    Invoke-DeviceSort MergedPersonSortButton MergedPersonSortGlyph $true
    Assert-SortedFixture Person $true $expected
    Invoke-DeviceSort MergedPersonSortButton MergedPersonSortGlyph $false
    Assert-SortedFixture Person $false $expected

    # Room-only uses the assignment slot, not the separate or merged Room header.
    Select-DevicePage Settings
    Set-ColumnOption "Person" $false
    Select-DevicePage DevicesNavItem
    Invoke-DeviceSort RoomOnlySortButton RoomOnlySortGlyph $true
    Assert-SortedFixture Room $true $expected
    Invoke-DeviceSort RoomOnlySortButton RoomOnlySortGlyph $false
    Assert-SortedFixture Room $false $expected
    Select-DevicePage Settings
    Set-ColumnOption "Person" $true
    Select-DevicePage DevicesNavItem
    if ((Find-DeviceElement MergedRoomSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Switching assignment layout lost the selected sort."
    }

    # Every fixture row responded in the displayed scan, so equal Last seen values fall back to MAC order.
    foreach ($ascending in @($true, $false)) {
        Invoke-DeviceSort LastSeenSortButton LastSeenSortGlyph $ascending
        Assert-SortedFixture LastSeen $ascending $expected
    }
    foreach ($row in @(Get-DeviceRows)) {
        $lastSeen = Get-VisibleDeviceChild $row AutomationId DeviceLastSeenText
        if (-not $lastSeen -or $lastSeen.Current.Name -notlike "Last seen: Online - responded in the displayed scan (*)") {
            throw "Current responses must show Online with an exact accessible timestamp."
        }
        $rendered = $lastSeen.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
        if ($rendered -cne "Online") { throw "Current responses must render Online, not '$rendered'." }
        if ($row.Current.HelpText -notlike "*`nLast seen: Online - responded in the displayed scan (*)*") {
            throw "Row values must include the full Last seen value."
        }
    }

    Invoke-DeviceSort NameSortButton NameSortGlyph $true
    Invoke-DeviceSort NameSortButton NameSortGlyph $false
    $search.SetValue("Fixture device 01")
    Start-Sleep -Milliseconds 350
    $row = @(Get-DeviceRows)[0]
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x0D)
    Start-Sleep -Milliseconds 350
    (Find-DeviceElement DeviceRenameButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    (Find-DeviceElement DeviceNameInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("ZZ sorting update")
    # The Save action is enabled by the asynchronous text-changed handler.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Find-DeviceElement DeviceNameSaveButton).Current.IsEnabled -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    (Find-DeviceElement DeviceNameSaveButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $saved = (Find-DeviceElement DeviceNameSaveButton).Current.Name -like "*Saved"
    } while (-not $saved -and [DateTime]::UtcNow -lt $deadline)
    if (-not $saved) { throw "Sorting fixture name update was not saved." }
    Select-DevicePage DevicesNavItem
    $first.Name = "ZZ sorting update"
    $search.SetValue("127.0.0.1")
    Assert-SortedFixture Name $false $expected
    Clear-DeviceFilters
    if ((Find-DeviceElement NameSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Clearing filters lost the selected sort direction."
    }
    $null = Save-DeviceCapture "devices-column-sorting"
}
