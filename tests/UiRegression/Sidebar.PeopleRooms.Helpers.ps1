function Find-PeopleRoomsElement([string] $Property, [string] $Value, [string] $OwnerId) {
    $propertyId = if ($Property -eq 'Name') {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $condition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    Find-UiRegressionElement -Condition $condition -Description "People/Rooms '$Value'" -Container {
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
    (Find-PeopleRoomsElement $Property $Value $OwnerId).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
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
        $pageId = "${page}Page"
        $detailId = "${category}DetailPage"
        $name = "Refactor $singular"
        $short = if ($category -eq 'Person') { 'RP' } else { 'RR' }
        Select-SidebarPage $page "Search $($page.ToLowerInvariant())"
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" 'missing-refactor'
        $null = Find-PeopleRoomsElement Name "No $($page.ToLowerInvariant()) match your search." $pageId
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" ''

        Invoke-PeopleRoomsElement AutomationId "Add${category}Button" $pageId
        Set-PeopleRoomsText 'Full name' $name
        Set-PeopleRoomsText 'Short name' 'UI'
        $null = Find-PeopleRoomsElement Name "That short name is already used by another $singular."
        if ((Find-PeopleRoomsElement Name Save).Current.IsEnabled) { throw 'Duplicate short name enabled Save.' }
        Set-PeopleRoomsText 'Short name' 'LONG'
        $null = Find-PeopleRoomsElement Name 'Short names must contain 1 to 3 characters.'
        Set-PeopleRoomsText 'Short name' $short
        Invoke-PeopleRoomsElement Name Cancel
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" $name
        $null = Find-PeopleRoomsElement Name "No $($page.ToLowerInvariant()) match your search." $pageId
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" ''

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
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" "$name edited"
        $null = Find-PeopleRoomsElement Name "No $($page.ToLowerInvariant()) match your search." $pageId
        Set-PeopleRoomsText "Search $($page.ToLowerInvariant())" ''
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
        Select-SidebarPage People 'Search people'
        $null = Wait-UiRegressionState -Description 'People editor ready' -Condition {
            (Find-PeopleRoomsElement AutomationId AddPersonButton PeoplePage).Current.IsEnabled
        }
        # A file at the missing fixture directory deterministically rejects the write without a database lock.
        Set-Content -LiteralPath $storeDirectory -Value 'blocked fixture directory' -Encoding ASCII
        Invoke-PeopleRoomsElement AutomationId AddPersonButton PeoplePage
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
        $null = Find-PeopleRoomsElement Name 'Retained draft' PeoplePage
        Stop-SidebarApp
        Start-SidebarApp
        Select-SidebarPage People 'Search people'
        $null = Find-PeopleRoomsElement Name 'Retained draft' PeoplePage
        Stop-SidebarApp
        Set-Content -LiteralPath $database -Value 'not a SQLite database' -Encoding ASCII
        Start-SidebarApp
        Select-SidebarPage People 'Search people'
        $null = Wait-UiRegressionState -Description 'unavailable People status' -Condition {
            (Find-PeopleRoomsElement AutomationId PeopleStatusText PeoplePage).Current.Name -like 'Saved inventory could not be loaded.*'
        }
        if ((Find-PeopleRoomsElement AutomationId AddPersonButton PeoplePage).Current.IsEnabled) {
            throw 'Unavailable inventory enabled People changes.'
        }
        Select-SidebarPage Rooms 'Search rooms'
        if ((Find-PeopleRoomsElement AutomationId AddRoomButton RoomsPage).Current.IsEnabled) {
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
