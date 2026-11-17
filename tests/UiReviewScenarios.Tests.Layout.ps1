# Page contracts: shell, Tools and extracted page view layout.
    $pageViews = @{
        OverviewPage = "OverviewPageView"
        NetworkPage = "NetworkPageView"
        DevicesPage = "DevicesPageView"
        DevicePage = "DeviceDetailsPageView"
        PeoplePage = "PeoplePageView"
        RoomsPage = "RoomsPageView"
        PersonDetailPage = "PersonDetailsPageView"
        RoomDetailPage = "RoomDetailsPageView"
        SettingsPage = "SettingsPageView"
    }
    $appDirectory = Join-Path $PSScriptRoot "..\src\FingVibe.App"
    $shellDocument = [xml](Get-Content (Join-Path $appDirectory "MainWindow.xaml") -Raw)
    $rootGrid = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='RootGrid']")
    $ribbonArea = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='BuildRibbonArea']")
    $navigation = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='MainNavigation']")
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
        @("SqlEditorCard", "FingImportCard", "SpeedTestCard", "TroubleshootingCard", "DatabaseBackupsCard") `
        "Tools visual and keyboard row order"
    foreach ($card in $cards) {
        if ($card.GetAttribute("Grid.ColumnSpan") -notin @("", "1") -or
            @($card.SelectNodes(".//*[local-name()='TextBlock']") |
                Where-Object { $_.GetAttribute("TextWrapping") -cne "Wrap" }).Count -ne 0) {
            throw "Tools cards must keep one column each and wrap all labels, including open actions."
        }
    }
    $toolIcons = @(
        @{ Page = "SpeedTestPage"; Title = "Speed test"; Card = "SpeedTestCard"; Click = "SpeedTestCard_Click"; Glyph = 0xEC4A },
        @{ Page = "NetworkTroubleshootingPage"; Title = "Network troubleshooting"; Card = "TroubleshootingCard"; Click = "TroubleshootingCard_Click"; Glyph = 0xE90F },
        @{ Page = "AboutPage"; Title = "About FingVibe"; Card = "AboutCard"; Click = "AboutCard_Click"; Glyph = 0xE946 },
        @{ Page = "FingImportPage"; Title = "Import from Fing"; Card = "FingImportCard"; Click = "FingImportCard_Click"; Glyph = 0xE8B5 },
        @{ Page = "SqlEditorPage"; Title = "SQL editor"; Card = "SqlEditorCard"; Click = "SqlEditorCard_Click"; Glyph = 0xE943 },
        @{ Page = "DatabaseBackupsPage"; Title = "Database backups"; Card = "DatabaseBackupsCard"; Click = "DatabaseBackupsCard_Click"; Glyph = 0xE74E }
    )
    foreach ($tool in $toolIcons) {
        $pageDocument = [System.Xml.XmlDocument]::new()
        $pageDocument.Load((Join-Path $appDirectory "Tools\$($tool.Page).xaml"))
        if ($tool.Page -eq "NetworkTroubleshootingPage") {
            $run = $pageDocument.SelectSingleNode("//*[@*[local-name()='Name']='RunButton']")
            if ($run.GetAttribute("Style") -cne "{ThemeResource AccentButtonStyle}") {
                throw "Run checks must use the existing primary-action accent style."
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
                    $header.SelectSingleNode("./*[local-name()='Button' or local-name()='FontIcon' or local-name()='TextBlock']") -ne $back -or
                    $back.GetAttribute("Content") -cne "$([char]0x2190) $destination" -or
                    $pageDocument.SelectNodes("//*[local-name()='Button' and @AutomationProperties.Name='Back to $destination']").Count -ne 1 -or
                    $back.GetAttribute("Style") -cne "{StaticResource PageBackButtonStyle}" -or
                    $back.HasAttribute("Width") -or $back.HasAttribute("Height")) {
                    throw "$($tool.Title) must have one content-safe neutral Back action first in its title row."
                }
            }
            $icons = $header.SelectNodes("./*[local-name()='FontIcon']")
            if ($icons.Count -ne 1) { throw "$($tool.Title) must have exactly one decorative header icon." }
            $icon = $icons[0]
            if ($isPageTitle -and $icon.GetAttribute("Grid.Column") -cne "1") {
                throw "$($tool.Title) must keep its decorative icon with the heading after Back."
            }
            foreach ($attribute in @{
                Glyph = [string][char]$tool.Glyph
                FontFamily = "Segoe Fluent Icons"
                FontSize = "48"
                Width = "48"
                Height = "48"
                Foreground = "{ThemeResource TextFillColorPrimaryBrush}"
                IsHitTestVisible = "False"
                "AutomationProperties.AccessibilityView" = "Raw"
            }.GetEnumerator()) {
                if ($icon.GetAttribute($attribute.Key) -cne $attribute.Value) {
                    throw "$($tool.Title) icon must use $($attribute.Key)=$($attribute.Value) on both surfaces."
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
        if ($overview.ParentNode -ne $assignments.ParentNode -or
            $assignments.GetAttribute("Grid.Column") -ne "1" -or
            $identification.ParentNode -ne $overview.ParentNode.ParentNode -or
            $identification.NextSibling -ne $ports) {
            throw "Details must put network/assignments in the top row, then full-width identification and ports."
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
