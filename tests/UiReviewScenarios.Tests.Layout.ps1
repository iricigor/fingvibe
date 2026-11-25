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
    foreach ($pagePath in @(
        "Views\OverviewPageView.xaml",
        "Views\NetworkPageView.xaml",
        "Views\DevicesPageView.xaml",
        "Views\DeviceDetailsPageView.xaml",
        "Views\PeopleRoomsPageView.xaml",
        "Views\PersonDetailsPageView.xaml",
        "Views\RoomDetailsPageView.xaml",
        "Views\RoomMapPageView.xaml",
        "Views\SettingsPageView.xaml",
        "Tools\ToolsPage.xaml",
        "Tools\AboutPage.xaml",
        "Tools\DatabaseBackupsPage.xaml",
        "Tools\FingImportPage.xaml",
        "Tools\NetworkHealthPage.xaml",
        "Tools\ServiceStatusPage.xaml",
        "Tools\SpeedTestPage.xaml",
        "Tools\SqlEditorPage.xaml"
    )) {
        $pageDocument = [xml](Get-Content (Join-Path $appDirectory $pagePath) -Raw)
        $headerElements = @(
            $pageDocument.SelectNodes("//*[contains(@Style,'ScannerPageTitleStyle') or contains(@Style,'PageHeaderTitleStyle')]")
            $pageDocument.SelectNodes("//*[@*[local-name()='Name' and .='HeaderGrid']]")
            $pageDocument.SelectNodes("//*[@*[local-name()='Name' and .='PeopleRoomsHeadingRow']]")
            $pageDocument.SelectNodes("//*[@*[local-name()='Name' and .='PersonDetailName']]")
            $pageDocument.SelectNodes("//*[@*[local-name()='Name' and .='RoomDetailName']]")
            $pageDocument.SelectNodes("//*[@AutomationProperties.Name]") |
                Where-Object { $_.GetAttribute("AutomationProperties.Name") -like "Back to *" }
            $pageDocument.SelectNodes("//*[local-name()='PageBackButton']")
        )
        if ($headerElements.Count -eq 0) {
            throw "$pagePath must expose its fixed page-header contract."
        }
        foreach ($headerElement in $headerElements) {
            if ($headerElement.SelectSingleNode("ancestor::*[local-name()='ScrollViewer']")) {
                throw "$pagePath places a page heading or Back control inside a ScrollViewer; headers must remain stationary while the body scrolls."
            }
        }
    }
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
    if ($roomMapBackButton.LocalName -cne "PageBackButton" -or
        $roomMapBackButton.GetAttribute("Destination") -cne "Rooms" -or
        $roomMapBackButton.HasAttribute("Style") -or
        $roomMapOnlineOnly.GetAttribute("IsOn") -cne "True" -or
        $roomMapOnlineOnly.GetAttribute("Header") -cne "Only online") {
        throw "Room map must use the shared Back control (Back to Rooms by default) and start with Only online enabled."
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
        $headingRow.GetAttribute("Style") -cne "{StaticResource PageHeaderRowStyle}" -or
        $headingTitle.GetAttribute("Grid.Column") -cne "1" -or
        $headingTitle.GetAttribute("Style") -cne "{StaticResource PageHeaderTitleStyle}") {
        throw "People & rooms must align its wrapping title beside one shared 48-DIP 'people-rooms' family icon in the shared page header."
    }
    $navItem = [regex]::Match((Get-Content (Join-Path $appDirectory "MainWindow.xaml") -Raw),
        '(?s)<NavigationViewItem x:Name="PeopleRoomsNavItem".*?</NavigationViewItem>').Value
    if ($navItem -notmatch 'UriSource="ms-appx:///Assets/PageIcons/people-rooms-mono-48\.png"' -or
        $navItem -notmatch 'Style="\{ThemeResource SidebarPeopleRoomsIconStyle\}"' -or $navItem -match '<PathIcon\b') {
        throw "People & rooms navigation must use one theme-colored single-color 'people-rooms' family icon."
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
    $settingsPage = $settings.SelectSingleNode("//*[@*[local-name()='Name']='SettingsPage']")
    $settingsScroll = $settings.SelectSingleNode("//*[@*[local-name()='Name']='SettingsScroll']")
    if (-not $settingsPage -or $settingsPage.LocalName -cne "Grid" -or -not $settingsScroll -or
        $settingsScroll.GetAttribute("AutomationProperties.AutomationId") -cne "SettingsPage") {
        throw "Settings must keep its fixed page grid for header visibility and expose the body ScrollViewer as the SettingsPage automation peer."
    }
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
    $headingBandStyle = $settings.SelectSingleNode("//*[@*[local-name()='Key']='SettingsCardHeadingBandStyle']")
    if (-not $headingBandStyle -or
        $headingBandStyle.GetAttribute("BasedOn") -cne "{StaticResource CardHeadingBandStyle}" -or
        $headingBandStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='Margin']").GetAttribute("Value") -cne "0" -or
        $headingBandStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='Background']").GetAttribute("Value") -cne "Transparent" -or
        $headingBandStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='BorderThickness']").GetAttribute("Value") -cne "0") {
        throw "Settings card headings must inherit the shared H4 heading without the scanner-card offset or a shaded band that leaves the native chevron outside it."
    }
    $navigationCardPadding = $settings.SelectSingleNode(
        "//*[@*[local-name()='Key']='SettingsNavigationCardStyle']/*[local-name()='Setter' and @Property='Padding']")
    if (-not $navigationCardPadding -or $navigationCardPadding.GetAttribute("Value") -cne "16,0,8,0") {
        throw "The About card must keep the Expander header's 16-DIP inset so all Settings titles share one column."
    }
    foreach ($entry in @(
        @{ Id = "AppearanceSection"; Type = "Expander"; Summary = "AppearanceSummary"; Heading = "AppearanceSettingsHeading" },
        @{ Id = "DevicesSection"; Type = "Expander"; Summary = "DevicesSummary"; Heading = "DevicesSettingsHeading" },
        @{ Id = "ScheduledScansSection"; Type = "Expander"; Summary = "ScheduledScansSummary"; Heading = "ScheduledScansHeading" },
        @{ Id = "AboutSettingsButton"; Type = "Button"; Summary = "AboutSummary"; Heading = "AboutSettingsHeading" }
    )) {
        $card = $cards.SelectSingleNode(".//*[@*[local-name()='Name']='$($entry.Id)']")
        $band = $card.SelectSingleNode(".//*[local-name()='Border' and @Style='{StaticResource SettingsCardHeadingBandStyle}']")
        $row = if ($band) { $band.SelectSingleNode("./*[local-name()='Grid' and @Style='{StaticResource CardHeadingRowStyle}']") }
        $icon = if ($row) { $row.SelectSingleNode(".//*[local-name()='FontIcon' and @Style='{StaticResource CardHeadingIconStyle}']") }
        $title = if ($row) { $row.SelectSingleNode(".//*[@*[local-name()='Name']='$($entry.Heading)' and @Style='{StaticResource CardHeadingTextStyle}']") }
        $summary = if ($row) { $row.SelectSingleNode(".//*[@*[local-name()='Name']='$($entry.Summary)' and @Style='{StaticResource SettingsCardSummaryStyle}']") }
        if ($card.LocalName -cne $entry.Type -or -not $band -or -not $row -or -not $icon -or
            -not $icon.GetAttribute("Glyph") -or -not $title -or -not $summary -or
            $title.HasAttribute("FontSize") -or $title.HasAttribute("FontWeight") -or $title.HasAttribute("Foreground")) {
            throw "$($entry.Id) must preserve its native interaction and use the shared H4 icon, band and styled heading."
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
    $closeSource = Get-Content (Join-Path $appDirectory "MainWindow.xaml.cs") -Raw
    if ($closeSource -notmatch '(?s)await ToolsPage\.StopForWindowCloseAsync\(\);\s*await TryInstallScheduledUpdateOnCloseAsync\(\);' -or
        $closeSource -notmatch '(?s)finally\s*\{\s*_updateCloseScheduler\?\.Dispose\(\);\s*StopUpdates\(\);') {
        throw "Postponed update handoff must run after existing activity shutdown and before the final close cleanup."
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
    $toolsLandingContainer = $toolsDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='ToolsLandingContainer']")
    $toolsLandingScroll = $toolsDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='ToolsLanding']")
    if ($toolsLandingContainer.LocalName -cne "Grid" -or $toolsLandingScroll.LocalName -cne "ScrollViewer" -or
        $toolsLandingScroll.GetAttribute("AutomationProperties.AutomationId") -cne "ToolsLanding") {
        throw "Tools must keep its fixed landing grid while exposing the body ScrollViewer as the ToolsLanding automation and ScrollPattern peer."
    }
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
    # #688: content cards on the main pages start with the shared H4 card heading used by Device Details (#578).
    foreach ($page in @(
        @{ Path = "Views\OverviewPageView.xaml"; Headings = @("Network", "Network setup") },
        @{ Path = "Views\NetworkPageView.xaml"; Headings = @("NetworkIdentityText", "Network health", "Device activity") },
        @{ Path = "Views\PeopleRoomsPageView.xaml"; Headings = @("People", "Rooms") },
        @{ Path = "Views\PersonDetailsPageView.xaml"; Headings = @("Equipment activity") },
        @{ Path = "Views\RoomDetailsPageView.xaml"; Headings = @("Assigned devices") }
    )) {
        $document = [System.Xml.XmlDocument]::new()
        $document.Load((Join-Path $appDirectory $page.Path))
        $bands = @($document.SelectNodes("//*[local-name()='Border' and @Style='{StaticResource CardHeadingBandStyle}']"))
        $titles = @()
        foreach ($band in $bands) {
            $card = $band.ParentNode.ParentNode
            $first = $card.SelectSingleNode("./*/*[not(contains(local-name(), '.'))]")
            $icon = $band.SelectSingleNode(".//*[local-name()='FontIcon' and @Style='{StaticResource CardHeadingIconStyle}']")
            $title = $band.SelectSingleNode(".//*[local-name()='TextBlock' and @Style='{StaticResource CardHeadingTextStyle}']")
            if ($card.GetAttribute("Style") -cne "{StaticResource ScannerSummaryCardStyle}" -or $first -ne $band -or
                -not $icon -or -not $icon.GetAttribute("Glyph") -or -not $title -or
                $title.HasAttribute("FontSize") -or $title.HasAttribute("FontWeight") -or $title.HasAttribute("Foreground")) {
                throw "$($page.Path) card headings must start their card with one shared band holding an icon and styled heading."
            }
            # Zero-padding table cards keep the band flush and the 12-DIP inset shared with their column headers.
            $zeroPadding = $card.GetAttribute("Padding") -eq "0"
            if (($zeroPadding -and ($band.GetAttribute("Margin") -cne "0" -or $band.GetAttribute("Padding") -cne "12,10")) -or
                (-not $zeroPadding -and ($band.HasAttribute("Margin") -or $band.HasAttribute("Padding")))) {
                throw "$($page.Path) heading bands may only override their insets inside zero-padding table cards."
            }
            $titles += if ($title.HasAttribute("x:Name")) { $title.GetAttribute("x:Name") } else { $title.GetAttribute("Text") }
        }
        if (($titles -join "|") -cne ($page.Headings -join "|")) {
            throw "$($page.Path) must use the shared card heading for exactly: $($page.Headings -join ', '); found $($titles -join ', ')."
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
    $scheduledStatus = $aboutDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='UpdateScheduledStatus']")
    $cancelScheduled = $aboutDocument.SelectSingleNode(
        "//*[@*[local-name()='Name']='CancelScheduledUpdateButton']")
    if (-not $scheduledStatus -or $scheduledStatus.GetAttribute("AutomationProperties.LiveSetting") -cne "Polite" -or
        $scheduledStatus.GetAttribute("Visibility") -cne "Collapsed" -or -not $cancelScheduled -or
        $cancelScheduled.GetAttribute("Click") -cne "CancelScheduledUpdate_Click" -or
        $cancelScheduled.GetAttribute("Visibility") -cne "Collapsed") {
        throw "About must expose one polite scheduled-update line and one collapsed Cancel scheduled update action."
    }
    $browserLinks = @($aboutDocument.SelectNodes(
        "//*[local-name()='HyperlinkButton' and contains(@AutomationProperties.Name,'opens in browser')]"))
    if ($browserLinks.Count -ne 7) { throw "About must retain all seven browser destinations." }
    foreach ($link in $browserLinks) {
        $externalIcons = @($link.SelectNodes(
            ".//*[local-name()='FontIcon' and @Style='{StaticResource ExternalLinkIconStyle}']"))
        $embeddedArrows = @($link.SelectNodes(".//*[local-name()='TextBlock']") |
            Where-Object { $_.GetAttribute("Text").Contains([char]0x2197) })
        if ($externalIcons.Count -ne 1 -or $embeddedArrows.Count -ne 0) {
            throw "About browser links must use one separate external-link icon."
        }
    }
    $updateItems = @($aboutDocument.SelectSingleNode("//*[@*[local-name()='Name']='InstallUpdateButton']").ParentNode.ChildNodes |
        Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { $_.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") })
    $notesExpander = $aboutDocument.SelectSingleNode("//*[@*[local-name()='Name']='ReleaseNotesExpander']")
    if ([Array]::IndexOf($updateItems, "CancelScheduledUpdateButton") -ne [Array]::IndexOf($updateItems, "InstallUpdateButton") + 1 -or
        [Array]::IndexOf($updateItems, "ReleaseNotesExpander") -ne [Array]::IndexOf($updateItems, "CancelScheduledUpdateButton") + 1 -or
        [Array]::IndexOf($updateItems, "ReleaseNotesFallbackLink") -ne [Array]::IndexOf($updateItems, "ReleaseNotesExpander") + 1 -or
        $notesExpander.GetAttribute("IsExpanded") -cne "False" -or
        $notesExpander.SelectSingleNode(".//*[local-name()='ScrollViewer' or local-name()='WebView2' or local-name()='RichTextBlock' or local-name()='Hyperlink']") -or
        @($notesExpander.SelectNodes(".//*[local-name()='HyperlinkButton']")).Count -ne 1) {
        throw "Release notes must be a collapsed expander below Update now, using page scrolling, plain text and one explicit GitHub link."
    }
    # #689: content cards on the tool pages start with the shared H4 card heading used by Device Details (#578).
    foreach ($toolPage in @(
        @{ Path = "Tools\NetworkHealthPage.xaml"; Headings = @("Incident history", "Network path and status",
            "Detailed checkpoint diagnostics", "Traceroute", "Connection and checks")
            # The live health state and the Service status entry tile keep their own status and page-icon treatments.
            Excluded = @("CurrentHealthCard", "ServiceStatusEntryCard") },
        @{ Path = "Tools\SpeedTestPage.xaml"; Headings = @("Test", "Live measurement", "Results") },
        @{ Path = "Tools\FingImportPage.xaml"; Headings = @("1   Choose a file", "2   Analysis", "3   Changes and conflicts") },
        @{ Path = "Tools\AboutPage.xaml"; Headings = @("FingVibe LAN Scanner", "Updates") }
    )) {
        $toolDocument = [System.Xml.XmlDocument]::new()
        $toolDocument.Load((Join-Path $appDirectory $toolPage.Path))
        $toolTitles = @()
        foreach ($band in @($toolDocument.SelectNodes("//*[local-name()='Border' and @Style='{StaticResource CardHeadingBandStyle}']"))) {
            $card = $band.ParentNode.ParentNode
            $first = $card.SelectSingleNode("./*/*[not(contains(local-name(), '.'))]")
            $icon = $band.SelectSingleNode(".//*[local-name()='FontIcon' and @Style='{StaticResource CardHeadingIconStyle}']")
            $title = $band.SelectSingleNode(".//*[local-name()='TextBlock' and @Style='{StaticResource CardHeadingTextStyle}']")
            if ($card.GetAttribute("Style") -cne "{StaticResource ScannerSummaryCardStyle}" -or $first -ne $band -or
                -not $icon -or -not $icon.GetAttribute("Glyph") -or -not $title -or $band.HasAttribute("Margin") -or
                $band.HasAttribute("Padding") -or $title.HasAttribute("FontSize") -or $title.HasAttribute("FontWeight") -or
                $title.HasAttribute("Foreground")) {
                throw "$($toolPage.Path) card headings must start their card with one shared band holding an icon and styled heading."
            }
            $toolTitles += $title.GetAttribute("Text")
        }
        $plainHeadings = @($toolDocument.SelectNodes("//*[local-name()='Border' and @Style='{StaticResource ScannerSummaryCardStyle}']//*[@Style='{ThemeResource SubtitleTextBlockStyle}' and @Text]") |
            Where-Object { $_.SelectSingleNode("ancestor::*[local-name()='Border' and @Style='{StaticResource ScannerSummaryCardStyle}'][1]").GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") -notin @($toolPage.Excluded) })
        if (($toolTitles -join "|") -cne ($toolPage.Headings -join "|") -or $plainHeadings.Count -ne 0) {
            throw "$($toolPage.Path) must use the shared card heading for exactly: $($toolPage.Headings -join ', '); found $($toolTitles -join ', ')."
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
        $pageTitle = $pageDocument.SelectSingleNode("//*[local-name()='TextBlock' and @Text='$($tool.Title)' and @Style='{StaticResource PageHeaderTitleStyle}']")
        $titles = @($pageTitle)
        if ($tool.Page -ne "AboutPage") {
            $titles += $card.SelectSingleNode(".//*[local-name()='TextBlock' and @Text='$($tool.Title)']")
        } elseif ($card) { throw "About must no longer appear in Tools." }
        foreach ($title in $titles) {
            $isPageTitle = $title -eq $pageTitle
            $titleColumn = if ($isPageTitle) { "2" } else { "1" }
            # Page titles get wrapping and centering from the shared PageHeaderTitleStyle (#657).
            if (-not $title -or $title.GetAttribute("Grid.Column") -cne $titleColumn -or
                (-not $isPageTitle -and ($title.GetAttribute("TextWrapping") -cne "Wrap" -or
                    $title.GetAttribute("VerticalAlignment") -cne "Center"))) {
                throw "$($tool.Title) must wrap and center beside its icon."
            }
            $header = $title.ParentNode
            $columns = $header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*[local-name()='ColumnDefinition']")
            $expectedColumns = if ($isPageTitle) { 3 } else { 2 }
            $headerSpacing = if ($isPageTitle) { $header.GetAttribute("Style") -ceq "{StaticResource PageHeaderRowStyle}" }
                else { $header.GetAttribute("ColumnSpacing") -ceq "12" }
            if ($header.LocalName -cne "Grid" -or -not $headerSpacing -or
                $columns.Count -ne $expectedColumns -or $columns[0].GetAttribute("Width") -cne "Auto" -or
                $columns[$expectedColumns - 1].GetAttribute("Width") -cne "*") {
                throw "$($tool.Title) must reserve icon space and constrain the title for wrapping."
            }
            if ($isPageTitle) {
                $destination = if ($tool.Page -eq "AboutPage") { "Settings" } else { "Tools" }
                $back = $header.SelectSingleNode("./*[local-name()='PageBackButton' and @Destination='$destination']")
                if (-not $back -or $columns[1].GetAttribute("Width") -cne "Auto" -or
                    $back.GetAttribute("Grid.Column") -notin @("", "0") -or
                    $header.SelectSingleNode("./*[local-name()='Button' or local-name()='PageBackButton' or local-name()='PageHeaderIcon' or local-name()='TextBlock']") -ne $back -or
                    $back.HasAttribute("Content") -or $back.HasChildNodes -or
                    $pageDocument.SelectNodes("//*[local-name()='PageBackButton']").Count -ne 1 -or
                    $back.HasAttribute("Style") -or
                    $back.HasAttribute("Width") -or $back.HasAttribute("Height")) {
                    throw "$($tool.Title) must have one content-safe shared Back control first in its title row."
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
    # #657: every main and tool page shares one compact fixed header: [Back, 16 DIP,] 48-DIP icon, 12 DIP, title.
    $headerStyles = @{}
    foreach ($key in @("PageHeaderRowStyle", "PageHeaderTitleStyle", "ScannerPageTitleStyle")) {
        $headerStyles[$key] = $appResources.SelectSingleNode("/*/*/*[local-name()='ResourceDictionary']/*[local-name()='Style' and @*[local-name()='Key']='$key']")
        if (-not $headerStyles[$key]) { throw "App resources must define $key." }
    }
    $headerSetters = {
        param($Style)
        $values = [ordered]@{}
        foreach ($setter in $Style.SelectNodes("./*[local-name()='Setter']")) { $values[$setter.GetAttribute("Property")] = $setter.GetAttribute("Value") }
        ($values.Keys | ForEach-Object { "$_=$($values[$_])" }) -join ";"
    }
    $styleOrder = @($appResources.SelectNodes("//*[local-name()='Style']/@*[local-name()='Key']") | ForEach-Object Value)
    if ($headerStyles.PageHeaderRowStyle.GetAttribute("TargetType") -cne "Grid" -or
        (& $headerSetters $headerStyles.PageHeaderRowStyle) -cne "ColumnSpacing=12;MinHeight={StaticResource PageHeaderControlHeight}" -or
        $headerStyles.PageHeaderTitleStyle.GetAttribute("TargetType") -cne "TextBlock" -or
        $headerStyles.PageHeaderTitleStyle.GetAttribute("BasedOn") -cne "{StaticResource ScannerPageTitleStyle}" -or
        (& $headerSetters $headerStyles.PageHeaderTitleStyle) -cne "Margin=0;VerticalAlignment=Center;TextWrapping=Wrap" -or
        $headerStyles.ScannerPageTitleStyle.GetAttribute("BasedOn") -cne "{StaticResource TitleTextBlockStyle}" -or
        $styleOrder.IndexOf("PageHeaderTitleStyle") -lt $styleOrder.IndexOf("ScannerPageTitleStyle")) {
        throw "The shared page header must be a background-free 12-DIP row of the shared 48-DIP header-control height with the 28-px semibold page title centered, wrapping and without its 8-DIP bottom margin."
    }
    $sharedHeaders = @(
        @{ Path = "Views\OverviewPageView.xaml"; Icon = "overview"; Title = "Overview" },
        @{ Path = "Views\NetworkPageView.xaml"; Icon = "network"; Title = "Network" },
        @{ Path = "Views\DevicesPageView.xaml"; Icon = "devices"; Title = "Devices"; TitleName = "DevicesHeading" },
        @{ Path = "Views\PeopleRoomsPageView.xaml"; Icon = "people-rooms"; Title = "People & rooms"; RowName = "PeopleRoomsHeadingRow" },
        @{ Path = "Views\SettingsPageView.xaml"; Icon = "tools"; Title = "Settings" },
        @{ Path = "Tools\ToolsPage.xaml"; Icon = "tools"; Title = "Tools" },
        @{ Path = "Tools\SqlEditorPage.xaml"; Icon = "tools"; Title = "SQL editor"; Back = "Tools"; Click = "Back_Click" },
        @{ Path = "Tools\FingImportPage.xaml"; Icon = "import"; Title = "Import from Fing"; Back = "Tools"; Click = "Back_Click" },
        @{ Path = "Tools\SpeedTestPage.xaml"; Icon = "speed-test"; Title = "Speed test"; Back = "Tools"; Click = "BackButton_Click" },
        @{ Path = "Views\RoomMapPageView.xaml"; Icon = "rooms"; Title = "Room map"; Back = "Rooms"; Click = "BackToRoomsButton_Click"; RowName = "RoomMapHeadingRow"; BackName = "RoomMapBackButton" },
        @{ Path = "Tools\NetworkHealthPage.xaml"; Icon = "troubleshooting"; Title = "Network health"; Back = "Tools"; Click = "BackButton_Click" },
        @{ Path = "Tools\ServiceStatusPage.xaml"; Icon = "network"; Title = "Service status"; Back = "Network health"; Click = "BackButton_Click" },
        @{ Path = "Tools\DatabaseBackupsPage.xaml"; Icon = "tools"; Title = "Database backups"; Back = "Tools"; Click = "Back_Click"; BackName = "BackupsBackButton" },
        @{ Path = "Tools\AboutPage.xaml"; Icon = "about"; Title = "About FingVibe"; Back = "Settings"; Click = "Back_Click"; BackName = "BackToSettingsButton"; TitleName = "PageHeading" }
    )
    $xamlNamespace = "http://schemas.microsoft.com/winfx/2006/xaml"
    foreach ($entry in $sharedHeaders) {
        $document = [xml](Get-Content (Join-Path $appDirectory $entry.Path) -Raw)
        $rows = @($document.SelectNodes("//*[@Style='{StaticResource PageHeaderRowStyle}']"))
        $header = $rows[0]
        $headerHost = if ($header) { $header.ParentNode }
        $hostRows = if ($headerHost) { @($headerHost.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*")) }
        $children = if ($header) { @($header.SelectNodes("./*[not(contains(local-name(), '.'))]")) }
        $columns = if ($header) { @($header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*")) }
        $hasBack = [bool]$entry.Back
        $expected = if ($hasBack) { @("PageBackButton", "PageHeaderIcon", "TextBlock") } else { @("PageHeaderIcon", "TextBlock") }
        if ($rows.Count -ne 1 -or $header.LocalName -cne "Grid" -or $headerHost.LocalName -cne "Grid" -or
            $header.GetAttribute("Grid.Row") -notin @("", "0") -or $hostRows.Count -lt 2 -or
            $hostRows[0].GetAttribute("Height") -cne "Auto" -or
            $header.SelectSingleNode("ancestor::*[local-name()='ScrollViewer']") -or
            -not $headerHost.SelectSingleNode("./*[@Grid.Row='1']") -or
            @($header.Attributes | Where-Object { $_.LocalName -notin @("Style", "Name") }).Count -ne 0 -or
            ($entry.RowName -and $header.GetAttribute("Name", $xamlNamespace) -cne $entry.RowName) -or
            (($children | ForEach-Object LocalName) -join ",") -cne ($expected -join ",") -or
            $columns.Count -ne $expected.Count -or
            (($columns | ForEach-Object { $_.GetAttribute("Width") }) -join ",") -cne ((@("Auto") * ($expected.Count - 1) + "*") -join ",")) {
            throw "$($entry.Path) must place exactly one shared page header (Back only on tool pages, then icon and title) in its own fixed Auto row above the content, with no local spacing, background or divider."
        }
        $icon = $children[$expected.Count - 2]
        $title = $children[$expected.Count - 1]
        $iconColumns = if ($hasBack) { @("1") } else { @("", "0") }
        if ($icon.GetAttribute("Icon") -cne $entry.Icon -or $icon.GetAttribute("Grid.Column") -notin $iconColumns -or
            @($icon.Attributes | Where-Object { $_.LocalName -notin @("Icon", "Grid.Column") }).Count -ne 0 -or
            $title.GetAttribute("Text") -cne $entry.Title -or $title.GetAttribute("Grid.Column") -cne "$($expected.Count - 1)" -or
            $title.GetAttribute("Style") -cne "{StaticResource PageHeaderTitleStyle}" -or
            @($title.Attributes | Where-Object { $_.LocalName -notin @("Text", "Grid.Column", "Style", "Name", "IsTabStop") }).Count -ne 0 -or
            ($entry.TitleName -and $title.GetAttribute("Name", $xamlNamespace) -cne $entry.TitleName)) {
            throw "$($entry.Path) must show the 48-DIP '$($entry.Icon)' icon then '$($entry.Title)' in the shared title style without local overrides."
        }
        if ($hasBack) {
            $back = $children[0]
            if ($back.GetAttribute("Destination") -cne $entry.Back -or $back.GetAttribute("BackRequested") -cne $entry.Click -or
                $back.HasAttribute("Style") -or $back.HasAttribute("Click") -or $back.HasAttribute("Content") -or
                $back.HasAttribute("AutomationProperties.Name") -or $back.HasChildNodes -or
                $back.GetAttribute("Grid.Column") -notin @("", "0") -or $back.HasAttribute("Margin") -or
                ($entry.BackName -and $back.GetAttribute("Name", $xamlNamespace) -cne $entry.BackName)) {
                throw "$($entry.Path) must keep its Back to $($entry.Back) action, handler and name first in the shared header."
            }
        }
        if (@($document.SelectNodes("//*[@Style='{StaticResource ScannerPageTitleStyle}']")).Count -ne 0) {
            throw "$($entry.Path) must use only the shared page-header title style."
        }
    }
    # #670: Device, Person and Room details use the identity variant of the shared header: Back, the entity's own
    # 48-DIP icon (short-name badge beneath it), 12 DIP, the name in the shared title style and only existing secondary text.
    $identityHeaders = @(
        @{ View = "DeviceDetailsPageView"; Row = "HeaderGrid"; Back = "DeviceBackButton"; Icon = "DeviceTypeIcon"; Title = "DeviceNameValue"
            TitleType = "DeviceDetailValue"; TitleStyle = "PageHeaderSingleLineTitleStyle"; Secondary = "DeviceStatusText"; Columns = "Auto,Auto,*,Auto" },
        @{ View = "PersonDetailsPageView"; Row = "PersonDetailHeading"; Icon = "PersonDetailIcon"; IconType = "PersonIcon"; Title = "PersonDetailName"
            TitleType = "TextBlock"; Badge = "PersonDetailShortName"; Actions = "PersonDetailActions"; Columns = "Auto,48,*,Auto"
            Buttons = @("EditPersonDetailButton=EditPersonButton_Click", "DeletePersonDetailButton=DeletePersonButton_Click") },
        @{ View = "RoomDetailsPageView"; Row = "RoomDetailHeading"; Back = "RoomBackButton"; Icon = "RoomDetailIcon"; Title = "RoomDetailName"
            TitleType = "TextBlock"; Badge = "RoomDetailShortName"; Actions = "RoomDetailActions"; Columns = "Auto,48,*,Auto"
            Buttons = @("EditRoomDetailButton=EditRoomButton_Click", "DeleteRoomDetailButton=DeleteRoomButton_Click") }
    )
    foreach ($entry in $identityHeaders) {
        $document = [xml](Get-Content (Join-Path $appDirectory "Views\$($entry.View).xaml") -Raw)
        $named = { param($Name) , @($document.SelectNodes("//*[@*[local-name()='Name']='$Name']")) }
        $rows = @($document.SelectNodes("//*[@Style='{StaticResource PageHeaderRowStyle}']"))
        $header = $rows[0]
        $pageGrid = $document.DocumentElement.SelectSingleNode("./*[local-name()='Grid']")
        $hostRows = @($pageGrid.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*"))
        $scroll = $pageGrid.SelectSingleNode("./*[local-name()='ScrollViewer']")
        $children = if ($header) { @($header.SelectNodes("./*[not(contains(local-name(), '.'))]")) }
        $columns = if ($header) { @($header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*") | ForEach-Object { $_.GetAttribute("Width") }) }
        if ($rows.Count -ne 1 -or $header.LocalName -cne "Grid" -or $header.ParentNode -ne $pageGrid -or
            $header.GetAttribute("Name", $xamlNamespace) -cne $entry.Row -or $header.GetAttribute("Grid.Row") -notin @("", "0") -or
            $hostRows[0].GetAttribute("Height") -cne "Auto" -or -not $scroll -or [int]$scroll.GetAttribute("Grid.Row") -lt 1 -or
            $header.SelectSingleNode("ancestor::*[local-name()='ScrollViewer'] | .//*[local-name()='ScrollViewer']") -or
            @($header.Attributes | Where-Object { $_.LocalName -notin @("Style", "Name", "SizeChanged") }).Count -ne 0 -or
            ($columns -join ",") -cne $entry.Columns -or
            $header.SelectSingleNode(".//*[local-name()='PageHeaderIcon' or (local-name()='Border' and not(@*[local-name()='Name']='DetailsTabsHost')) or local-name()='Rectangle']")) {
            throw "$($entry.View) must place one identity header in its own fixed Auto row above the scrolling body, with no background, divider or family icon."
        }
        $back = $children[0]
        $icon = $children[1]
        $title = $children[2]
        $iconType = if ($entry.IconType) { $entry.IconType } else { "FontIcon" }
        if ($back.LocalName -cne "PageBackButton" -or $back.HasAttribute("Margin") -or $back.HasAttribute("Grid.Column") -or
            $back.HasAttribute("Grid.Row") -or $back.GetAttribute("Name", $xamlNamespace) -cne "$($entry.Back)" -or
            $icon.LocalName -cne $iconType -or $icon.GetAttribute("Name", $xamlNamespace) -cne $entry.Icon -or
            $icon.GetAttribute("Grid.Column") -cne "1" -or $icon.HasAttribute("Grid.Row") -or $icon.HasAttribute("Margin") -or
            $icon.GetAttribute("Width") -cne "48" -or $icon.GetAttribute("Height") -cne "48" -or $icon.GetAttribute("FontSize") -cne "48" -or
            $icon.GetAttribute("IsTextScaleFactorEnabled") -cne "False" -or
            $title.LocalName -cne $entry.TitleType -or $title.GetAttribute("Name", $xamlNamespace) -cne $entry.Title -or
            $title.GetAttribute("Grid.Column") -cne "2" -or $title.HasAttribute("Grid.Row") -or
            @($title.Attributes | Where-Object { $_.LocalName -in @("FontSize", "ValueFontSize", "FontWeight", "Margin", "TextTrimming") }).Count -ne 0 -or
            ($entry.TitleType -eq "TextBlock" -and $title.GetAttribute("Style") -cne "{StaticResource PageHeaderTitleStyle}") -or
            ($entry.TitleType -ne "TextBlock" -and ($title.GetAttribute("ValueStyle") -cne "{StaticResource $($entry.TitleStyle)}" -or
                $title.GetAttribute("RenameRequested") -cne "Rename_Click" -or $title.GetAttribute("VerticalAlignment") -cne "Center"))) {
            throw "$($entry.View) must order Back (shared 16-DIP gap), its own 48-DIP entity icon and the name in the shared title style without hand-set sizes."
        }
        foreach ($name in @($entry.Icon, $entry.Title, $entry.Badge, $entry.Secondary) | Where-Object { $_ }) {
            if ((& $named $name).Count -ne 1 -or -not $header.SelectSingleNode(".//*[@*[local-name()='Name']='$name']")) {
                throw "$($entry.View) must keep exactly one $name, inside its identity header."
            }
        }
        if ($entry.Secondary) {
            $secondary = (& $named $entry.Secondary)[0]
            if ($secondary.ParentNode -ne $header -or $secondary.GetAttribute("Grid.Row") -cne "1" -or
                $secondary.GetAttribute("Grid.Column") -cne "2" -or $secondary.GetAttribute("TextWrapping") -cne "Wrap" -or
                $secondary.GetAttribute("Foreground") -cne "{ThemeResource TextFillColorSecondaryBrush}") {
                throw "$($entry.View) must show its existing $($entry.Secondary) as a wrapping secondary line under the title."
            }
        }
        if ($entry.Badge) {
            $badge = (& $named $entry.Badge)[0]
            if ($badge.ParentNode -ne $header -or $badge.LocalName -cne "TextBlock" -or $badge.GetAttribute("Grid.Row") -cne "1" -or
                $badge.GetAttribute("Grid.Column") -cne "1" -or $badge.GetAttribute("FontSize") -cne "18" -or
                $badge.GetAttribute("FontWeight") -cne "SemiBold" -or $badge.GetAttribute("MinWidth") -cne "48" -or
                $badge.GetAttribute("TextAlignment") -cne "Center" -or $badge.GetAttribute("HorizontalAlignment") -cne "Left") {
                throw "$($entry.View) must keep its short-name badge centered beneath the 48-DIP icon without widening the icon slot."
            }
        }
        if ($entry.Actions) {
            $actions = (& $named $entry.Actions)[0]
            $buttons = @($actions.SelectNodes("./*[local-name()='Button']") | ForEach-Object {
                "$($_.GetAttribute('Name', $xamlNamespace))=$($_.GetAttribute('Click'))" })
            $viewCode = Get-Content (Join-Path $appDirectory "Views\$($entry.View).xaml.cs") -Raw
            if ($actions.ParentNode -ne $header -or $actions.GetAttribute("Grid.Column") -cne "3" -or
                ($buttons -join "|") -cne ($entry.Buttons -join "|") -or
                $viewCode -notmatch "Grid\.SetRow\($($entry.Actions), inline \? 0 : 2\)" -or
                $viewCode -notmatch "Grid\.SetColumn\($($entry.Actions), inline \? 3 : 2\)") {
                throw "$($entry.View) must keep Edit and Delete after the title, wrapping them beneath it only when the title would be squeezed."
            }
        }
    }
    # #659: the shared D3 quiet segmented tabs end the Device Details header row (wrapping beneath it only when the
    # single-line name would be squeezed), with one App-level look and no local SelectorBarItem overrides.
    $deviceXaml = Get-Content (Join-Path $appDirectory "Views\DeviceDetailsPageView.xaml") -Raw
    $deviceDocument = [xml]$deviceXaml
    $deviceCode = Get-Content (Join-Path $appDirectory "Views\DeviceDetailsPageView.xaml.cs") -Raw
    $tabsHost = $deviceDocument.SelectSingleNode("//*[@*[local-name()='Name']='DetailsTabsHost']")
    $deviceHeader = $deviceDocument.SelectSingleNode("//*[@*[local-name()='Name']='HeaderGrid']")
    $tabItems = @($tabsHost.SelectNodes("./*[local-name()='SelectorBar']/*[local-name()='SelectorBarItem']"))
    if ($tabsHost.ParentNode -ne $deviceHeader -or $tabsHost.GetAttribute("Grid.Column") -cne "3" -or
        $tabsHost.HasAttribute("Grid.Row") -or $tabsHost.HasAttribute("Margin") -or
        $tabsHost.GetAttribute("Style") -cne "{StaticResource PageHeaderTabTrackStyle}" -or
        @($tabsHost.Attributes | Where-Object { $_.LocalName -notin @("Name", "Grid.Column", "Style") }).Count -ne 0 -or
        $tabsHost.SelectSingleNode("following-sibling::*") -or
        $deviceHeader.GetAttribute("SizeChanged") -cne "HeaderGrid_SizeChanged" -or
        (@($deviceHeader.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*")).Count) -ne 3 -or
        (@($deviceHeader.ParentNode.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*") | ForEach-Object { $_.GetAttribute("Height") }) -join ",") -cne "Auto,*" -or
        $deviceHeader.ParentNode.GetAttribute("RowSpacing") -cne "16" -or
        $deviceHeader.SelectSingleNode("following-sibling::*[1]").LocalName -cne "ScrollViewer" -or
        $deviceHeader.SelectSingleNode("following-sibling::*[1]").GetAttribute("Grid.Row") -cne "1" -or
        -not $tabsHost.SelectSingleNode("./*[local-name()='SelectorBar' and @*[local-name()='Name']='DetailsTabs' and @Style='{StaticResource PageHeaderTabsStyle}']") -or
        $tabItems.Count -ne 2 -or @($tabItems | Where-Object {
            $_.GetAttribute("Style") -cne "{StaticResource PageHeaderTabItemStyle}" -or $_.HasAttribute("Padding") -or
            $_.HasAttribute("CornerRadius") -or $_.HasAttribute("Background") }).Count -ne 0 -or
        $deviceXaml -match 'SelectorBarItem(Background|Foreground)|DetailsSectionSelection|UserControl\.Resources' -or
        $deviceCode -match 'OverviewSelected|HistorySelected' -or
        $deviceCode -notmatch 'Grid\.SetRow\(DetailsTabsHost, inline \? 0 : 2\)' -or
        $deviceCode -notmatch 'Grid\.SetColumn\(DetailsTabsHost, inline \? 3 : 0\)' -or
        $deviceCode -notmatch 'Grid\.SetColumnSpan\(DetailsTabsHost, inline \? 1 : 4\)' -or
        $deviceCode -notmatch 'title >= 160 \* new Windows\.UI\.ViewManagement\.UISettings\(\)\.TextScaleFactor') {
        throw "Device Details tabs must use the shared quiet page-tab style at the right end of the identity header, wrapping left-aligned beneath it only when the name would keep less than 160 DIP, with the body 16 DIP below."
    }
    $tabStyles = @{}
    foreach ($key in @("PageHeaderSingleLineTitleStyle", "PageHeaderTabTrackStyle", "PageHeaderTabsStyle", "PageHeaderTabItemStyle")) {
        $tabStyles[$key] = $appResources.SelectSingleNode("/*/*/*[local-name()='ResourceDictionary']/*[local-name()='Style' and @*[local-name()='Key']='$key']")
        if (-not $tabStyles[$key]) { throw "App resources must define $key." }
    }
    $itemTemplate = $tabStyles.PageHeaderTabItemStyle.SelectSingleNode(".//*[local-name()='ControlTemplate']")
    $itemStates = @($itemTemplate.SelectNodes(".//*[local-name()='VisualStateGroup' and @*[local-name()='Name']='CombinedStates']/*[local-name()='VisualState']") |
        ForEach-Object { $_.GetAttribute("Name", $xamlNamespace) })
    $selectedSetters = { param($State)
        @($itemTemplate.SelectNodes(".//*[local-name()='VisualState' and @*[local-name()='Name']='$State']//*[local-name()='Setter']") |
            ForEach-Object { "$($_.GetAttribute('Target'))=$($_.GetAttribute('Value'))" }) }
    $pill = $itemTemplate.SelectSingleNode(".//*[local-name()='Rectangle' and @*[local-name()='Name']='PART_SelectionVisual']")
    if ((& $headerSetters $tabStyles.PageHeaderSingleLineTitleStyle) -cne "TextWrapping=NoWrap;TextTrimming=CharacterEllipsis" -or
        $tabStyles.PageHeaderSingleLineTitleStyle.GetAttribute("BasedOn") -cne "{StaticResource PageHeaderTitleStyle}" -or
        (& $headerSetters $tabStyles.PageHeaderTabTrackStyle) -cne "MinHeight={StaticResource PageHeaderControlHeight};Padding=4;CornerRadius=8;BorderThickness=1;Background={ThemeResource PageHeaderTabTrackBackgroundBrush};BorderBrush={ThemeResource PageHeaderTabTrackBorderBrush};HorizontalAlignment=Left;VerticalAlignment=Center" -or
        (& $headerSetters $tabStyles.PageHeaderTabsStyle) -cne "Padding=0;VerticalAlignment=Stretch" -or
        (& $headerSetters $tabStyles.PageHeaderTabItemStyle) -notmatch '(^|;)MinHeight=38;CornerRadius=6;' -or
        ($itemStates -join ",") -cne "UnselectedNormal,UnselectedPointerOver,UnselectedPressed,SelectedNormal,SelectedPointerOver,SelectedPressed" -or
        @("SelectedNormal", "SelectedPointerOver", "SelectedPressed" | Where-Object {
            $setters = & $selectedSetters $_
            $setters -notcontains "PART_TextVisual.FontWeight=SemiBold" -or $setters -notcontains "PART_SelectionVisual.Opacity=1" -or
            $setters -notcontains "Surface.BorderBrush={ThemeResource PageHeaderTabSelectedBorderBrush}" }).Count -ne 0 -or
        -not $pill -or $pill.GetAttribute("Width") -cne "16" -or $pill.GetAttribute("Height") -cne "3" -or
        -not $itemTemplate.SelectSingleNode(".//*[local-name()='TextBlock' and @FontWeight='SemiBold' and @Opacity='0']") -or
        -not $itemTemplate.SelectSingleNode(".//*[local-name()='TextBlock' and @*[local-name()='Name']='PART_TextVisual']") -or
        -not $itemTemplate.SelectSingleNode("./*[local-name()='Grid' and @*[local-name()='Name']='PART_ContainerRoot']")) {
        throw "The shared page tabs must be a 48-DIP neutral track of 38-DIP items whose selected state is a raised surface, semibold text and a 16x3 pill (never colour alone) at a fixed width."
    }
    $tabBrushes = @("PageHeaderTabTrackBackgroundBrush", "PageHeaderTabTrackBorderBrush", "PageHeaderTabForegroundBrush",
        "PageHeaderTabForegroundPointerOverBrush", "PageHeaderTabForegroundPressedBrush", "PageHeaderTabBackgroundPointerOverBrush",
        "PageHeaderTabBackgroundPressedBrush", "PageHeaderTabBorderPointerOverBrush", "PageHeaderTabSelectedBackgroundBrush",
        "PageHeaderTabSelectedBackgroundPointerOverBrush", "PageHeaderTabSelectedBackgroundPressedBrush",
        "PageHeaderTabSelectedForegroundBrush", "PageHeaderTabPillBrush", "PageHeaderTabSelectedBorderBrush")
    foreach ($theme in @("Light", "Dark", "HighContrast")) {
        $dictionary = $appResources.SelectSingleNode("//*[local-name()='ResourceDictionary.ThemeDictionaries']/*[@*[local-name()='Key']='$theme']")
        foreach ($brush in $tabBrushes) {
            $node = $dictionary.SelectSingleNode("./*[@*[local-name()='Key']='$brush']")
            if (-not $node -or ($theme -eq "HighContrast" -and $node.GetAttribute("Color") -notmatch '^\{ThemeResource SystemColor\w+Color\}$')) {
                throw "The $theme theme must define $brush$(if ($theme -eq 'HighContrast') { ' from system colours' })."
            }
        }
    }
    $valueCode = Get-Content (Join-Path $appDirectory "Views\DeviceDetailValue.cs") -Raw
    if ($valueCode -notmatch 'DependencyProperty ValueStyleProperty' -or
        $valueCode -notmatch '(?s)ValueStyleChanged.*?_value\.ClearValue\(TextBlock\.TextWrappingProperty\);\s*detail\._value\.ClearValue\(TextBlock\.FontSizeProperty\);\s*detail\._value\.Style =' -or
        $valueCode -match 'ValueFontSize') {
        throw "The Device Details name must take the shared page-title style, including its wrapping, rather than a hand-set font size or wrap."
    }
    # #658: one quiet reusable Back control on every tool and detail page; pages own navigation, guards and cleanup.
    $backControlStyle = @($appResources.SelectNodes("/*/*/*[local-name()='ResourceDictionary']/*[local-name()='Style' and @TargetType='local:PageBackButton']"))
    $controlHeight = @($appResources.SelectNodes("/*/*/*[local-name()='ResourceDictionary']/*[@*[local-name()='Key']='PageHeaderControlHeight']"))
    $appResourceKeys = @($appResources.SelectNodes("/*/*/*[local-name()='ResourceDictionary']/*/@*[local-name()='Key' or local-name()='TargetType']") | ForEach-Object Value)
    if ($controlHeight.Count -ne 1 -or $controlHeight[0].LocalName -cne "Double" -or $controlHeight[0].InnerText -cne "48" -or
        $appResourceKeys.IndexOf("PageHeaderControlHeight") -gt $appResourceKeys.IndexOf("PageHeaderRowStyle") -or
        $backControlStyle.Count -ne 1 -or $backControlStyle[0].HasAttribute("x:Key") -or
        $backControlStyle[0].GetAttribute("BasedOn") -cne "{StaticResource SubtleButtonStyle}" -or
        (& $headerSetters $backControlStyle[0]) -cne "MinHeight={StaticResource PageHeaderControlHeight};Padding=12,8;Margin=0,0,4,0;VerticalContentAlignment=Center" -or
        $appResourceKeys.IndexOf("PageHeaderControlHeight") -gt $appResourceKeys.IndexOf("local:PageBackButton")) {
        throw "The shared Back must be one implicit SubtleButtonStyle-based style (transparent and borderless at rest, subtle hover/pressed fill, system colours in high contrast) with the shared 48-DIP PageHeaderControlHeight minimum and the 4-DIP header gap margin, without a local look."
    }
    $backControlCode = Get-Content (Join-Path $appDirectory "PageBackButton.cs") -Raw
    foreach ($pattern in @('class PageBackButton : Button\b', 'DependencyProperty DestinationProperty', 'DependencyProperty AccessibleDestinationProperty',
        'event RoutedEventHandler\? BackRequested', 'Click \+= \(_, args\) => BackRequested\?\.Invoke\(this, args\)', 'Glyph = "\\uE72B"',
        '\$"Back to \{', 'AutomationProperties\.SetName\(this, name\)', '_toolTip\.Content = name', 'ToolTipService\.SetToolTip\(this, _toolTip\)',
        'SetAccessibilityView\(_toolTip, AccessibilityView\.Raw\)', 'SetAccessibilityView\(_destinationText, AccessibilityView\.Raw\)')) {
        if ($backControlCode -notmatch $pattern) {
            throw "PageBackButton must stay a native Button that shows its destination and derives its name and tooltip 'Back to {destination}' ($pattern)."
        }
    }
    $backPages = @(
        @{ Path = "Tools\AboutPage.xaml"; Destination = "Settings"; Handler = "Back_Click"; Name = "BackToSettingsButton" },
        @{ Path = "Tools\DatabaseBackupsPage.xaml"; Destination = "Tools"; Handler = "Back_Click"; Name = "BackupsBackButton" },
        @{ Path = "Tools\FingImportPage.xaml"; Destination = "Tools"; Handler = "Back_Click" },
        @{ Path = "Tools\NetworkHealthPage.xaml"; Destination = "Tools"; Handler = "BackButton_Click" },
        @{ Path = "Tools\ServiceStatusPage.xaml"; Destination = "Network health"; Handler = "BackButton_Click" },
        @{ Path = "Tools\SpeedTestPage.xaml"; Destination = "Tools"; Handler = "BackButton_Click" },
        @{ Path = "Tools\SqlEditorPage.xaml"; Destination = "Tools"; Handler = "Back_Click" },
        @{ Path = "Views\RoomMapPageView.xaml"; Destination = "Rooms"; Handler = "BackToRoomsButton_Click"; Name = "RoomMapBackButton"; AutomationId = "RoomMapBackButton" },
        @{ Path = "Views\DeviceDetailsPageView.xaml"; Destination = "Devices"; Spoken = "devices"; Handler = "BackToDevicesButton_Click"; Name = "DeviceBackButton"; AutomationId = "DeviceBackButton" },
        @{ Path = "Views\PersonDetailsPageView.xaml"; Destination = "People & rooms"; Spoken = "people and rooms"; Handler = "BackToPeopleButton_Click" },
        @{ Path = "Views\RoomDetailsPageView.xaml"; Destination = "People & rooms"; Spoken = "people and rooms"; Handler = "BackToRoomsButton_Click"; Name = "RoomBackButton"; AutomationId = "RoomBackButton" }
    )
    foreach ($entry in $backPages) {
        $pageXaml = Get-Content (Join-Path $appDirectory $entry.Path) -Raw
        $document = [xml]$pageXaml
        $backs = @($document.SelectNodes("//*[local-name()='PageBackButton']"))
        $back = $backs[0]
        $allowed = @("Destination", "AccessibleDestination", "BackRequested", "Name", "AutomationProperties.AutomationId", "Margin", "Grid.Column")
        if ($backs.Count -ne 1 -or $back.NamespaceURI -notin @("using:FingVibe.App") -or
            $back.GetAttribute("Destination") -cne $entry.Destination -or
            $back.GetAttribute("AccessibleDestination") -cne "$($entry.Spoken)" -or
            $back.GetAttribute("BackRequested") -cne $entry.Handler -or
            $back.GetAttribute("Name", $xamlNamespace) -cne "$($entry.Name)" -or
            $back.GetAttribute("AutomationProperties.AutomationId") -cne "$($entry.AutomationId)" -or
            $back.GetAttribute("Margin") -cne "$($entry.Margin)" -or $back.HasChildNodes -or
            @($back.Attributes | Where-Object { $_.LocalName -notin $allowed -and $_.Name -notlike "xmlns*" }).Count -ne 0 -or
            @($document.SelectNodes("//*[local-name()='Button' and starts-with(@AutomationProperties.Name, 'Back to ')]")).Count -ne 0 -or
            $pageXaml -match '&#x2190;|\u2190|&#xE72B;|PageBackButtonStyle|PageHeaderBackButtonStyle|PageHeaderSizing') {
            throw "$($entry.Path) must use exactly one shared Back control to '$($entry.Destination)' with its existing handler, name and automation ID, and no hand-built arrow, style or sizing."
        }
    }
    $backUses = @(Get-ChildItem $appDirectory -Recurse -Include *.xaml, *.cs | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Select-String -Pattern '<(local|app):PageBackButton\b' -AllMatches | ForEach-Object { $_.Matches })
    $retiredBack = @(Get-ChildItem $appDirectory -Recurse -Include *.xaml, *.cs | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Select-String -Pattern 'PageBackButtonStyle|PageHeaderBackButtonStyle|PageHeaderSizing|ReferenceHeight')
    if ($backUses.Count -ne $backPages.Count -or $retiredBack.Count -ne 0 -or
        (Test-Path -LiteralPath (Join-Path $appDirectory "PageHeaderSizing.cs"))) {
        throw "Only the $($backPages.Count) tool and detail pages may use the shared Back control (found $($backUses.Count)), and the retired Back styles and reference sizing must stay removed."
    }
    foreach ($runtime in @(
        @{ Path = "Views\DeviceDetailsPageView.xaml.cs"; Button = "DeviceBackButton"; Pattern = 'DeviceBackButton\.Destination = roomMap \? "Room map" : "Devices"' },
        @{ Path = "Views\RoomDetailsPageView.xaml.cs"; Button = "RoomBackButton"; Pattern = 'RoomBackButton\.Destination = roomMap \? "Room map" : "People & rooms"' },
        @{ Path = "Views\RoomMapPageView.xaml.cs"; Button = "RoomMapBackButton"; Pattern = '(?s)RoomMapBackButton\.Destination = origin switch.*RoomMapOrigin\.Tools => "Tools".*RoomMapOrigin\.NetworkHealth => "Network health".*_ => "Rooms"' }
    )) {
        $runtimeCode = Get-Content (Join-Path $appDirectory $runtime.Path) -Raw
        if ($runtimeCode -notmatch $runtime.Pattern -or
            $runtimeCode -match "(SetName|SetToolTip)\(\s*$($runtime.Button)\b|$($runtime.Button)\.Content\s*=") {
            throw "$($runtime.Path) must route its runtime Back destination through the shared control so text, name and tooltip change together."
        }
    }
    $sqlCode = Get-Content (Join-Path $appDirectory "Tools\SqlEditorPage.xaml.cs") -Raw
    $importCode = Get-Content (Join-Path $appDirectory "Tools\FingImportPage.xaml.cs") -Raw
    if ($sqlCode -notmatch '(?s)async void Back_Click\(object sender, RoutedEventArgs e\)\s*\{\s*await StopAsync\(\);\s*BackRequested\?\.Invoke' -or
        $importCode -notmatch '(?s)void Back_Click\(object sender, RoutedEventArgs e\)\s*\{\s*if \(!_busy\) BackRequested\?\.Invoke') {
        throw "Pages must keep their own leave guards and tool cleanup in their Back handlers."
    }
    $headerUses = @(Get-ChildItem $appDirectory -Recurse -Filter *.xaml | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Select-String -Pattern 'PageHeaderRowStyle\}' -AllMatches | ForEach-Object { $_.Matches })
    if ($headerUses.Count -ne $sharedHeaders.Count + $identityHeaders.Count) {
        throw "Only the $($sharedHeaders.Count) covered main and tool pages and the $($identityHeaders.Count) identity detail headers may use the shared page header; found $($headerUses.Count)."
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
            # Native AppWindow properties are not references to page child controls.
            $childReferencePattern = "(?<!\bAppWindow\.)\b$([regex]::Escape($childName))\b"
            if ($childName -ne $page -and $shellCode -cmatch $childReferencePattern) {
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
