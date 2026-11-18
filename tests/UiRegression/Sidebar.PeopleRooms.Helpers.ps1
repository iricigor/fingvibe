function Find-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
    $propertyId = if ($Property -eq 'Name') {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    # Wait-UiRegressionState's $Condition parameter shadows caller variables in callbacks.
    $peopleRoomsCondition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    if ($OwnerId -in @('PersonDetailPage', 'PeopleRoomsPage')) {
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
