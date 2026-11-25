function Find-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
    $propertyId = if ($Property -eq 'Name') {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    # Wait-UiRegressionState's $Condition parameter shadows caller variables in callbacks.
    $peopleRoomsCondition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    if ($OwnerId -in @('PersonDetailPage', 'RoomDetailPage', 'PeopleRoomsPage', 'RoomMapPage', 'PeopleRoomsDialog')) {
        $getPage = {
            $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $OwnerId))
        }
        $getTarget = {
            $page = & $getPage
            if (-not $page) { return }
            $match = $page.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $peopleRoomsCondition)
            if (-not $match) {
                $match = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $peopleRoomsCondition)
            }
            $match
        }
        $target = Wait-UiRegressionState -Description "$OwnerId '$Value' peer" -Condition $getTarget
        if ($target.Current.IsKeyboardFocusable) {
            $target.SetFocus()
            $scrollItem = $null
            if ($target.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
                $scrollItem.ScrollIntoView()
            }
        }
        else {
            $null = Show-UiRegressionScrollTargets -Description "$OwnerId '$Value'" `
                -GetViewport $getPage -GetTargets $getTarget -GetWindow { $root }
        }
    }
    Find-UiRegressionElement -Condition $peopleRoomsCondition -Description "People/Rooms '$Value'" -Container {
        if (-not $OwnerId) {
            $dialog = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PeopleRoomsDialog'))
            if (Test-UiRegressionElementVisible $dialog) { return $dialog }
            return $root
        }
        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $OwnerId))
    } -Find {
        param($Owner, $Match)
        $matches = @($Owner.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Match) |
            Where-Object { Test-UiRegressionElementVisible $_ })
        if ($matches.Count -eq 0 -and $OwnerId -in @('PersonDetailPage', 'RoomDetailPage')) {
            $matches = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Match) |
                Where-Object { Test-UiRegressionElementVisible $_ })
        }
        $matches | Select-Object -First 1
    }
}

function Invoke-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
    if ($Property -eq 'AutomationId' -and $Value -eq 'PersonIconPicker') { $OwnerId = 'PeopleRoomsDialog' }
    if (-not $OwnerId -and $Property -eq 'Name' -and $Value -in @('Save', 'Cancel', 'Delete', 'Assign')) {
        $OwnerId = 'PeopleRoomsDialog'
    }
    (Find-PeopleRoomsElement $Property $Value $OwnerId).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ($Property -eq 'Name' -and $Value -in @('Cancel', 'Delete')) {
        $null = Wait-UiRegressionState -Description "People/Rooms '$Value' dialog dismissal" -Condition {
            $dialog = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PeopleRoomsDialog'))
            -not (Test-UiRegressionElementVisible $dialog)
        }
    }
}

function Set-PeopleRoomsText([string] $Name, [string] $Value) {
    $editCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit))
    $edit = Wait-UiRegressionState -Description "editable People/Rooms '$Name'" -Condition {
        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
    }
    $edit.SetFocus()
    $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}

function Open-PeopleRoomsDetails([string] $Name, [string] $PageId) {
    $element = Find-PeopleRoomsElement Name $Name $PageId
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    while ($element -and $element.Current.ControlType -ne [System.Windows.Automation.ControlType]::ListItem) {
        $element = $walker.GetParent($element)
    }
    if (-not $element) { throw "No list item owns '$Name'." }
    $element.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x0D)
}

function Invoke-RoomMapBack([string] $ExpectedName) {
    $back = Find-PeopleRoomsElement AutomationId RoomMapBackButton RoomMapPage
    if ($back.Current.Name -cne $ExpectedName) {
        throw "Room map Back must name its entry page '$ExpectedName', not '$($back.Current.Name)'."
    }
    $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Test-RoomMapEntries {
    Select-SidebarPage 'People & rooms' 'Search people and rooms'
    Invoke-PeopleRoomsElement AutomationId ViewRoomMapButton PeopleRoomsPage
    # Never name this $root: helper callbacks resolve the window root through dynamic scope.
    $gateway = Find-PeopleRoomsElement AutomationId RoomMapRootPlaceholder RoomMapPage
    if ($gateway.Current.IsKeyboardFocusable -ne $true) { throw 'The Room map gateway fallback must remain keyboard reachable.' }
    $unassigned = Find-PeopleRoomsElement AutomationId RoomMapUnassigned RoomMapPage
    if ($unassigned.Current.IsKeyboardFocusable -ne $true) { throw 'The Room map unassigned strip must remain keyboard reachable.' }
    Invoke-RoomMapBack 'Back to Rooms'
    $null = Find-PeopleRoomsElement Name 'Search people and rooms' PeopleRoomsPage

    Select-SidebarPage 'Tools' 'View room map'
    Invoke-PeopleRoomsElement Name 'View room map'
    Invoke-RoomMapBack 'Back to Tools'
    $null = Find-PeopleRoomsElement AutomationId RoomMapCard

    Select-SidebarPage 'Tools' 'Network health'
    Invoke-PeopleRoomsElement Name 'Network health'
    # The visible "Run diagnostics" button is exposed to UI Automation as "Run network diagnostics".
    $null = Find-PeopleRoomsElement AutomationId RunButton
    # Saved incident history sits above the manual diagnostic path, so scroll the entry into view like a user would.
    $null = Show-UiRegressionScrollTargets -Description "Network health Room map entry" -GetWindow { $root } -GetViewport {
        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NetworkHealthScroll'))
    } -GetTargets {
        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NetworkHealthViewRoomMapButton'))
    }
    Invoke-PeopleRoomsElement AutomationId NetworkHealthViewRoomMapButton
    Invoke-RoomMapBack 'Back to Network health'
    # Network health keeps the scroll position of its Room map entry and returns keyboard focus to that entry.
    $null = Wait-UiRegressionState -Description 'Network health Room map entry focused after Back' -Condition {
        $entry = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NetworkHealthViewRoomMapButton'))
        if ((Test-UiRegressionElementVisible $entry) -and $entry.Current.HasKeyboardFocus) { $entry }
    }
    Write-Host 'Room map entry points, conceptual gateway fallback, focus reachability and origin-aware Back passed.'
}

function Test-RoomMapDetailsRoundTrip {
    $inventory = Join-Path (Join-Path $fixtureDirectory 'room-map-scale') 'inventory.json'
    if (-not (Test-Path -LiteralPath $inventory)) { throw 'Test-RoomMapScale must create the Room map scale fixture first.' }
    $savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
    Stop-SidebarApp
    try {
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage 'Tools' 'View room map'
        Invoke-PeopleRoomsElement Name 'View room map'

        $roomId = '00000000-0000-0000-0000-000000000004'
        $room = Find-PeopleRoomsElement AutomationId "RoomMapOpenRoom-$roomId" RoomMapPage
        $room.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $roomBack = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Back to Room map')) `
            -Description 'Room details return to Room map' -Container { $root }
        if ($roomBack.Current.AutomationId -ne 'RoomBackButton') {
            throw "Room details must expose the origin-aware Room map Back action."
        }
        $roomBack.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $returnedRoom = Wait-UiRegressionState -Description 'Room map room origin restored' -Condition {
            $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    "RoomMapOpenRoom-$roomId"))
            if ($candidate -and -not $candidate.Current.IsOffscreen) { $candidate }
        }
        if (-not $returnedRoom.Current.HasKeyboardFocus) {
            throw 'Returning from Room Details must restore focus to the originating room-name action.'
        }

        $device = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        $scrollViewer = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll')) `
            -Description 'Room map round-trip scroll viewer' -Container {
                $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage'))
            }
        $scroll = $scrollViewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        $horizontal = $scroll.Current.HorizontalScrollPercent
        $vertical = $scroll.Current.VerticalScrollPercent
        if ($horizontal -le 0 -and $vertical -le 0) {
            throw 'The round-trip test must begin from a scrolled Room map position.'
        }
        $device.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $deviceBack = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Back to Room map')) `
            -Description 'Device details return to Room map' -Container { $root }
        if ($deviceBack.Current.AutomationId -ne 'DeviceBackButton') {
            throw "Device Details must expose the origin-aware Room map Back action."
        }
        $deviceBack.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $returnedDevice = Wait-UiRegressionState -Description 'Room map device origin restored' -Condition {
            $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    'RoomMapDevice-001122000063'))
            if ($candidate -and -not $candidate.Current.IsOffscreen) { $candidate }
        }
        $restoredViewer = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll')) `
            -Description 'restored Room map scroll viewer' -Container {
                $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage'))
            }
        $restoredScroll = $restoredViewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if (-not $returnedDevice.Current.HasKeyboardFocus -or
            [Math]::Abs($restoredScroll.Current.HorizontalScrollPercent - $horizontal) -gt 1 -or
            [Math]::Abs($restoredScroll.Current.VerticalScrollPercent - $vertical) -gt 1) {
            throw 'Returning from Device Details must restore the originating device focus and Room map scroll position.'
        }
        Invoke-RoomMapBack 'Back to Tools'
        $null = Find-PeopleRoomsElement AutomationId RoomMapCard
        Write-Host 'Room map device and room detail round trips restored origin focus, scroll state and Back destination.'
    }
    finally {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
    }
}

function Test-RoomMapAppearance([string] $Name) {
    Select-SidebarPage 'Tools' 'View room map'
    Invoke-PeopleRoomsElement Name 'View room map'
    $null = Find-PeopleRoomsElement AutomationId RoomMapRootPlaceholder RoomMapPage
    Save-SidebarAppearance "room-map-$Name" -AssertMatchingSolid
    Invoke-RoomMapBack 'Back to Tools'
    $null = Find-PeopleRoomsElement AutomationId RoomMapCard
}

function Test-RoomMapThemes {
    # Room map theme captures run with the Room map group, which owns its origin-aware navigation.
    $mode = Get-SidebarAppearanceSelection ModePicker
    $style = Get-SidebarAppearanceSelection ThemePicker
    $highContrast = $null
    $themesFailed = $true
    try {
        foreach ($theme in @('Standard Light', 'Standard Dark')) {
            Set-SidebarAppearance ThemePicker $theme
            Test-RoomMapAppearance ($theme.Replace(' ', '-').ToLowerInvariant())
        }
        $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
        if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw 'High contrast did not activate.' }
        Start-Sleep -Seconds 2
        Test-RoomMapAppearance 'high-contrast'
        $themesFailed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $themesFailed -Steps @(
            {
                if ($null -ne $highContrast) {
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
                    Start-Sleep -Seconds 2
                }
            },
            {
                Select-SidebarPage Settings "Window backdrop"
                Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice $mode
                Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice $style
            })
    }
}

function Test-RoomMapScale {
    $savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
    $scaleDirectory = Join-Path $fixtureDirectory 'room-map-scale'
    $inventory = Join-Path $scaleDirectory 'inventory.json'
    $rooms = @()
    $assignments = @{}
    $devices = @{}
    $names = @{}
    for ($roomIndex = 0; $roomIndex -lt 10; $roomIndex++) {
        $id = "00000000-0000-0000-0000-{0:D12}" -f ($roomIndex + 1)
        $rooms += @{ id = $id; name = "Scale room $roomIndex"; shortName = "R$($roomIndex.ToString('D2'))" }
    }
    for ($deviceIndex = 0; $deviceIndex -lt 100; $deviceIndex++) {
        $mac = "001122{0:X6}" -f $deviceIndex
        $room = $rooms[$deviceIndex % 10].id
        $timestamp = [DateTimeOffset]::new(2026, 11, 17, 12, 0, 0, [TimeSpan]::Zero).ToString('o')
        $devices[$mac] = @{
            mac = $mac; imported = @{}
            observations = @(@{
                networkId = 'ui-review-network'; subnet = '127.0.0.1/32'; address = '127.0.0.1'
                hostname = "scale-$deviceIndex"; vendor = 'Synthetic'; ports = @(); latency = 1
                probeDuration = '00:00:00.001'
                classification = @{ type = $(if ($deviceIndex % 8 -eq 0) { 3 } else { 1 });
                    operatingSystem = 0; typeEvidence = 'Fixture'; operatingSystemEvidence = 'Fixture' }
                firstSeen = $timestamp; lastSeen = $timestamp; lastChecked = $timestamp
                present = $deviceIndex % 5 -ne 0
            })
            scanHistory = @()
        }
        $names[$mac] = "Scale device $($deviceIndex.ToString('D2'))"
        $assignments[$mac] = @{ roomId = $room }
    }
    $data = @{
        revision = [Guid]::NewGuid().ToString(); devices = $devices; names = $names; classifications = @{}
        peopleRooms = @{ people = @(); rooms = $rooms; assignments = $assignments }
        virtualDevices = @(); discoveryBaselines = @()
    }
    Stop-SidebarApp
    try {
        $null = New-Item -ItemType Directory -Path $scaleDirectory -Force
        @{ version = 4; data = $data } | ConvertTo-Json -Depth 15 |
            Set-Content -LiteralPath $inventory -Encoding UTF8
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage 'Tools' 'View room map'
        $layoutClock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-PeopleRoomsElement Name 'View room map'
        $page = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage')) `
            -Description 'Room map scale page' -Container { $root }
        $onlineOnly = Find-PeopleRoomsElement AutomationId RoomMapOnlineOnlySwitch RoomMapPage
        $onlineOnlyToggle = $onlineOnly.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if ($onlineOnlyToggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
            throw 'The Room map Only online switch must be on by default.'
        }
        $elements = $page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $deviceElements = @($elements | Where-Object {
            $_.Current.AutomationId -like 'RoomMapDevice-*'
        })
        $roomElements = @($elements | Where-Object {
            $_.Current.AutomationId -like 'RoomMapRoom-*'
        })
        if ($deviceElements.Count -ne 80) {
            throw "Only online must show the 80 online devices by default; found $($deviceElements.Count)."
        }
        $shownIds = @($deviceElements | ForEach-Object { $_.Current.AutomationId })
        if ($shownIds -contains 'RoomMapDevice-001122000000') {
            throw 'Only online exposed an offline Room map device.'
        }
        if ($roomElements.Count -ne 10) { throw "The Room map must retain all ten saved rooms; found $($roomElements.Count)." }
        $onlineOnlyToggle.Toggle()
        $null = Wait-UiRegressionState -Description 'all Room map devices after disabling Only online' -Condition {
            $current = $page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.AutomationId -like 'RoomMapDevice-*' }
            @($current).Count -eq 100
        }
        $elements = $page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $deviceElements = @($elements | Where-Object {
            $_.Current.AutomationId -like 'RoomMapDevice-*'
        })
        if ($deviceElements.Count -ne 100) {
            throw "Turning off Only online must show all 100 relevant devices; found $($deviceElements.Count)."
        }
        $layoutClock.Stop()
        $last = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        if ($last.Current.IsKeyboardFocusable -ne $true) { throw 'The last Room map device must remain keyboard reachable.' }
        if ($last.Current.IsOffscreen -ne $false) { throw 'The focused last Room map device must be brought into view.' }
        @{
            rooms = $roomElements.Count
            onlineDevicesByDefault = 80
            allDevices = $deviceElements.Count
            layoutAndRenderSeconds = $layoutClock.Elapsed.TotalSeconds
            focusedFinalDevice = $last.Current.AutomationId
        } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'room-map-scale.json') -Encoding UTF8
        Write-Host "Room map rendered 10 rooms, hid 20 offline devices by default, restored all 100 devices, and reached the final keyboard target in $($layoutClock.Elapsed.TotalSeconds.ToString('F2')) seconds."
    }
    finally {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
    }
}

function Get-SidebarAppearanceSelection([string] $Picker) {
    Select-SidebarPage Settings "Window backdrop"
    Expand-UiReviewSettingsSection -Root $root -Section AppearanceSection
    $combo = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Picker)) `
        -Description "appearance picker '$Picker'" -Container { $root }
    $selected = $combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    if ($selected.Count -ne 1) { throw "Appearance picker '$Picker' must have one selected choice." }
    $selected[0].Current.Name
}

function Assert-RoomMapConnectionInk([string] $Name, [double] $TextScale) {
    # Connection paths are Raw-view shapes without control peers, so legibility is measured from rendered pixels on
    # the shared trunk in the root gutter: it runs down from the root-entry anchor, and nothing is drawn above it.
    $page = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage')) `
        -Description 'Room map connection page' -Container { $root }
    $rootRoom = @($page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
            $_.Current.AutomationId -eq 'RoomMapRootPlaceholder' -or
                ($_.Current.AutomationId -like 'RoomMapRoom-*' -and $_.Current.Name -like '*, root room*')
        })
    if ($rootRoom.Count -ne 1) { throw "The Room map must show one root room for '$Name'." }
    $scrollViewer = $page.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll'))
    if ($scrollViewer) {
        $scroll = $scrollViewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable -or $scroll.Current.HorizontallyScrollable) {
            $scroll.SetScrollPercent($(if ($scroll.Current.HorizontallyScrollable) { 0 } else { -1 }),
                $(if ($scroll.Current.VerticallyScrollable) { 0 } else { -1 }))
            Start-Sleep -Milliseconds 300
        }
        if ($scroll.Current.VerticallyScrollable) {
            $windowBounds = $root.Current.BoundingRectangle
            $viewportBounds = $scrollViewer.Current.BoundingRectangle
            $viewportTopValue = if (-not [double]::IsNaN($viewportBounds.Top) -and
                -not [double]::IsInfinity($viewportBounds.Top)) {
                $viewportBounds.Top
            } else { $windowBounds.Top }
            $viewportHeight = if (-not [double]::IsNaN($viewportBounds.Height) -and
                -not [double]::IsInfinity($viewportBounds.Height) -and $viewportBounds.Height -gt 0) {
                $viewportBounds.Height
            } else { $windowBounds.Height }
            $visibleTop = [Math]::Max($viewportTopValue, $windowBounds.Top) + 8 * $scale
            $viewportBottomValue = if (-not [double]::IsNaN($viewportBounds.Bottom) -and
                -not [double]::IsInfinity($viewportBounds.Bottom)) {
                $viewportBounds.Bottom
            } else { $windowBounds.Bottom }
            $visibleBottom = [Math]::Min($viewportBottomValue, $windowBounds.Bottom) - 24 * $scale
            $entryOffset = (40 + 56 * $TextScale + 22) * $scale
            for ($move = 0; $move -lt 4; $move++) {
                $rootTop = $rootRoom[0].Current.BoundingRectangle.Top
                if ([double]::IsNaN($rootTop) -or [double]::IsInfinity($rootTop)) { break }
                $entryY = $rootTop + $entryOffset
                $visibleLength = [Math]::Min($entryY + 120 * $scale, $visibleBottom) -
                    [Math]::Max($entryY, $visibleTop)
                if ($visibleLength -ge 40 * $scale) { break }
                $delta = $entryY - $visibleTop
                $viewSize = $scroll.Current.VerticalViewSize
                $visibleViewportHeight = $visibleBottom - $visibleTop
                $extent = $visibleViewportHeight * (100 / $viewSize - 1)
                if ($viewSize -le 0 -or $viewSize -ge 100 -or $extent -le 0 -or
                    [double]::IsNaN($extent) -or [double]::IsInfinity($extent)) {
                    throw "The Room map connection viewport has no measurable vertical extent for '$Name'."
                }
                $previousPercent = $scroll.Current.VerticalScrollPercent
                $percent = [Math]::Max(0, [Math]::Min(100,
                    $previousPercent + 100 * $delta / $extent))
                if ([Math]::Abs($percent - $previousPercent) -lt 0.01) {
                    throw "The Room map connection entry cannot reach the visible viewport for '$Name' " +
                        "(entry=$([Math]::Round($entryY, 2)), root=$([Math]::Round($rootTop, 2)), " +
                        "visible=$([Math]::Round($visibleTop, 2))-$([Math]::Round($visibleBottom, 2)), " +
                        "scroll=$([Math]::Round($previousPercent, 2))%, target=$([Math]::Round($percent, 2))%, " +
                        "view=$([Math]::Round($viewSize, 2))%, extent=$([Math]::Round($extent, 2)))."
                }
                $scroll.SetScrollPercent(-1, $percent)
                Start-Sleep -Milliseconds 300
            }
        }
    }
    $bounds = $rootRoom[0].Current.BoundingRectangle
    $path = Join-Path $ScreenshotDirectory "room-map-connections-$Name.png"
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path $path
    $window = Get-UiReviewWindowBounds $windowHandle
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $connectionLefts = @($page.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
                $_.Current.AutomationId -like 'RoomMapConnection-*' -and
                    -not [double]::IsNaN($_.Current.BoundingRectangle.Left) -and
                    -not [double]::IsInfinity($_.Current.BoundingRectangle.Left)
            } | ForEach-Object { $_.Current.BoundingRectangle.Left - $window.Left })
        $trunkX = if ($connectionLefts.Count -gt 0) {
            [int][Math]::Round(($connectionLefts | Measure-Object -Minimum).Minimum)
        } elseif (-not [double]::IsNaN($bounds.Left) -and -not [double]::IsInfinity($bounds.Left)) {
            [int][Math]::Round($bounds.Left - $window.Left - 16 * $scale)
        } else {
            $scrollBounds = $scrollViewer.Current.BoundingRectangle
            if ([double]::IsNaN($scrollBounds.Left) -or [double]::IsInfinity($scrollBounds.Left) -or
                [double]::IsNaN($scrollBounds.Width) -or [double]::IsInfinity($scrollBounds.Width)) {
                throw "Room map connection bounds are unavailable for '$Name'."
            }
            # The canvas is the scroll viewport minus 16 DIP; the shared trunk is 344 DIP from its right edge.
            [int][Math]::Round(
                $scrollBounds.Left - $window.Left + $scrollBounds.Width - 360 * $scale)
        }
        $viewportTopValue = if (-not [double]::IsNaN($scrollViewer.Current.BoundingRectangle.Top) -and
            -not [double]::IsInfinity($scrollViewer.Current.BoundingRectangle.Top)) {
            $scrollViewer.Current.BoundingRectangle.Top
        } else { $window.Top }
        $viewportBottomValue = if (-not [double]::IsNaN($scrollViewer.Current.BoundingRectangle.Bottom) -and
            -not [double]::IsInfinity($scrollViewer.Current.BoundingRectangle.Bottom)) {
            $scrollViewer.Current.BoundingRectangle.Bottom
        } else { $window.Bottom }
        $visibleTop = [int][Math]::Max(
            0,
            [Math]::Ceiling($viewportTopValue - $window.Top + 4 * $scale))
        $visibleBottom = [int][Math]::Min(
            [double]($viewportBottomValue - $window.Top),
            [double]($bitmap.Height - [int](24 * $scale)))
        $firstRow = $visibleTop
        $lastRow = $visibleBottom
        if (-not [double]::IsNaN($bounds.Top) -and -not [double]::IsInfinity($bounds.Top)) {
            $top = [int][Math]::Round($bounds.Top - $window.Top)
            $entryY = $top + [int][Math]::Ceiling((40 + 56 * $TextScale + 22) * $scale)
            $firstRow = [int][Math]::Max(
                $visibleTop, $entryY + [int][Math]::Ceiling(4 * $scale))
            $lastRow = [int][Math]::Min(
                [double]($entryY + [int](120 * $scale)),
                [double]$visibleBottom)
        }
        if ($trunkX -lt 3 -or $trunkX + 3 -ge $bitmap.Width -or $firstRow -lt 0 -or
            $lastRow -ge $bitmap.Height -or $lastRow - $firstRow -lt 40 * $scale) {
            throw "The Room map connection trunk must be inside the captured window for '$Name'. " +
                "TrunkX=$trunkX; firstRow=$firstRow; lastRow=$lastRow; capture=$($bitmap.Width)x$($bitmap.Height); " +
                "scroll=$($scroll.Current.VerticalScrollPercent)%."
        }
        $sum = { param($Pixel) [int]$Pixel.R + $Pixel.G + $Pixel.B }
        $backgroundX = [Math]::Max(0, $trunkX - [int](8 * $scale))
        $background = & $sum $bitmap.GetPixel($backgroundX, $firstRow + [int](4 * $scale))
        $inked = 0
        for ($y = $firstRow; $y -le $lastRow; $y++) {
            $contrast = 0
            for ($x = $trunkX - 2; $x -le $trunkX + 2; $x++) {
                $contrast = [Math]::Max($contrast, [Math]::Abs((& $sum $bitmap.GetPixel($x, $y)) - $background))
            }
            if ($contrast -ge 90) { $inked++ }
        }
        $ratio = $inked / ($lastRow - $firstRow + 1)
        if ($ratio -lt 0.85) {
            throw "Room map connections must stay legible in '$Name'; only " +
                "$([Math]::Round($ratio * 100))% of the visible trunk interval contrasts with the background."
        }
    }
    finally { $bitmap.Dispose() }
}

function Assert-RoomMapDetailsBack([string] $Name) {
    # Find the button itself: its keyboard-focus ToolTip carries the same name without the Invoke pattern.
    $back = Find-UiRegressionElement -Condition ([System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceBackButton'),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, 'Back to Room map'))) `
        -Description "Device details Room map Back for '$Name'" -Container { $root }
    $tolerance = 1.5 * $scale
    $bounds = $back.Current.BoundingRectangle
    $window = $root.Current.BoundingRectangle
    $label = $back.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text))
    # A Button with string Content may not expose its TextBlock as a separate peer; when it does, it must fit.
    $text = if ($label) { $label.Current.BoundingRectangle } else { $null }
    if ($label -and $label.Current.Name -cne "$([char]0x2190) Room map") {
        throw "The Room map Back button must show the Room map destination in '$Name'; found '$($label.Current.Name)'."
    }
    if ($bounds.IsEmpty -or $bounds.Width -lt 80 * $scale -or $bounds.Height -lt 32 * $scale -or
        $bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right -or
        $bounds.Top -lt $window.Top -or $bounds.Bottom -gt $window.Bottom -or
        $text -and ($text.Width -le 0 -or $text.Left -lt $bounds.Left - $tolerance -or $text.Right -gt $bounds.Right + $tolerance -or
            $text.Top -lt $bounds.Top - $tolerance -or $text.Bottom -gt $bounds.Bottom + $tolerance)) {
        throw "The Room map Back button is clipped in '$Name'. Button=$bounds; label=$text; window=$window."
    }
    foreach ($tabId in @('DeviceOverviewTab', 'DeviceHistoryTab')) {
        $tab = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $tabId))
        if (-not $tab) { throw "Device Details tab '$tabId' is missing in '$Name'." }
        $overlap = [System.Windows.Rect]::Intersect($bounds, $tab.Current.BoundingRectangle)
        if (-not $overlap.IsEmpty -and $overlap.Width -gt $tolerance -and $overlap.Height -gt $tolerance) {
            throw "The Room map Back button overlaps '$tabId' in '$Name'. Button=$bounds; tab=$($tab.Current.BoundingRectangle)."
        }
    }
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path (Join-Path $ScreenshotDirectory "room-map-details-back-$Name.png")
    $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description "Room map after the '$Name' Back check" -Condition {
        $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll'))
        $candidate -and -not $candidate.Current.IsOffscreen
    }
}

function Test-RoomMapAccessibility {
    # Reuses Test-RoomMapScale's 10-room/100-device fixture: narrow windows scroll instead of shrinking,
    # and 200% Windows text scale keeps every label inside its room or device tile.
    $inventory = Join-Path (Join-Path $fixtureDirectory 'room-map-scale') 'inventory.json'
    if (-not (Test-Path -LiteralPath $inventory)) { throw 'Test-RoomMapScale must create the Room map scale fixture first.' }
    $savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
    $tolerance = 1.5 * $scale
    $openMap = {
        Select-SidebarPage 'Tools' 'View room map'
        Invoke-PeopleRoomsElement Name 'View room map'
        $null = Find-PeopleRoomsElement AutomationId 'RoomMapRoom-00000000-0000-0000-0000-000000000001' RoomMapPage
        $page = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage')) `
            -Description 'Room map accessibility page' -Container { $root }
        $onlyOnline = Find-PeopleRoomsElement AutomationId RoomMapOnlineOnlySwitch RoomMapPage
        $toggle = $onlyOnline.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {
            $toggle.Toggle()
            $null = Wait-UiRegressionState -Description 'all Room map accessibility devices' -Condition {
                $devices = $page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition) |
                    Where-Object { $_.Current.AutomationId -like 'RoomMapDevice-*' }
                @($devices).Count -eq 100
            }
        }
        $page
    }
    $mapElements = {
        param($Page, [string] $Prefix)
        @($Page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.AutomationId -like "$Prefix*" })
    }
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    # UI Automation can return clipped bounds for a partially visible peer while keeping IsOffscreen false.
    $viewport = {
        $map = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll'))
        if (-not $map) { throw 'The Room map scroll viewer is missing.' }
        # The scroll viewer's automation bounds can extend past the physical window frame.
        $frame = $root.Current.BoundingRectangle
        [System.Windows.Rect]::Intersect($map.Current.BoundingRectangle,
            [System.Windows.Rect]::new($frame.Left, $frame.Top, $frame.Width, [Math]::Max(0, $frame.Height - 16 * $scale)))
    }
    $fullyVisible = {
        param($Elements)
        $area = & $viewport
        $contained = @($Elements | Where-Object {
            $bounds = $_.Current.BoundingRectangle
            -not $_.Current.IsOffscreen -and -not $bounds.IsEmpty -and
                $bounds.Left -ge $area.Left - 1 -and $bounds.Right -le $area.Right + 1 -and
                $bounds.Top -ge $area.Top - 1 -and $bounds.Bottom -le $area.Bottom + 1
        })
        if ($contained.Count -eq 0) { return @() }
        Select-UiRegressionLargestRenderedPeers -Elements $contained -Tolerance $tolerance
    }
    $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
    $originalScale = $settings.TextScaleFactor
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $originalValue = $key.GetValue('TextScaleFactor', $null)
    $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
    $failed = $true
    Stop-SidebarApp
    try {
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        $page = & $openMap
        $mode = Get-SidebarAppearanceSelection ModePicker
        $style = Get-SidebarAppearanceSelection ThemePicker
        $highContrast = $null
        $themesFailed = $true
        try {
            foreach ($theme in @('Standard Light', 'Standard Dark')) {
                Set-SidebarAppearance ThemePicker $theme
                $null = & $openMap
                Assert-RoomMapConnectionInk ($theme.Replace(' ', '-').ToLowerInvariant()) 1
            }
            $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
            Start-Sleep -Seconds 2
            if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw 'High contrast did not activate.' }
            $null = & $openMap
            Assert-RoomMapConnectionInk 'high-contrast' 1
            $themesFailed = $false
        }
        finally {
            Invoke-UiRegressionCleanup -PrimaryFailed $themesFailed -Steps @(
                {
                    if ($null -ne $highContrast) {
                        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
                        Start-Sleep -Seconds 2
                    }
                },
                {
                    Select-SidebarPage Settings "Window backdrop"
                    Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice $mode
                    Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice $style
                })
        }
        $page = & $openMap
        $tiles = & $mapElements $page 'RoomMapDevice-'
        if ($tiles.Count -ne 100) { throw "The Room map must render all 100 devices before resizing; found $($tiles.Count)." }
        $normal = @{}
        foreach ($tile in (& $fullyVisible $tiles)) { $normal[$tile.Current.AutomationId] = $tile.Current.BoundingRectangle }
        if ($normal.Count -eq 0) { throw 'At least one Room map device must be fully visible before resizing.' }
        $normalSizes = @($normal.Values | ForEach-Object { [System.Windows.Size]::new($_.Width, $_.Height) })
        Set-SidebarWindowWidth 640
        # The scroll viewer is not focusable, and the RoomMapPage pane has no ScrollPattern to reveal it with.
        $page = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapScroll')) `
            -Description 'narrow Room map scroll viewer' -Container {
                $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage'))
            }
        $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if (-not $scroll.Current.HorizontallyScrollable -or -not $scroll.Current.VerticallyScrollable) {
            throw 'A narrow window must scroll the Room map horizontally and vertically instead of shrinking it.'
        }
        $page = Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage')) `
            -Description 'resized Room map page' -Container { $root }
        $narrowTiles = & $fullyVisible (& $mapElements $page 'RoomMapDevice-')
        if ($narrowTiles.Count -eq 0) { throw 'At least one Room map device must be fully visible in a narrow window.' }
        foreach ($tile in $narrowTiles) {
            $after = $tile.Current.BoundingRectangle
            $expected = if ($normal.ContainsKey($tile.Current.AutomationId)) {
                @([System.Windows.Size]::new($normal[$tile.Current.AutomationId].Width, $normal[$tile.Current.AutomationId].Height))
            } else { $normalSizes }
            if (-not ($expected | Where-Object {
                    [Math]::Abs($after.Width - $_.Width) -le $tolerance -and [Math]::Abs($after.Height - $_.Height) -le $tolerance })) {
                throw "Room map device $($tile.Current.AutomationId) must keep its normal size in a narrow window ($($after.Width)x$($after.Height))."
            }
        }
        $last = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        if ($last.Current.IsOffscreen) { throw 'Keyboard focus must bring the last Room map device into view in a narrow window.' }
        Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path (Join-Path $ScreenshotDirectory 'room-map-narrow.png')
        $last.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Assert-RoomMapDetailsBack 'narrow'

        Stop-SidebarApp
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [SidebarReviewKeyboard]::NotifyTextScaleChanged()
        $null = Wait-UiRegressionState -Description 'effective Windows text scale of 200 percent' -Condition {
            [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
        }
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        $page = & $openMap
        Assert-RoomMapConnectionInk 'text-scale-200' 2
        $tiles = & $mapElements $page 'RoomMapDevice-'
        $rooms = & $mapElements $page 'RoomMapRoom-'
        if ($tiles.Count -ne 100 -or $rooms.Count -ne 10) {
            throw "Enlarged text must keep all 10 rooms and 100 devices; found $($rooms.Count) and $($tiles.Count)."
        }
        $visibleTiles = & $fullyVisible $tiles
        if ($visibleTiles.Count -eq 0) { throw 'At least one Room map device must be fully visible at 200% text scale.' }
        foreach ($tile in $visibleTiles) {
            $bounds = $tile.Current.BoundingRectangle
            foreach ($text in $tile.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition)) {
                $label = $text.Current.BoundingRectangle
                if ($label.Top -lt $bounds.Top - $tolerance -or $label.Bottom -gt $bounds.Bottom + $tolerance) {
                    throw "Room map device $($tile.Current.AutomationId) clips '$($text.Current.Name)' at 200% text scale."
                }
            }
        }
        $area = & $viewport
        $checkedRooms = 0
        foreach ($room in $rooms) {
            $bounds = $room.Current.BoundingRectangle
            if ($room.Current.IsOffscreen -or $bounds.Top -lt $area.Top - 1 -or $bounds.Top -gt $area.Bottom) { continue }
            $firstTile = @($visibleTiles | Where-Object { $bounds.Contains($_.Current.BoundingRectangle) } |
                ForEach-Object { $_.Current.BoundingRectangle.Top } | Measure-Object -Minimum).Minimum
            if ($null -eq $firstTile) { continue }
            $checkedRooms++
            foreach ($text in $room.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition)) {
                $label = $text.Current.BoundingRectangle
                if ($label.Bottom -gt $firstTile + $tolerance) {
                    throw "Room header '$($text.Current.Name)' must stay above its devices at 200% text scale."
                }
            }
        }
        if ($checkedRooms -eq 0) { throw 'At least one Room map room header and device must be fully visible at 200% text scale.' }
        $last = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        if ($last.Current.IsOffscreen) { throw 'Keyboard focus must bring the last Room map device into view at 200% text scale.' }
        Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path (Join-Path $ScreenshotDirectory 'room-map-text-scale-200.png')
        $last.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Assert-RoomMapDetailsBack 'text-scale-200'
        Set-SidebarWindowWidth 640
        $last = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        $last.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Assert-RoomMapDetailsBack 'text-scale-200-narrow'
        Write-Host 'Room map narrow-window scrolling, normal-size devices, 200% text-scale layout, connection legibility and Room map Back headers passed.'
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
            { Stop-SidebarApp },
            {
                if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                $null = Wait-UiRegressionState -Description 'restored Windows text scale' -Condition {
                    [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01
                }
            },
            { $key.Dispose() },
            { $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory; Start-SidebarApp; Set-SidebarWindowWidth $expandedWidth })
    }
}

function Select-PersonEmojiForReview([string] $ExpectedShortName, [string] $CaptureName = 'default') {
    Invoke-PeopleRoomsElement AutomationId PersonIconPicker
    $search = Find-SidebarElement AutomationId PersonIconSearch
    $viewport = Find-SidebarElement AutomationId PersonIconViewport
    if (-not (Test-UiRegressionElementWithin $search $viewport $root)) {
        throw 'The portrait search must fit inside the scrollable picker and application window, not be clipped by its presenter.'
    }
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path (Join-Path $ScreenshotDirectory "person-picker-off-$CaptureName.png")
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('manager')
    $variants = Find-SidebarElement AutomationId PersonIconVariants
    $toggle = $variants.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw 'A new person editor must initially hide icon variants.'
    }
    $null = Find-SidebarElement Name 'Manager, Man 1'
    $status = Find-SidebarElement AutomationId PersonIconStatus
    $null = Wait-UiRegressionState -Description 'one primary Manager portrait' -Condition {
        $status.Current.Name.StartsWith('1 icons.')
    }
    $toggle.Toggle()
    foreach ($name in @('Manager, Man 1', 'Manager, Man 2', 'Manager, Woman 1', 'Manager, Woman 2')) {
        $option = Find-SidebarElement Name $name
        if ($option.Current.BoundingRectangle.Width -le 0) { throw "Icon '$name' has no rendered bounds." }
    }
    $null = Wait-UiRegressionState -Description 'four Manager gender and tone combinations' -Condition {
        $status.Current.Name.StartsWith('4 icons.')
    }
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path (Join-Path $ScreenshotDirectory "person-picker-variants-$CaptureName.png")
    (Find-SidebarElement Name 'Icon category: Hair').GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $status = Find-SidebarElement AutomationId PersonIconStatus
    $null = Wait-UiRegressionState -Description 'category and search combine for portraits' -Condition {
        $status.Current.Name.StartsWith('No matching icons.')
    }
    (Find-SidebarElement Name 'Icon category: Professions').GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $null = Find-SidebarElement Name 'Manager, Woman 2'
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('no-such-person-icon')
    $status = Find-SidebarElement AutomationId PersonIconStatus
    $null = Wait-UiRegressionState -Description 'explicit empty portrait search' -Condition {
        $status.Current.Name.StartsWith('No matching icons.')
    }
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('manager woman 2')
    $option = Find-SidebarElement AutomationId 'PersonIconOption-emoji:1f469-1f3fc-200d-1f4bc'
    $option.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $option.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x0D)
    $button = Find-SidebarElement Name 'Person icon: Manager, Woman 2'
    $null = Wait-UiRegressionState -Description 'portrait selection returns keyboard focus' -Condition {
        $button.Current.HasKeyboardFocus
    }
    $null = Wait-UiRegressionState -Description 'portrait flyout dismissed by selection' -Condition {
        -not (Find-SidebarElement AutomationId PersonIconSearch -Optional)
    }
    Invoke-PeopleRoomsElement AutomationId PersonIconPicker
    $variants = Find-SidebarElement AutomationId PersonIconVariants
    $variants.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $variants.SetFocus()
    $null = Wait-UiRegressionState -Description 'variant switch receives keyboard focus' -Condition {
        $variants.Current.HasKeyboardFocus
    }
    $status = Find-SidebarElement AutomationId PersonIconStatus
    $null = Wait-UiRegressionState -Description 'hidden selected portrait remains unchanged' -Condition {
        $status.Current.Name.StartsWith('No matching icons.')
    }
    [SidebarReviewKeyboard]::Tap(0x1B)
    $null = Wait-UiRegressionState -Description 'portrait flyout dismissed by Escape' -Condition {
        -not (Find-SidebarElement AutomationId PersonIconSearch -Optional)
    }
    $button = Find-SidebarElement Name 'Person icon: Manager, Woman 2'
    $null = Wait-UiRegressionState -Description 'portrait picker Escape returns keyboard focus' -Condition {
        $button.Current.HasKeyboardFocus
    }
    $preview = Find-SidebarElement AutomationId PersonDevicesPreview
    if ($preview.Current.Name -notlike '*Manager, Woman 2*' -or
        -not $preview.Current.Name.EndsWith(", $ExpectedShortName")) {
        throw 'The Devices-table preview must retain the selected portrait and complete Short name when variants are hidden.'
    }
    $path = Join-Path $ScreenshotDirectory "person-editor-preview-$CaptureName.png"
    $bounds = $preview.Current.BoundingRectangle
    $label = (Find-SidebarElement Name 'Devices table').Current.BoundingRectangle
    $window = Get-UiReviewWindowBounds $windowHandle
    $paint = @{ Signature = $null; StableSince = $null }
    $null = Wait-UiRegressionState -Description "stable rendered person preview ($CaptureName)" -Condition {
        Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path $path
        $bitmap = [System.Drawing.Bitmap]::new($path)
        try {
            $left = $label.Right - $window.Left + 12 * $scale
            $right = $bounds.Right - $window.Left
            $center = ($left + $right) / 2
            $top = $bounds.Top - $window.Top
            $background = $bitmap.GetPixel([int]($right + 4 * $scale), [int]($top + 56 * $scale))
            $distance = {
                param($Pixel)
                [Math]::Max([Math]::Abs([int]$Pixel.R - $background.R),
                    [Math]::Max([Math]::Abs([int]$Pixel.G - $background.G), [Math]::Abs([int]$Pixel.B - $background.B)))
            }
            foreach ($point in @(
                @(($left + 2 * $scale), ($top + 56 * $scale)),
                @(($right - 2 * $scale), ($top + 56 * $scale)),
                @($center, ($top + $scale)))) {
                $pixel = $bitmap.GetPixel([int]($point[0]), [int]($point[1]))
                if ((& $distance $pixel) -gt 2) {
                    throw "The entire table fragment, including its background, must fade into the dialog surface ($CaptureName; edge $pixel; surface $background)."
                }
            }
            $ink = @{}
            foreach ($region in @(@{ Name = 'Person'; Left = -12; Right = 25 }, @{ Name = 'LastSeen'; Left = 62; Right = 122 })) {
                $maximum = 0
                for ($x = [int]($center + $region.Left * $scale); $x -lt $center + $region.Right * $scale; $x++) {
                    for ($y = [int]($top + 24 * $scale); $y -lt $top + 63 * $scale; $y++) {
                        $maximum = [Math]::Max($maximum, (& $distance $bitmap.GetPixel($x, $y)))
                    }
                }
                $ink[$region.Name] = $maximum
            }
            if ($ink.Person -lt 40) { return $false }
            if ($ink.LastSeen -lt .15 * $ink.Person -or $ink.LastSeen -gt .9 * $ink.Person) {
                throw "Person must remain sharp while '2 h ago' is visibly but partially faded ($CaptureName; ink $($ink.Person)/$($ink.LastSeen))."
            }
            $signature = "$($background.R),$($background.G),$($background.B):$($ink.Person)/$($ink.LastSeen)"
            if ($paint.Signature -ceq $signature -and $paint.StableSince.ElapsedMilliseconds -ge 100) {
                Write-Host "Person preview $CaptureName matches its dialog at all edges; sharp/faded text ink: $($ink.Person)/$($ink.LastSeen)."
                return $true
            }
            $paint.Signature = $signature
            $paint.StableSince = [Diagnostics.Stopwatch]::StartNew()
            $false
        }
        finally { $bitmap.Dispose() }
    }
}

function Test-PersonPortraitAccessibility {
    $mode = Get-SidebarAppearanceSelection ModePicker
    $style = Get-SidebarAppearanceSelection ThemePicker
    $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
    $originalScale = $settings.TextScaleFactor
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    $originalValue = $key.GetValue('TextScaleFactor', $null)
    $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
    $failed = $true
    try {
        foreach ($theme in @('Standard Light', 'Standard Dark')) {
            Set-SidebarAppearance ThemePicker $theme
            Select-SidebarPage 'People & rooms' 'Search people and rooms'
            Invoke-PeopleRoomsElement AutomationId AddPersonButton PeopleRoomsPage
            Set-PeopleRoomsText 'Short name' 'III'
            Select-PersonEmojiForReview 'III' ($theme.Replace(' ', '-').ToLowerInvariant())
            Invoke-PeopleRoomsElement Name Cancel
        }
        Stop-SidebarApp
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [SidebarReviewKeyboard]::NotifyTextScaleChanged()
        $null = Wait-UiRegressionState -Description 'person picker effective 200 percent text scale' -Condition {
            [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
        }
        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
        $null = Wait-UiRegressionState -Description 'person picker high contrast enabled' -Condition {
            ([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -ne 0
        }
        Start-SidebarApp
        Select-SidebarPage 'People & rooms' 'Search people and rooms'
        Set-SidebarWindowWidth 640
        Invoke-PeopleRoomsElement AutomationId AddPersonButton PeopleRoomsPage
        Set-PeopleRoomsText 'Short name' 'III'
        Select-PersonEmojiForReview 'III' 'narrow-text-200-high-contrast'
        Invoke-PeopleRoomsElement Name Cancel
        $failed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
            { Stop-SidebarApp },
            { [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast) },
            {
                if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                $null = Wait-UiRegressionState -Description 'restored person picker text scale' -Condition {
                    [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01
                }
            },
            { $key.Dispose() },
            {
                Start-SidebarApp
                Set-SidebarWindowWidth $expandedWidth
                Select-SidebarPage Settings 'Window backdrop'
                Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice $mode
                Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice $style
                Select-SidebarPage 'People & rooms' 'Search people and rooms'
            })
    }
}

function Test-PeopleRoomsFlows {
    Set-SidebarWindowWidth $expandedWidth
    foreach ($category in @('Person', 'Room')) {
        $page = if ($category -eq 'Person') { 'People' } else { 'Rooms' }
        $singular = $category.ToLowerInvariant()
        $plural = $page.ToLowerInvariant()
        $search = 'Search people and rooms'
        $pageId = 'PeopleRoomsPage'
        $detailId = "${category}DetailPage"
        $name = "Refactor $singular"
        $short = if ($category -eq 'Person') { 'RP' } else { 'RR' }
        Select-SidebarPage 'People & rooms' $search
        Set-PeopleRoomsText $search 'missing-refactor'
        $null = Find-PeopleRoomsElement Name "No $plural match your search." $pageId
        Set-PeopleRoomsText $search ''

        Invoke-PeopleRoomsElement AutomationId "Add${category}Button" $pageId
        Set-PeopleRoomsText 'Full name' $name
        Set-PeopleRoomsText 'Short name' 'UI'
        $null = Find-PeopleRoomsElement Name "That short name is already used by another $singular."
        if ((Find-PeopleRoomsElement Name Save).Current.IsEnabled) { throw 'Duplicate short name enabled Save.' }
        Set-PeopleRoomsText 'Short name' 'LONG'
        $null = Find-PeopleRoomsElement Name 'Short names must contain 1 to 3 characters.'
        Set-PeopleRoomsText 'Short name' $short
        Invoke-PeopleRoomsElement Name Cancel
        Set-PeopleRoomsText $search $name
        $null = Find-PeopleRoomsElement Name "No $plural match your search." $pageId
        Set-PeopleRoomsText $search ''

        Invoke-PeopleRoomsElement AutomationId "Add${category}Button" $pageId
        Set-PeopleRoomsText 'Full name' $name
        Set-PeopleRoomsText 'Short name' $short
        Set-PeopleRoomsText 'Notes (optional)' 'Original notes'
        if ($category -eq 'Person') { Select-PersonEmojiForReview $short }
        Invoke-PeopleRoomsElement Name Save
        Invoke-PeopleRoomsElement Name "Actions for $name" $pageId
        Invoke-PeopleRoomsElement Name Edit
        if ($category -eq 'Person') {
            $null = Find-SidebarElement Name 'Person icon: Manager, Woman 2'
        }
        Set-PeopleRoomsText 'Notes (optional)' 'Saved notes'
        Invoke-PeopleRoomsElement Name Save
        Open-PeopleRoomsDetails $name $pageId
        $null = Find-PeopleRoomsElement Name 'Saved notes' $detailId
        # #670: the identity header keeps #657's title position with the entity's own icon slot and badge beneath it.
        $detailBack = Find-UiRegressionElement -Description "$category details Back" -Container { $root } -Condition (
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Back to people and rooms'),
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
        $detailBadge = Find-SidebarElement AutomationId "${category}DetailShortName"
        if ($detailBadge.Current.Name -cne $short) { throw "$category details must keep the '$short' short-name badge." }
        Assert-UiRegressionIdentityHeader -Back $detailBack.Current.BoundingRectangle `
            -Title (Find-SidebarElement AutomationId "${category}DetailName").Current.BoundingRectangle `
            -Badge $detailBadge.Current.BoundingRectangle -Scale $scale -Description "$category details"
        $null = Find-PeopleRoomsElement Name '0 devices assigned' $detailId
        Assert-SharedNetworkHeader
        Test-SharedScanContext $name
        $null = Find-PeopleRoomsElement Name 'Saved notes' $detailId

        Invoke-PeopleRoomsElement AutomationId "Edit${category}DetailButton" $detailId
        Set-PeopleRoomsText 'Full name' 'Cancelled edit'
        if ($category -eq 'Person') {
            Invoke-PeopleRoomsElement AutomationId PersonIconPicker
            (Find-SidebarElement AutomationId PersonIconSearch).GetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern).SetValue('manager man 1')
            $option = Find-SidebarElement AutomationId 'PersonIconOption-emoji:1f468-1f3fb-200d-1f4bc'
            $option.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            $option.SetFocus()
            [SidebarReviewKeyboard]::Tap(0x0D)
            $null = Find-SidebarElement Name 'Person icon: Manager, Man 1'
        }
        Invoke-PeopleRoomsElement Name Cancel
        $null = Find-PeopleRoomsElement Name $name $detailId
        Invoke-PeopleRoomsElement AutomationId "Edit${category}DetailButton" $detailId
        if ($category -eq 'Person') { $null = Find-SidebarElement Name 'Person icon: Manager, Woman 2' }
        Set-PeopleRoomsText 'Full name' "$name edited"
        Invoke-PeopleRoomsElement Name Save
        $null = Find-PeopleRoomsElement Name "$name edited" $detailId

        Invoke-PeopleRoomsElement AutomationId "Assign${category}DevicesButton" $detailId
        $null = Find-PeopleRoomsElement Name 'Choose a device'
        Invoke-PeopleRoomsElement Name Cancel
        $null = Find-PeopleRoomsElement Name '0 devices assigned' $detailId
        Invoke-PeopleRoomsElement AutomationId "Assign${category}DevicesButton" $detailId
        Invoke-PeopleRoomsElement Name Assign
        $null = Find-PeopleRoomsElement Name '1 device assigned' $detailId
        Invoke-PeopleRoomsElement Name Unassign $detailId
        $null = Find-PeopleRoomsElement Name '0 devices assigned' $detailId
        Invoke-PeopleRoomsElement AutomationId "Assign${category}DevicesButton" $detailId
        Invoke-PeopleRoomsElement Name Assign
        $null = Find-PeopleRoomsElement Name '1 device assigned' $detailId
        Invoke-PeopleRoomsElement AutomationId "Delete${category}DetailButton" $detailId
        Invoke-PeopleRoomsElement Name Cancel
        $null = Find-PeopleRoomsElement Name '1 device assigned' $detailId
        Invoke-PeopleRoomsElement AutomationId "Delete${category}DetailButton" $detailId
        Invoke-PeopleRoomsElement Name Delete
        Set-PeopleRoomsText $search "$name edited"
        $null = Find-PeopleRoomsElement Name "No $plural match your search." $pageId
        Set-PeopleRoomsText $search ''
    }
    Write-Host 'People/Rooms search, list/detail editors, validation, cancellation, selection refresh, assignments and deletion passed.'
}

function Test-PeopleRoomsPersistenceErrors {
    $savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
    $storeDirectory = Join-Path $fixtureDirectory 'people-rooms-store'
    $inventory = Join-Path $storeDirectory 'inventory.json'
    $database = [IO.Path]::ChangeExtension($inventory, '.sqlite')
    Stop-SidebarApp
    try {
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
        Start-SidebarApp
        Select-SidebarPage 'People & rooms' 'Search people and rooms'
        $null = Wait-UiRegressionState -Description 'People editor ready' -Condition {
            (Find-PeopleRoomsElement AutomationId AddPersonButton PeopleRoomsPage).Current.IsEnabled
        }
        # UI review always seeds one person and one room; a no-match search empties both sections.
        Set-PeopleRoomsText 'Search people and rooms' 'missing-empty-sections'
        foreach ($section in @('People', 'Rooms')) {
            $count = (Find-PeopleRoomsElement AutomationId "${section}CountText" PeopleRoomsPage).Current.Name
            if ($count -ne '0 shown') {
                throw "Empty $section must retain its visible zero count; got '$count'."
            }
            $null = Find-PeopleRoomsElement AutomationId "${section}EmptyText" PeopleRoomsPage
        }
        Set-PeopleRoomsText 'Search people and rooms' ''
        # A file at the missing fixture directory deterministically rejects the write without a database lock.
        Set-Content -LiteralPath $storeDirectory -Value 'blocked fixture directory' -Encoding ASCII
        Invoke-PeopleRoomsElement AutomationId AddPersonButton PeopleRoomsPage
        Set-PeopleRoomsText 'Full name' 'Retained draft'
        Set-PeopleRoomsText 'Short name' 'RD'
        Select-PersonEmojiForReview 'RD' 'persistence'
        Invoke-PeopleRoomsElement Name Save
        $null = Find-PeopleRoomsElement Name 'The person could not be saved.'
        $draft = (Find-PeopleRoomsElement Name 'Full name').GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if ($draft -ne 'Retained draft') { throw 'Failed save lost the editor draft.' }
        Remove-Item -LiteralPath $storeDirectory
        $null = New-Item -ItemType Directory -Path $storeDirectory
        Invoke-PeopleRoomsElement Name Save
        $null = Find-PeopleRoomsElement Name 'Retained draft' PeopleRoomsPage
        Stop-SidebarApp
        Start-SidebarApp
        Select-SidebarPage 'People & rooms' 'Search people and rooms'
        $null = Find-PeopleRoomsElement Name 'Retained draft' PeopleRoomsPage
        Invoke-PeopleRoomsElement Name 'Actions for Retained draft' PeopleRoomsPage
        Invoke-PeopleRoomsElement Name Edit
        $null = Find-SidebarElement Name 'Person icon: Manager, Woman 2'
        Invoke-PeopleRoomsElement Name Cancel
        Stop-SidebarApp
        Set-Content -LiteralPath $database -Value 'not a SQLite database' -Encoding ASCII
        Start-SidebarApp
        Select-SidebarPage 'People & rooms' 'Search people and rooms'
        $null = Wait-UiRegressionState -Description 'unavailable People status' -Condition {
            (Find-PeopleRoomsElement AutomationId PeopleStatusText PeopleRoomsPage).Current.Name -like 'Saved inventory could not be loaded.*'
        }
        if ((Find-PeopleRoomsElement AutomationId RoomsStatusText PeopleRoomsPage).Current.Name -notlike 'Saved inventory could not be loaded.*') {
            throw 'Unavailable inventory must retain the Rooms error status even without rows.'
        }
        if ((Find-PeopleRoomsElement AutomationId AddPersonButton PeopleRoomsPage).Current.IsEnabled) {
            throw 'Unavailable inventory enabled People changes.'
        }
        Select-SidebarPage 'People & rooms' 'Search people and rooms'
        if ((Find-PeopleRoomsElement AutomationId AddRoomButton PeopleRoomsPage).Current.IsEnabled) {
            throw 'Unavailable inventory enabled Room changes.'
        }
        Write-Host 'People/Rooms failed-save draft, retry, persisted restart and unavailable inventory restrictions passed.'
    }
    finally {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
    }
}
