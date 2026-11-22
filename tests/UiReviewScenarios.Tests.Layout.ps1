# Page contracts: shell, Tools and extracted page view layout.
    $pageViews = @{
        OverviewPage = "OverviewPageView"
        NetworkPage = "NetworkPageView"
        DevicesPage = "DevicesPageView"
        DevicePage = "DeviceDetailsPageView"
        PeopleRoomsPage = "PeopleRoomsPageView"
        PersonDetailPage = "PersonDetailsPageView"
        RoomDetailPage = "RoomDetailsPageView"
        RoomMapPage = "RoomMapPageView"
        SettingsPage = "SettingsPageView"
    }
    $appDirectory = Join-Path $PSScriptRoot "..\src\FingVibe.App"
    $roomMapDocument = [xml](Get-Content (Join-Path $appDirectory "Views\RoomMapPageView.xaml") -Raw)
    $roomMapCode = Get-Content (Join-Path $appDirectory "Views\RoomMapPageView.xaml.cs") -Raw
    $roomMapLayoutCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.Core\Models\RoomMapLayout.cs") -Raw
    $roomMapShellCode = Get-Content (Join-Path $appDirectory "MainWindow.RoomMap.cs") -Raw
    if ($roomMapCode -notmatch 'AddConnections\(\s*layout\.Connections' -or
        $roomMapCode -notmatch 'internal void RestoreNavigation' -or
        $roomMapCode -notmatch 'DeviceRequested\?\.\s*Invoke' -or
        $roomMapCode -notmatch 'RoomRequested\?\.\s*Invoke' -or
        $roomMapCode -notmatch 'QuadraticBezierSegment' -or
        $roomMapCode -notmatch 'ControlStrongStrokeColorDefaultBrush' -or
        $roomMapCode -notmatch 'ThemeShadow' -or
        $roomMapCode -notmatch 'new Vector3\(0,\s*0,\s*12\)' -or
        $roomMapLayoutCode -notmatch 'RouteConnections' -or
        $roomMapShellCode -notmatch 'ReturnToRoomMap') {
        throw "Room map must render immutable conceptual routes and route device/room activation through origin-aware shell return navigation."
    }
    $roomMapBackButton = $roomMapDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='RoomMapBackButton']")
    $roomMapOnlineOnly = $roomMapDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='RoomMapOnlineOnlySwitch']")
    if ($roomMapBackButton.GetAttribute("AutomationProperties.Name") -cne "Back to Rooms" -or
        $roomMapBackButton.GetAttribute("Style") -cne "{StaticResource PageBackButtonStyle}" -or
        $roomMapOnlineOnly.GetAttribute("IsOn") -cne "True" -or
        $roomMapOnlineOnly.GetAttribute("Header") -cne "Only online") {
        throw "Room map must use the standard Back to Rooms action and start with Only online enabled."
    }
    $unassignedSummary = $roomMapDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='RoomMapUnassignedSummaryText']")
    if ($unassignedSummary.LocalName -cne "TextBlock" -or
        $unassignedSummary.GetAttribute("AutomationProperties.AutomationId") -cne "RoomMapUnassignedSummary" -or
        $unassignedSummary.HasAttribute("IsTabStop") -or
        $roomMapCode -notmatch 'SetAutomationId\(strip, "RoomMapUnassigned"\)') {
        throw "Room map must keep the unassigned summary as static text and the focusable strip as RoomMapUnassigned."
    }
    $peopleRoomsDocument = [xml](Get-Content (Join-Path $appDirectory "Views\PeopleRoomsPageView.xaml") -Raw)
    $peopleRoomsCode = Get-Content (Join-Path $appDirectory "Views\PeopleRoomsPageView.xaml.cs") -Raw
    $headingRow = $peopleRoomsDocument.SelectSingleNode("//*[@*[local-name()='Name']='PeopleRoomsHeadingRow']")
    if (-not $headingRow) { throw "People & rooms must expose its shared icon/title layout." }
    $headingIcon = $headingRow.SelectSingleNode("./*[local-name()='PageHeaderIcon']")
    $headingTitle = $headingRow.SelectSingleNode("./*[local-name()='TextBlock']")
    if (-not $headingIcon -or $headingIcon.GetAttribute("Icon") -cne "people-rooms" -or
        $headingIcon.HasAttribute("Width") -or $headingIcon.HasAttribute("Height") -or
        $headingRow.SelectNodes("./*[local-name()='PageHeaderIcon' or local-name()='Viewbox']").Count -ne 1 -or
        $headingRow.GetAttribute("ColumnSpacing") -cne "12" -or
        $headingTitle.GetAttribute("Grid.Column") -cne "1" -or
        $headingTitle.GetAttribute("VerticalAlignment") -cne "Center" -or
        $headingTitle.GetAttribute("TextWrapping") -cne "Wrap") {
        throw "People & rooms must align its wrapping title beside one shared 48-DIP 'people-rooms' family icon with a 12-DIP gap."
    }
    $navItem = [regex]::Match((Get-Content (Join-Path $appDirectory "MainWindow.xaml") -Raw),
        '(?s)<NavigationViewItem x:Name="PeopleRoomsNavItem".*?</NavigationViewItem>').Value
    if ($navItem -notmatch 'UriSource="ms-appx:///Assets/PageIcons/people-rooms-mono-48\.png"' -or
        $navItem -notmatch 'Style="\{ThemeResource SidebarPeopleRoomsIconStyle\}"' -or $navItem -match '<PathIcon\b') {
        throw "People & rooms navigation must use one theme-colored single-color 'people-rooms' family icon."
    }
    foreach ($detail in @(
        @{ View = "PersonDetailsPageView"; Heading = "PersonDetailHeading"; Icon = "people"; Name = "PersonDetailName"; Symbol = "PersonDetailIcon"; Badge = "PersonDetailShortName" },
        @{ View = "RoomDetailsPageView"; Heading = "RoomDetailHeading"; Icon = "rooms"; Name = "RoomDetailName"; Symbol = "RoomDetailIcon"; Badge = "RoomDetailShortName" }
    )) {
        $detailDocument = [xml](Get-Content (Join-Path $appDirectory "Views\$($detail.View).xaml") -Raw)
        $heading = $detailDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($detail.Heading)']")
        $first = if ($heading) { $heading.SelectSingleNode("./*[not(starts-with(local-name(), 'Grid.'))]") }
        $detailName = if ($heading) { $heading.SelectSingleNode("./*[@*[local-name()='Name']='$($detail.Name)']") }
        if (-not $first -or $first.LocalName -cne "PageHeaderIcon" -or $first.GetAttribute("Icon") -cne $detail.Icon -or
            $heading.SelectNodes(".//*[local-name()='PageHeaderIcon']").Count -ne 1 -or
            -not $detailName -or $detailName.GetAttribute("Grid.Column") -cne "1" -or
            $heading.SelectSingleNode(".//*[@*[local-name()='Name']='$($detail.Symbol)' or @*[local-name()='Name']='$($detail.Badge)']") -or
            -not $detailDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($detail.Symbol)']") -or
            -not $detailDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($detail.Badge)']")) {
            throw "$($detail.View) must show the '$($detail.Icon)' family icon before its title and keep the entity symbol and short-name badge separate."
        }
    }
    foreach ($section in @(
        @{ Name = "People"; Add = "AddPersonButton" },
        @{ Name = "Rooms"; Add = "AddRoomButton" }
    )) {
        $name = $section.Name
        $card = $peopleRoomsDocument.SelectSingleNode("//*[@*[local-name()='Name']='${name}TableBorder']")
        $empty = $card.SelectSingleNode(".//*[@*[local-name()='Name']='${name}EmptyState']")
        $status = $card.SelectSingleNode(".//*[@*[local-name()='Name']='${name}StatusText']")
        $headers = $card.SelectSingleNode(".//*[@*[local-name()='Name']='${name}ColumnHeaders']")
        $addButtons = @($peopleRoomsDocument.SelectNodes("//*[@Click='$($section.Add)_Click']"))
        if (-not $empty -or -not $status -or -not $headers -or
            $addButtons.Count -ne 1 -or $addButtons[0].GetAttribute("x:Name") -cne $section.Add -or
            $status.GetAttribute("TextWrapping") -cne "Wrap" -or
            $peopleRoomsCode -match "\b${name}TableBorder\.Visibility\s*=" -or
            $peopleRoomsCode -notmatch "${name}ColumnHeaders\.Visibility\s*=\s*${name}List\.Visibility\s*=") {
            throw "$name must retain its status, count and single guarded Add action when its rows are empty or unavailable."
        }
        # #551: header and row grids are measured separately, so they must share columns and container insets.
        $list = $card.SelectSingleNode(".//*[local-name()='ListView' and @*[local-name()='Name']='${name}List']")
        $row = $list.SelectSingleNode(".//*[local-name()='DataTemplate']/*[local-name()='Grid']")
        $headerColumns = @($headers.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*") | ForEach-Object { $_.GetAttribute("Width") }) -join ","
        $rowColumns = @($row.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*") | ForEach-Object { $_.GetAttribute("Width") }) -join ","
        $rowAction = $row.SelectSingleNode("./*[local-name()='Button' and @*[local-name()='Grid.Column']='4']")
        $headerAction = $headers.SelectSingleNode("./*[local-name()='Button' and @*[local-name()='Grid.Column']='4']")
        $styleKey = [regex]::Match($list.GetAttribute("ItemContainerStyle"), '^\{StaticResource (\S+)\}$').Groups[1].Value
        $itemStyle = $peopleRoomsDocument.SelectSingleNode("//*[local-name()='Style' and @*[local-name()='Key']='$styleKey']")
        $setter = { param($property) $itemStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='$property']").GetAttribute("Value") }
        if ($headerColumns -cne $rowColumns -or $headers.GetAttribute("Padding").Split(",")[0] -cne $row.GetAttribute("Padding").Split(",")[0] -or
            -not $rowAction -or -not $headerAction -or $headerAction.GetAttribute("Content") -cne $rowAction.GetAttribute("Content") -or
            $headerAction.GetAttribute("Opacity") -cne "0" -or $headerAction.GetAttribute("IsTabStop") -cne "False" -or
            $headerAction.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw" -or
            -not $itemStyle -or (& $setter HorizontalContentAlignment) -cne "Stretch" -or
            (& $setter Padding) -cne "0" -or (& $setter Margin) -cne "0") {
            throw "$name headers must share the row columns, a hidden More-width action column and an uninset stretched row container."
        }
    }
    $peopleRoomsStatusSetter = [regex]::Match($peopleRoomsCode, 'internal string Status\s*\{[\s\S]*?\n    \}').Value
    $mainWindowCode = (Get-ChildItem -LiteralPath $appDirectory -Filter "MainWindow*.cs" | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    if ($peopleRoomsStatusSetter -notmatch 'Visibility\.Collapsed' -or
        $mainWindowCode -match 'SetPeopleRoomsStatus\("People and rooms are saved (locally|with the local device inventory)\.' -or
        $mainWindowCode -notmatch 'PeopleRoomsPage\.Status = string\.Empty;') {
        throw "People & rooms must omit the storage notice and collapse empty status lines while keeping save and error feedback."
    }
    $settings = [xml](Get-Content (Join-Path $appDirectory "Views\SettingsPageView.xaml") -Raw)
    $cards = $settings.SelectSingleNode("//*[@*[local-name()='Name']='SettingsCards']")
    if (-not $cards -or [double]$cards.GetAttribute("Spacing") -lt 4 -or [double]$cards.GetAttribute("Spacing") -gt 6) {
        throw "Settings cards must form one compact stack with 4-6 DIP gaps."
    }
    foreach ($styleName in @("SettingsSectionStyle", "SettingsNavigationCardStyle")) {
        $style = $settings.SelectSingleNode("//*[@*[local-name()='Key']='$styleName']")
        if (-not $style -or
            $style.SelectSingleNode("./*[local-name()='Setter' and @Property='MinHeight']").GetAttribute("Value") -cne "68" -or
            $style.SelectSingleNode("./*[local-name()='Setter' and (@Property='Height' or @Property='Template')]")) {
            throw "$styleName must retain its native template and a growing 68-DIP minimum, not a fixed height."
        }
    }
    $titleStyle = $settings.SelectSingleNode("//*[@*[local-name()='Key']='SettingsCardTitleStyle']")
    if ($titleStyle.SelectSingleNode("./*[@Property='FontSize']").GetAttribute("Value") -cne "14" -or
        $titleStyle.SelectSingleNode("./*[@Property='FontWeight']").GetAttribute("Value") -cne "Normal" -or
        $titleStyle.SelectSingleNode("./*[@Property='TextWrapping']").GetAttribute("Value") -cne "Wrap") {
        throw "Settings card titles must use regular 14-DIP wrapping text."
    }
    $iconStyle = $settings.SelectSingleNode("//*[@*[local-name()='Key']='SettingsCardIconStyle']")
    if ($iconStyle.SelectSingleNode("./*[@Property='Width']").GetAttribute("Value") -cne "32" -or
        $iconStyle.SelectSingleNode("./*[@Property='AutomationProperties.AccessibilityView']").GetAttribute("Value") -cne "Raw") {
        throw "Settings leading icons must reserve a fixed column without duplicating accessible labels."
    }
    foreach ($entry in @(
        @{ Id = "AppearanceSection"; Type = "Expander"; Summary = "AppearanceSummary" },
        @{ Id = "DevicesSection"; Type = "Expander"; Summary = "DevicesSummary" },
        @{ Id = "ScheduledScansSection"; Type = "Expander"; Summary = "ScheduledScansSummary" },
        @{ Id = "AboutSettingsButton"; Type = "Button"; Summary = "AboutSummary" }
    )) {
        $card = $cards.SelectSingleNode(".//*[@*[local-name()='Name']='$($entry.Id)']")
        $header = $card.SelectSingleNode(".//*[local-name()='Grid' and @Style='{StaticResource SettingsCardHeaderStyle}']")
        if ($card.LocalName -cne $entry.Type -or -not $header -or
            $header.SelectSingleNode("./*[local-name()='Grid.ColumnDefinitions']/*[1]").GetAttribute("Width") -cne "32" -or
            -not $header.SelectSingleNode(".//*[local-name()='FontIcon' and @Style='{StaticResource SettingsCardIconStyle}']") -or
            -not $header.SelectSingleNode(".//*[@*[local-name()='Name']='$($entry.Summary)' and @Style='{StaticResource SettingsCardSummaryStyle}']")) {
            throw "$($entry.Id) must preserve its native interaction and use the shared icon/text header treatment."
        }
    }
    $aboutRow = $cards.SelectSingleNode("./*[local-name()='Grid' and @*[local-name()='Name']='AboutSettingsRow']")
    $settingsUpdate = $aboutRow.SelectSingleNode("./*[local-name()='Button' and @*[local-name()='Name']='SettingsUpdateNowButton']")
    $aboutButton = $aboutRow.SelectSingleNode("./*[local-name()='Button' and @*[local-name()='Name']='AboutSettingsButton']")
    if (-not $aboutRow -or -not $aboutButton -or -not $settingsUpdate -or
        $aboutButton.ParentNode -ne $aboutRow -or $settingsUpdate.ParentNode -ne $aboutRow) {
        throw "Settings Update now must remain a sibling action, not a nested About row control."
    }
    if ($settingsUpdate.GetAttribute("Content") -cne "Update now" -or
        $settingsUpdate.GetAttribute("Click") -cne "SettingsUpdateNowButton_Click") {
        throw "Settings must expose the shared Update now action."
    }
    if ($aboutRow.HasAttribute("ColumnSpacing") -or $settingsUpdate.GetAttribute("Margin") -cne "12,0,0,0") {
        throw "A collapsed Settings Update now action must not narrow the About card; keep its spacing on the button margin."
    }
    $scheduled = $settings.SelectSingleNode("//*[@*[local-name()='Name']='ScheduledScansSection']")
    $monitorSwitch = $scheduled.SelectSingleNode(".//*[@*[local-name()='Name']='NetworkMonitoringSwitch']")
    $monitorDisclosure = $scheduled.SelectSingleNode(".//*[@*[local-name()='Name']='NetworkMonitoringDisclosure']")
    $monitorStatus = $scheduled.SelectSingleNode(".//*[@*[local-name()='Name']='NetworkMonitorStatusText']")
    if (-not $monitorSwitch -or -not $monitorDisclosure -or -not $monitorStatus -or
        $monitorSwitch.GetAttribute("Header") -cne "Monitor network health" -or
        $monitorSwitch.GetAttribute("AutomationProperties.Name") -cne "Monitor network health" -or
        $monitorDisclosure.GetAttribute("TextWrapping") -cne "Wrap" -or
        $monitorStatus.GetAttribute("AutomationProperties.LiveSetting") -cne "Polite") {
        throw "Background activity must group an accessible monitoring toggle, disclosure and polite status with scheduled scans."
    }
    $shellDocument = [xml](Get-Content (Join-Path $appDirectory "MainWindow.xaml") -Raw)
    $rootGrid = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='RootGrid']")
    $ribbonArea = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='BuildRibbonArea']")
    $navigation = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='MainNavigation']")
    if ($navigation.SelectSingleNode(".//*[local-name()='NavigationViewItem' and @Tag='RoomMap']")) {
        throw "Room map must be reachable from its three entry points, never from a sidebar item."
    }
    if ($ribbonArea.ParentNode -ne $rootGrid -or $navigation.ParentNode -ne $rootGrid -or
        $rootGrid.LastChild -ne $ribbonArea) {
        throw "The build ribbon must overlay navigation as a root sibling, outside the shared header layout."
    }
    $ribbon = $ribbonArea.SelectSingleNode(".//*[@*[local-name()='Name']='BuildRibbon']")
    if ($ribbon.GetAttribute("UseSystemFocusVisuals") -cne "False" -or
        $ribbon.GetAttribute("GotFocus") -cne "BuildRibbon_FocusChanged" -or
        $ribbon.GetAttribute("LostFocus") -cne "BuildRibbon_FocusChanged") {
        throw "The ribbon must use an in-button focus border rather than an unclipped native focus adorner."
    }
    $scanHeader = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanHeader']")
    $scanSource = Get-Content (Join-Path $appDirectory "MainWindow.Scan.cs") -Raw
    if ($scanSource -notmatch 'await SaveCompletedScanAsync\([^;]+\);\s*_scanMessage = null;' -or
        $scanSource -match 'Complete in ' -or
        $scanSource -notmatch 'new\[\] \{ _scanMessage, _snapshotError, _inventoryError, _backupError, _discoveryMessage, _windowsNotificationMessage, targetWarning \}' -or
        $scanSource -notmatch 'ScanMessages\.Visibility = _isScanning \|\| !string\.IsNullOrWhiteSpace\(status\)\s*\? Visibility\.Visible : Visibility\.Collapsed;') {
        throw "Scan success must clear only its own message, retain independent errors/warnings, and collapse unused messages."
    }
    $messages = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='ScanMessages']")
    $messageRows = $messages.ParentNode.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*")
    if ($messages.GetAttribute("Visibility") -cne "Collapsed" -or
        @($messageRows | Where-Object { $_.GetAttribute("Height") -cne "Auto" }).Count -ne 0) {
        throw "The shared header must not reserve an empty row for collapsed scan messages."
    }
    foreach ($id in @("DetectedNetworkLabel", "NetworkPicker", "ScanFreshnessText")) {
        $element = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='$id']")
        if (-not $element -or $element.GetAttribute("VerticalAlignment") -cne "Center") {
            throw "Shared network element '$id' must be centered in the shell header."
        }
    }
    $progress = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanProgressBar']")
    if ($progress.GetAttribute("Height") -cne "10" -or $progress.GetAttribute("MinHeight") -cne "8" -or
        $progress.GetAttribute("IsIndeterminate") -eq "True") {
        throw "Scan progress needs an 8-DIP native indicator and 10-DIP outer height to retain the high-contrast border."
    }
    $scan = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='ScanButton']")
    $cancel = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='CancelButton']")
    if (-not $scan -or -not $cancel -or $scan.ParentNode -ne $cancel.ParentNode -or
        $scan.ParentNode.LocalName -cne "Grid" -or $cancel.GetAttribute("AutomationProperties.Name") -cne "Cancel scan") {
        throw "Scan LAN and Cancel scan must occupy the same shared-header slot with their existing automation IDs."
    }
    $scanIcon = $scan.SelectSingleNode(".//*[local-name()='FontIcon']")
    $scanLabel = $scan.SelectSingleNode(".//*[local-name()='TextBlock']")
    if ($scan.GetAttribute("AutomationProperties.Name") -cne "Scan LAN" -or
        $scanIcon.GetAttribute("Glyph") -cne [string][char]0xE895 -or
        $scanIcon.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw" -or
        $scanIcon.GetAttribute("IsHitTestVisible") -cne "False" -or
        $scanIcon.HasAttribute("Foreground") -or $scanIcon.GetAttribute("IsTextScaleFactorEnabled") -eq "False" -or
        $scanIcon.NextSibling -ne $scanLabel -or $scanLabel.GetAttribute("Grid.Column") -cne "1" -or
        $scanLabel.GetAttribute("Text") -cne "Scan LAN" -or $scanLabel.GetAttribute("TextWrapping") -cne "Wrap") {
        throw "Scan LAN must retain its accessible label with a preceding decorative, theme-inherited, scalable refresh icon and wrapping text."
    }
    $devicesDocument = [xml](Get-Content (Join-Path $appDirectory "Views\DevicesPageView.xaml") -Raw)
    $devicesCode = Get-Content (Join-Path $appDirectory "Views\DevicesPageView.xaml.cs") -Raw
    $deviceRowCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\ScanResultRow.cs") -Raw
    $results = $devicesDocument.SelectSingleNode("//*[@*[local-name()='Name']='ResultsList']")
    $chevron = $results.SelectSingleNode(".//*[@*[local-name()='Name']='DeviceMacExpansionButton']")
    $expansionLines = $results.SelectSingleNode(".//*[@*[local-name()='Name']='DeviceMacExpansionLines']")
    if (-not $chevron -or -not $expansionLines -or
        $chevron.GetAttribute("Click") -cne "DeviceMacExpansionButton_Click" -or
        $chevron.GetAttribute("Visibility") -cne "{x:Bind HasEarlierMacAddresses, Mode=OneWay}" -or
        $expansionLines.LocalName -cne "ItemsControl" -or
        $results.GetAttribute("KeyDown") -cne "ResultsList_KeyDown" -or
        $devicesCode -notmatch 'HashSet<string> _expandedMacRows' -or
        $devicesCode -notmatch 'DeviceMacExpansionButton_Click' -or
        $devicesCode -notmatch 'ResultsList_KeyDown' -or
        $deviceRowCode -notmatch 'VisibleMacExpansionLines' -or
        $deviceRowCode -notmatch 'SearchExpandsMacAddresses') {
        throw "Devices must expose an in-row chevron, reusable MAC lines, remembered expansion state and hidden-search expansion without separate ListView items."
    }
    $matchButton = $devicesDocument.SelectSingleNode("//*[@*[local-name()='Name']='DeviceMatchButton']")
    $matchTooltip = $matchButton.SelectSingleNode("./*[local-name()='ToolTipService.ToolTip']/*[local-name()='ToolTip']")
    if (-not $matchTooltip -or
        $matchButton.GetAttribute("AutomationProperties.HelpText") -cne "{x:Bind MatchSuggestionText, Mode=OneWay}" -or
        $matchTooltip.GetAttribute("AutomationProperties.AutomationId") -cne "DeviceMatchTooltip" -or
        $matchTooltip.GetAttribute("AutomationProperties.Name") -cne "{x:Bind MatchSuggestionText, Mode=OneWay}" -or
        $matchTooltip.GetAttribute("Content") -cne "{x:Bind MatchSuggestionText, Mode=OneWay}") {
        throw "Possible-match buttons must expose the full hover copy on an explicitly identified, named ToolTip peer."
    }
    $matchButtonEnter = $matchButton.GetAttribute("PointerEntered")
    $matchButtonExit = $matchButton.GetAttribute("PointerExited")
    if ($matchButtonEnter -cne "DeviceMatchButton_PointerEntered" -or
        $matchButtonExit -cne "DeviceMatchButton_PointerExited") {
        throw "Possible-match ToolTips must explicitly open and close with pointer entry and exit."
    }
    $serviceButton = $devicesDocument.SelectSingleNode("//*[@*[local-name()='Name']='ServiceDiscoveryButton']")
    $serviceCell = $serviceButton.ParentNode
    $servicePorts = $serviceCell.SelectSingleNode("./*[local-name()='ItemsControl']")
    if ($serviceCell.GetAttribute("Grid.Column") -cne "3" -or -not $servicePorts -or
        $servicePorts.GetAttribute("ItemsSource") -cne "{x:Bind OpenPortItems, Mode=OneWay}" -or
        $servicePorts.GetAttribute("HorizontalAlignment") -cne "Left" -or
        $serviceButton.GetAttribute("Grid.Column") -cne "1" -or $serviceButton.GetAttribute("HorizontalAlignment") -cne "Right" -or
        $serviceButton.GetAttribute("Visibility") -cne "{x:Bind HasLatestServiceDiscovery, Mode=OneWay}" -or
        $serviceButton.GetAttribute("AutomationProperties.AutomationId") -cne "ServiceDiscoveryButton" -or
        $serviceButton.GetAttribute("AutomationProperties.Name") -cne "{x:Bind ServiceDiscoveryName, Mode=OneWay}" -or
        $serviceButton.GetAttribute("AutomationProperties.HelpText") -cne "{x:Bind ServiceDiscoveryText, Mode=OneWay}" -or
        $serviceButton.GetAttribute("ToolTipService.ToolTip") -cne "{x:Bind ServiceDiscoveryText, Mode=OneWay}" -or
        $serviceButton.SelectSingleNode("./*[local-name()='FontIcon']").GetAttribute("Glyph") -cne [string][char]0xE95A) {
        throw "The Open ports cell must keep verified ports left-aligned and a named, right-aligned U+E95A service-discovery button for latest-scan advertisements."
    }
    $detailsDocument = [xml](Get-Content (Join-Path $appDirectory "Views\DeviceDetailsPageView.xaml") -Raw)
    foreach ($id in @("MergeMacCount", "MergeMacOtherHeading", "MergeMacOtherName", "MergeMacReason")) {
        $node = $detailsDocument.SelectSingleNode("//*[@*[local-name()='Name']='$id']")
        if ($node.LocalName -cne "TextBlock" -or $node.GetAttribute("AutomationProperties.AutomationId") -cne $id) {
            throw "Merge suggestion state '$id' must remain a separately addressable text peer."
        }
    }
    if ($devicesDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanButton']")) {
        throw "Devices must not duplicate the shared primary scan action."
    }
    $statusStyle = $devicesDocument.SelectSingleNode("//*[@*[local-name()='Key']='StatusFilterStyle']")
    if ($statusStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='BorderThickness']").GetAttribute("Value") -cne "1" -or
        $statusStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='BorderBrush']").GetAttribute("Value") -cne "{ThemeResource ControlStrongStrokeColorDefaultBrush}") {
        throw "Status needs a subtle neutral stroke, distinct from an applied value and native accent focus."
    }
    $toolsDocument = [System.Xml.XmlDocument]::new()
    $toolsDocument.Load((Join-Path $appDirectory "Tools\ToolsPage.xaml"))
    $landing = $toolsDocument.SelectSingleNode("//*[@*[local-name()='Name']='ToolsLandingGrid']")
    $landingColumns = $landing.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*")
    $cards = @($landing.SelectNodes("./*[local-name()='Button']"))
    if ($landing.LocalName -cne "Grid" -or $landingColumns.Count -ne 2 -or
        @($landingColumns | Where-Object { $_.GetAttribute("Width") -cne "*" }).Count -ne 0) {
        throw "Tools cards must share two equal-width grid columns."
    }
    Assert-Equal @($cards | ForEach-Object { $_.GetAttribute("x:Name") }) `
        @("SqlEditorCard", "FingImportCard", "SpeedTestCard", "RoomMapCard", "NetworkHealthCard", "DatabaseBackupsCard") `
        "Tools visual and keyboard row order"
    foreach ($card in $cards) {
        if ($card.GetAttribute("Grid.ColumnSpan") -notin @("", "1") -or
            @($card.SelectNodes(".//*[local-name()='TextBlock']") |
                Where-Object { $_.GetAttribute("TextWrapping") -cne "Wrap" }).Count -ne 0) {
            throw "Tools cards must keep one column each and wrap all labels, including open actions."
        }
        $cardChevrons = @($card.SelectNodes(
            ".//*[local-name()='FontIcon' and @Style='{StaticResource NavigationChevronIconStyle}']"))
        $embeddedArrows = @($card.SelectNodes(".//*[local-name()='TextBlock']") |
            Where-Object { $_.GetAttribute("Text").Contains([char]0x2192) })
        if ($cardChevrons.Count -ne 1 -or $embeddedArrows.Count -ne 0) {
            throw "$($card.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')) must use one separate trailing chevron."
        }
    }
    $overviewDocument = [System.Xml.XmlDocument]::new()
    $overviewDocument.Load((Join-Path $appDirectory "Views\OverviewPageView.xaml"))
    $overviewCards = @($overviewDocument.SelectNodes(
        "//*[local-name()='Button' and @Style='{StaticResource ScannerSummaryButtonStyle}']"))
    if ($overviewCards.Count -ne 3) { throw "Overview must preserve its three whole-card navigation actions." }
    foreach ($card in $overviewCards) {
        $cardChevrons = @($card.SelectNodes(
            ".//*[local-name()='FontIcon' and @Style='{StaticResource NavigationChevronIconStyle}']"))
        $embeddedArrows = @($card.SelectNodes(".//*[local-name()='TextBlock']") |
            Where-Object { $_.GetAttribute("Text").Contains([char]0x2192) })
        if ($cardChevrons.Count -ne 1 -or $embeddedArrows.Count -ne 0) {
            throw "Overview navigation cards must use one separate trailing chevron and no embedded arrow."
        }
    }
    foreach ($link in @(
        @{ Path = "Views\NetworkPageView.xaml"; Id = "OpenNetworkHealthButton" },
        @{ Path = "Tools\NetworkHealthPage.xaml"; Id = "OpenServiceStatusButton" },
        @{ Path = "Tools\NetworkHealthPage.xaml"; Id = "NetworkHealthViewRoomMapButton" },
        @{ Path = "Views\PeopleRoomsPageView.xaml"; Id = "ViewRoomMapButton" },
        @{ Path = "Views\DeviceDetailsPageView.xaml"; Id = "DeviceViewHistory" }
    )) {
        $linkDocument = [System.Xml.XmlDocument]::new()
        $linkDocument.Load((Join-Path $appDirectory $link.Path))
        $linkNode = $linkDocument.SelectSingleNode(
            "//*[@*[local-name()='Name']='$($link.Id)' or @AutomationProperties.AutomationId='$($link.Id)']")
        if (-not $linkNode -or $linkNode.LocalName -cne "HyperlinkButton" -or
            [string]::IsNullOrWhiteSpace($linkNode.GetAttribute("AutomationProperties.Name"))) {
            throw "$($link.Id) must remain a text-style internal navigation link with its accessible name."
        }
        if ($linkNode.SelectNodes(".//*[local-name()='FontIcon']").Count -ne 0 -or
            $linkNode.GetAttribute("Content").Contains([char]0x203A) -or
            $linkNode.GetAttribute("Content").Contains([char]0x2192)) {
            throw "$($link.Id) must not add a decorative chevron or embedded arrow to internal-link text."
        }
    }
    $aboutDocument = [System.Xml.XmlDocument]::new()
    $aboutDocument.Load((Join-Path $appDirectory "Tools\AboutPage.xaml"))
    $browserLinks = @($aboutDocument.SelectNodes(
        "//*[local-name()='HyperlinkButton' and contains(@AutomationProperties.Name,'opens in browser')]"))
    if ($browserLinks.Count -ne 5) { throw "About must retain all five browser destinations." }
    foreach ($link in $browserLinks) {
        $externalIcons = @($link.SelectNodes(
            ".//*[local-name()='FontIcon' and @Style='{StaticResource ExternalLinkIconStyle}']"))
        $embeddedArrows = @($link.SelectNodes(".//*[local-name()='TextBlock']") |
            Where-Object { $_.GetAttribute("Text").Contains([char]0x2197) })
        if ($externalIcons.Count -ne 1 -or $embeddedArrows.Count -ne 0) {
            throw "About browser links must use one separate external-link icon."
        }
    }
    $toolIcons = @(
        @{ Page = "SpeedTestPage"; Title = "Speed test"; Card = "SpeedTestCard"; Click = "SpeedTestCard_Click"; Icon = "speed-test" },
        @{ Page = "NetworkHealthPage"; Title = "Network health"; Card = "NetworkHealthCard"; Click = "NetworkHealthCard_Click"; Icon = "troubleshooting" },
        @{ Page = "AboutPage"; Title = "About FingVibe"; Card = "AboutCard"; Click = "AboutCard_Click"; Icon = "about" },
        @{ Page = "FingImportPage"; Title = "Import from Fing"; Card = "FingImportCard"; Click = "FingImportCard_Click"; Icon = "import" },
        @{ Page = "SqlEditorPage"; Title = "SQL editor"; Card = "SqlEditorCard"; Click = "SqlEditorCard_Click"; Icon = "tools" },
        @{ Page = "DatabaseBackupsPage"; Title = "Database backups"; Card = "DatabaseBackupsCard"; Click = "DatabaseBackupsCard_Click"; Icon = "tools" }
    )
    $headerIcon = [System.Xml.XmlDocument]::new()
    $headerIcon.Load((Join-Path $appDirectory "PageHeaderIcon.xaml"))
    $headerIconRoot = $headerIcon.DocumentElement
    $colorIcon = $headerIconRoot.SelectSingleNode(".//*[local-name()='Image']")
    $monochromeIcon = $headerIconRoot.SelectSingleNode(".//*[local-name()='BitmapIcon']")
    if ($headerIconRoot.LocalName -cne "UserControl" -or $headerIconRoot.GetAttribute("Width") -cne "48" -or
        $headerIconRoot.GetAttribute("Height") -cne "48" -or $headerIconRoot.GetAttribute("IsHitTestVisible") -cne "False" -or
        $headerIconRoot.GetAttribute("IsTabStop") -cne "False" -or
        $headerIconRoot.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw" -or
        -not $colorIcon -or $colorIcon.GetAttribute("Stretch") -cne "Uniform" -or
        $colorIcon.GetAttribute("Style") -cne "{ThemeResource PageHeaderColorIconStyle}" -or
        $colorIcon.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw" -or
        -not $monochromeIcon -or $monochromeIcon.GetAttribute("ShowAsMonochrome") -cne "True" -or
        $monochromeIcon.GetAttribute("Foreground") -cne "{ThemeResource TextFillColorPrimaryBrush}" -or
        $monochromeIcon.GetAttribute("Style") -cne "{ThemeResource PageHeaderMonochromeIconStyle}" -or
        $monochromeIcon.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw") {
        throw "Page header icons must be decorative 48-DIP full-color art with a theme-colored single-color equivalent."
    }
    $appResources = [System.Xml.XmlDocument]::new()
    $appResources.Load((Join-Path $appDirectory "App.xaml"))
    foreach ($theme in @(
        @{ Key = "Light"; Color = "Visible"; Monochrome = "Collapsed" },
        @{ Key = "Dark"; Color = "Visible"; Monochrome = "Collapsed" },
        @{ Key = "HighContrast"; Color = "Collapsed"; Monochrome = "Visible" }
    )) {
        $dictionary = $appResources.SelectSingleNode("//*[local-name()='ResourceDictionary.ThemeDictionaries']/*[@*[local-name()='Key']='$($theme.Key)']")
        foreach ($style in @(
            @{ Key = "PageHeaderColorIconStyle"; Target = "Image"; Visibility = $theme.Color },
            @{ Key = "PageHeaderMonochromeIconStyle"; Target = "BitmapIcon"; Visibility = $theme.Monochrome }
        )) {
            $node = $dictionary.SelectSingleNode("./*[local-name()='Style' and @*[local-name()='Key']='$($style.Key)']")
            if (-not $node -or $node.GetAttribute("TargetType") -cne $style.Target -or
                $node.SelectSingleNode("./*[local-name()='Setter' and @Property='Visibility']").GetAttribute("Value") -cne $style.Visibility) {
                throw "$($theme.Key) page headers must show $($style.Target) as $($style.Visibility)."
            }
        }
    }
    foreach ($tool in $toolIcons) {
        $pageDocument = [System.Xml.XmlDocument]::new()
        $pageDocument.Load((Join-Path $appDirectory "Tools\$($tool.Page).xaml"))
        if ($tool.Page -eq "NetworkHealthPage") {
            $run = $pageDocument.SelectSingleNode("//*[@*[local-name()='Name']='RunButton']")
            if ($run.GetAttribute("Style") -cne "{ThemeResource AccentButtonStyle}") {
                throw "Run diagnostics must use the existing primary-action accent style."
            }
        }
        $card = $toolsDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($tool.Card)']")
        if ($tool.Page -ne "AboutPage" -and ($card.LocalName -cne "Button" -or $card.GetAttribute("Click") -cne $tool.Click -or
            $card.GetAttribute("AutomationProperties.Name") -cne $tool.Title -or
            $card.SelectNodes(".//*[local-name()='Button' or local-name()='HyperlinkButton']").Count -ne 0)) {
            throw "$($tool.Title) must remain one landing button with its existing handler and accessible name."
        }
        $pageTitle = $pageDocument.SelectSingleNode("//*[local-name()='TextBlock' and @Text='$($tool.Title)' and @Style='{StaticResource ScannerPageTitleStyle}']")
        $titles = @($pageTitle)
        if ($tool.Page -ne "AboutPage") {
            $titles += $card.SelectSingleNode(".//*[local-name()='TextBlock' and @Text='$($tool.Title)']")
        } elseif ($card) { throw "About must no longer appear in Tools." }
        foreach ($title in $titles) {
            $isPageTitle = $title -eq $pageTitle
            $titleColumn = if ($isPageTitle) { "2" } else { "1" }
            if (-not $title -or $title.GetAttribute("TextWrapping") -cne "Wrap" -or
                $title.GetAttribute("Grid.Column") -cne $titleColumn -or $title.GetAttribute("VerticalAlignment") -cne "Center") {
                throw "$($tool.Title) must wrap and center beside its icon."
            }
            $header = $title.ParentNode
            $columns = $header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*[local-name()='ColumnDefinition']")
            $expectedColumns = if ($isPageTitle) { 3 } else { 2 }
            if ($header.LocalName -cne "Grid" -or $header.GetAttribute("ColumnSpacing") -cne "12" -or
                $columns.Count -ne $expectedColumns -or $columns[0].GetAttribute("Width") -cne "Auto" -or
                $columns[$expectedColumns - 1].GetAttribute("Width") -cne "*") {
                throw "$($tool.Title) must reserve icon space and constrain the title for wrapping."
            }
            if ($isPageTitle) {
                $destination = if ($tool.Page -eq "AboutPage") { "Settings" } else { "Tools" }
                $back = $header.SelectSingleNode("./*[local-name()='Button' and @AutomationProperties.Name='Back to $destination']")
                if (-not $back -or $columns[1].GetAttribute("Width") -cne "Auto" -or
                    $back.GetAttribute("Grid.Column") -notin @("", "0") -or
                    $header.SelectSingleNode("./*[local-name()='Button' or local-name()='PageHeaderIcon' or local-name()='TextBlock']") -ne $back -or
                    $back.GetAttribute("Content") -cne "$([char]0x2190) $destination" -or
                    $pageDocument.SelectNodes("//*[local-name()='Button' and @AutomationProperties.Name='Back to $destination']").Count -ne 1 -or
                    $back.GetAttribute("Style") -cne "{StaticResource PageBackButtonStyle}" -or
                    $back.HasAttribute("Width") -or $back.HasAttribute("Height")) {
                    throw "$($tool.Title) must have one content-safe neutral Back action first in its title row."
                }
            }
            $icons = $header.SelectNodes("./*[local-name()='PageHeaderIcon']")
            if ($icons.Count -ne 1) { throw "$($tool.Title) must have exactly one decorative header icon." }
            $icon = $icons[0]
            if ($isPageTitle -and $icon.GetAttribute("Grid.Column") -cne "1") {
                throw "$($tool.Title) must keep its decorative icon with the heading after Back."
            }
            if ($icon.GetAttribute("Icon") -cne $tool.Icon -or $icon.HasAttribute("Width") -or $icon.HasAttribute("Height")) {
                throw "$($tool.Title) icon must use the shared 48-DIP '$($tool.Icon)' family icon on both surfaces."
            }
            foreach ($variant in @("color", "mono")) {
                if (-not (Test-Path -LiteralPath (Join-Path $appDirectory "Assets\PageIcons\$($tool.Icon)-$variant.png"))) {
                    throw "$($tool.Title) icon is missing its $variant family asset."
                }
            }
        }
        if ($tool.Page -eq "AboutPage" -and
            ($pageTitle.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") -cne "PageHeading" -or
             $pageTitle.GetAttribute("IsTabStop") -cne "True")) {
            throw "About must preserve its named, keyboard-focusable heading."
        }
    }
    $shellCode = (Get-ChildItem (Join-Path $appDirectory "MainWindow*.cs") |
        ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    foreach ($page in $pageViews.Keys) {
        $view = $pageViews[$page]
        $node = $applicationDocument.SelectSingleNode("//*[@*[local-name()='Name']='$page']")
        if ($node.LocalName -cne $view -or $node.ChildNodes.Count -ne 0) {
            throw "$page must be composed as $view without inline page content."
        }
        $viewDocument = [System.Xml.XmlDocument]::new()
        $viewDocument.Load((Join-Path $appDirectory "Views\$view.xaml"))
        if ($viewDocument.DocumentElement.LocalName -cne "UserControl" -or
            $viewDocument.DocumentElement.GetAttribute("Class", "http://schemas.microsoft.com/winfx/2006/xaml") -cne "FingVibe.App.Views.$view") {
            throw "$view must have its own UserControl namescope and class."
        }
        $viewCode = (Get-ChildItem (Join-Path $appDirectory "Views\$view.*.cs") |
            ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        if ($viewCode -match '(?m)^\s*(public|internal)\s+(TextBlock|TextBox|ComboBox|Button|ListView|ScrollViewer|Grid|Image|FontIcon|Expander)\??\s+\w+\s*(\{|=>)') {
            throw "$view must not expose its child controls."
        }
        foreach ($child in $viewDocument.SelectNodes("//*[@*[local-name()='Name']]")) {
            if ($child.LocalName -in @("VisualState", "VisualStateGroup")) { continue }
            $childName = $child.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
            if ($childName -ne $page -and $shellCode -match "\b$([regex]::Escape($childName))\b") {
                throw "Shell code must use $view APIs, not the child control $childName."
            }
        }
        foreach ($attribute in $viewDocument.SelectNodes("//@*")) {
            if ($attribute.Value.StartsWith("{ThemeResource ") -and -not $attribute.Value.EndsWith("}")) {
                throw "Unclosed ThemeResource in $view."
            }
            if ($attribute.LocalName -in @("Click", "ItemClick", "TextChanged", "SelectionChanged", "SizeChanged") -and
                $viewCode -notmatch "\b$([regex]::Escape($attribute.Value))\s*\(") {
                throw "$view must own handler $($attribute.Value)."
            }
        }
    }
    foreach ($view in @("DevicesPageView", "SettingsPageView")) {
        $viewCode = Get-Content (Join-Path $appDirectory "Views\$view.xaml.cs") -Raw
        if ($viewCode -notmatch 'DeviceColumnLayout Columns => DeviceColumnLayout.Current') {
            throw "$view must bind the shared table column layout."
        }
        $details = [xml](Get-Content (Join-Path $appDirectory "Views\DeviceDetailsPageView.xaml") -Raw)
        $overview = $details.SelectSingleNode("//*[@*[local-name()='Name']='NetworkOverviewCard']")
        $assignments = $details.SelectSingleNode("//*[@*[local-name()='Name']='AssignmentsCard']")
        $identification = $details.SelectSingleNode("//*[@*[local-name()='Name']='IdentificationCard']")
        $ports = $details.SelectSingleNode("//*[@*[local-name()='Name']='PortsServicesCard']")
        $serviceDiscovery = $details.SelectSingleNode("//*[@*[local-name()='Name']='ServiceDiscoveryCard']")
        if ($overview.ParentNode -ne $assignments.ParentNode -or
            $assignments.GetAttribute("Grid.Column") -ne "1" -or
            $identification.ParentNode -ne $overview.ParentNode.ParentNode -or
            $identification.NextSibling -ne $serviceDiscovery -or $serviceDiscovery.NextSibling -ne $ports) {
            throw "Details must put network/assignments in the top row, then full-width identification, service discovery and ports."
        }
        $assignmentLayout = $assignments.FirstChild
        $assignmentNote = $details.SelectSingleNode("//*[@*[local-name()='Name']='DeviceAssignmentStatusText']")
        if ($overview.GetAttribute("VerticalAlignment") -ne "Stretch" -or
            $assignments.GetAttribute("VerticalAlignment") -ne "Stretch" -or
            $assignmentLayout.LocalName -ne "Grid" -or
            $assignmentLayout.FirstChild.LastChild.GetAttribute("Height") -ne "*" -or
            [int]$assignmentNote.GetAttribute("Grid.Row") -ne $assignmentLayout.FirstChild.ChildNodes.Count - 1 -or
            $assignmentNote.GetAttribute("VerticalAlignment") -ne "Bottom") {
            throw "Top-row cards must share their height, with the assignments note anchored at the bottom."
        }
        $networkNote = $details.SelectSingleNode("//*[@*[local-name()='Name']='DeviceAddressSourceText']")
        if ($networkNote.ParentNode.GetAttribute("VerticalAlignment") -ne "Bottom" -or
            $networkNote.ParentNode.GetAttribute("Grid.Row") -ne "2" -or
            $overview.FirstChild.FirstChild.LastChild.GetAttribute("Height") -ne "*") {
            throw "The network footnote must stay aligned with the Assignments footer when usage evidence grows."
        }
        $valueCode = Get-Content (Join-Path $appDirectory "Views\DeviceDetailValue.cs") -Raw
        if ($valueCode -notmatch 'HyperlinkButton _browser' -or
            $valueCode -notmatch '_valueRow.Children.Add\(_copy\)' -or
            $valueCode -notmatch '_copy.Opacity = _rename.Opacity = visible' -or
            $valueCode -notmatch '_rename.FocusState != FocusState.Unfocused') {
            throw "Details must keep native browser links and reserved hover/focus copy actions beside values."
        }
    }
