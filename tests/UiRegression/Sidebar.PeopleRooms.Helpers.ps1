function Find-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
    $propertyId = if ($Property -eq 'Name') {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    # Wait-UiRegressionState's $Condition parameter shadows caller variables in callbacks.
    $peopleRoomsCondition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    if ($OwnerId -in @('PersonDetailPage', 'PeopleRoomsPage', 'RoomMapPage')) {
        $getPage = {
            $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $OwnerId))
        }
        $getTarget = {
            $page = & $getPage
            if ($page) { $page.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $peopleRoomsCondition) }
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
        $Owner.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Match) |
            Where-Object { Test-UiRegressionElementVisible $_ } | Select-Object -First 1
    }
}

function Invoke-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
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
    (Find-PeopleRoomsElement Name $Name).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
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

function Test-RoomMapEntries {
    Select-SidebarPage 'People & rooms' 'Search people and rooms'
    Invoke-PeopleRoomsElement AutomationId ViewRoomMapButton PeopleRoomsPage
    # Never name this $root: helper callbacks resolve the window root through dynamic scope.
    $gateway = Find-PeopleRoomsElement AutomationId RoomMapRootPlaceholder RoomMapPage
    if ($gateway.Current.IsKeyboardFocusable -ne $true) { throw 'The Room map gateway fallback must remain keyboard reachable.' }
    $unassigned = Find-PeopleRoomsElement AutomationId RoomMapUnassigned RoomMapPage
    if ($unassigned.Current.IsKeyboardFocusable -ne $true) { throw 'The Room map unassigned strip must remain keyboard reachable.' }
    $null = Find-PeopleRoomsElement AutomationId ManageRoomsButton RoomMapPage
    Invoke-PeopleRoomsElement AutomationId ManageRoomsButton RoomMapPage
    $null = Find-PeopleRoomsElement Name 'Search people and rooms' PeopleRoomsPage

    Select-SidebarPage 'Tools' 'View room map'
    Invoke-PeopleRoomsElement Name 'View room map'
    Invoke-PeopleRoomsElement AutomationId ManageRoomsButton RoomMapPage
    $null = Find-PeopleRoomsElement Name 'Search people and rooms' PeopleRoomsPage

    Select-SidebarPage 'Tools' 'Network troubleshooting'
    Invoke-PeopleRoomsElement Name 'Network troubleshooting'
    # The visible "Run checks" button is exposed to UI Automation as "Run network troubleshooting".
    $null = Find-PeopleRoomsElement AutomationId RunButton
    Invoke-PeopleRoomsElement AutomationId TroubleshootingViewRoomMapButton
    Invoke-PeopleRoomsElement AutomationId ManageRoomsButton RoomMapPage
    $null = Find-PeopleRoomsElement Name 'Search people and rooms' PeopleRoomsPage
    Write-Host 'Room map entry points, conceptual gateway fallback, focus reachability and return to management passed.'
}

function Test-RoomMapAppearance([string] $Name) {
    Select-SidebarPage 'Tools' 'View room map'
    Invoke-PeopleRoomsElement Name 'View room map'
    $null = Find-PeopleRoomsElement AutomationId RoomMapRootPlaceholder RoomMapPage
    Save-SidebarAppearance "room-map-$Name" -AssertMatchingSolid
    Invoke-PeopleRoomsElement AutomationId ManageRoomsButton RoomMapPage
    $null = Find-PeopleRoomsElement Name 'Search people and rooms' PeopleRoomsPage
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
        $elements = $page.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $deviceElements = @($elements | Where-Object {
            $_.Current.AutomationId -like 'RoomMapDevice-*'
        })
        $roomElements = @($elements | Where-Object {
            $_.Current.AutomationId -like 'RoomMapRoom-*'
        })
        if ($deviceElements.Count -ne 100) { throw "The Room map must retain all 100 relevant devices; found $($deviceElements.Count)." }
        if ($roomElements.Count -ne 10) { throw "The Room map must retain all ten saved rooms; found $($roomElements.Count)." }
        $layoutClock.Stop()
        $last = Find-PeopleRoomsElement AutomationId 'RoomMapDevice-001122000063' RoomMapPage
        if ($last.Current.IsKeyboardFocusable -ne $true) { throw 'The last Room map device must remain keyboard reachable.' }
        if ($last.Current.IsOffscreen -ne $false) { throw 'The focused last Room map device must be brought into view.' }
        @{
            rooms = $roomElements.Count
            devices = $deviceElements.Count
            layoutAndRenderSeconds = $layoutClock.Elapsed.TotalSeconds
            focusedFinalDevice = $last.Current.AutomationId
        } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'room-map-scale.json') -Encoding UTF8
        Write-Host "Room map rendered 10 rooms and 100 devices in $($layoutClock.Elapsed.TotalSeconds.ToString('F2')) seconds and reached the final keyboard target."
    }
    finally {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
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
        Find-UiRegressionElement -Condition ([System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'RoomMapPage')) `
            -Description 'Room map accessibility page' -Container { $root }
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

        Stop-SidebarApp
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
        [SidebarReviewKeyboard]::NotifyTextScaleChanged()
        $null = Wait-UiRegressionState -Description 'effective Windows text scale of 200 percent' -Condition {
            [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
        }
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        $page = & $openMap
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
        Write-Host 'Room map narrow-window scrolling, normal-size devices and 200% text-scale layout passed.'
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
        Invoke-PeopleRoomsElement Name Save
        Invoke-PeopleRoomsElement Name "Actions for $name" $pageId
        Invoke-PeopleRoomsElement Name Edit
        Set-PeopleRoomsText 'Notes (optional)' 'Saved notes'
        Invoke-PeopleRoomsElement Name Save
        Open-PeopleRoomsDetails $name $pageId
        $null = Find-PeopleRoomsElement Name 'Saved notes' $detailId
        $null = Find-PeopleRoomsElement Name '0 devices assigned' $detailId
        Assert-SharedNetworkHeader
        Test-SharedScanContext $name
        $null = Find-PeopleRoomsElement Name 'Saved notes' $detailId

        Invoke-PeopleRoomsElement AutomationId "Edit${category}DetailButton" $detailId
        Set-PeopleRoomsText 'Full name' 'Cancelled edit'
        Invoke-PeopleRoomsElement Name Cancel
        $null = Find-PeopleRoomsElement Name $name $detailId
        Invoke-PeopleRoomsElement AutomationId "Edit${category}DetailButton" $detailId
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
