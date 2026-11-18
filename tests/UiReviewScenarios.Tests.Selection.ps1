# Scenario selection: fixture repository and path-based capture selection.
    $null = Invoke-UiReviewGit $repository @("init", "--quiet")
    $null = Invoke-UiReviewGit $repository @("config", "user.name", "Scenario tests")
    $null = Invoke-UiReviewGit $repository @("config", "user.email", "scenario-tests@example.invalid")
    $null = Invoke-UiReviewGit $repository @("config", "commit.gpgsign", "false")
    $xamlPath = Join-Path $repository "src\FingVibe.App\MainWindow.xaml"
    $null = New-Item -ItemType Directory -Path (Split-Path $xamlPath) -Force
    $xaml = '<Window xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid x:Name="RootGrid">'
    foreach ($page in ($UiReviewScenarios.Values.Page | Select-Object -Unique)) {
        $xaml += "<Grid x:Name=`"$page`"><TextBlock Text=`"$page`" /></Grid>"
    }
    $xaml += '</Grid></Window>'
    Set-Content -LiteralPath $xamlPath -Value $xaml
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Baseline")
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")

    function Test-Change([hashtable] $Files, [string[]] $Expected, [string] $Message) {
        $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
        foreach ($path in $Files.Keys) {
            $target = Join-Path $repository $path
            $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
            Set-Content -LiteralPath $target -Value $Files[$path]
        }
        $null = Invoke-UiReviewGit $repository @("add", ".")
        $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", $Message)
        $plan = @(Get-UiReviewCapturePlan -RepositoryPath $repository -BaseRevision $base)
        Assert-Equal $plan.Scenario $Expected $Message
        foreach ($capture in $plan) {
            if ($capture.Reasons.Count -eq 0) { throw "Every capture must explain why it was selected." }
        }
    }

    Assert-Equal @(Get-UiReviewCapturePlan $repository).Scenario @("Devices") "Manual default"
    Assert-Equal @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network", "Network")).Scenario `
        @("Devices", "Network") "Explicit scenarios must be deduplicated"
    Assert-Throws { Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Typo") } "*Unknown UI capture scenario*"
    Assert-Throws { Get-UiReviewCapturePlan $repository -BaseRevision "missing-ref" } "*failed with exit code*"

    Test-Change @{ "README.md" = "Documentation" } @("Devices") "Documentation-only"
    foreach ($scenario in @("Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails", "RoomMap", "Tools", "SpeedTest", "Settings", "Devices")) {
        $page = $UiReviewScenarios[$scenario].Page
        $changed = $xaml.Replace("Text=`"$page`"", "Text=`"Changed $page`"")
        $expected = @("Devices")
        foreach ($pageScenario in $UiReviewScenarios.Keys) {
            if ($UiReviewScenarios[$pageScenario].Page -eq $page -and $pageScenario -ne "Devices") {
                $expected += $pageScenario
            }
        }
        Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $changed } $expected "Page-local $scenario"
    }
    $changed = $xaml.Replace('Text="OverviewPage"', 'Text="New overview"').Replace('Text="NetworkPage"', 'Text="New network"')
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $changed } @("Devices", "Overview", "Network") "Multiple pages"
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $xaml.Replace('</Window>', '<Grid x:Name="NewPage" /></Window>') } `
            @() "Unsupported new page"
    } "*NewPage*has no capture scenario*"
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $xaml.Replace('<Window ', '<Window Title="Shared" ') } `
        @($UiReviewScenarios.Keys) "Shared layout"
    $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
    Set-Content -LiteralPath $xamlPath -Value $xaml.Replace('</Grid></Window>', '<Grid x:Name="RetiredPage" /></Grid></Window>')
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Retired page")
    $originalBase = $base
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $xaml } @($UiReviewScenarios.Keys) "Removed page"
    $base = $originalBase
    $navigation = '<NavigationView><NavigationView.MenuItems><NavigationViewItem Content="Tools" /></NavigationView.MenuItems></NavigationView>'
    $navigationXaml = $xaml.Replace('<Grid x:Name="RootGrid">', "<Grid x:Name=`"RootGrid`">$navigation")
    # The existing navigation container is part of the shell; only its menu entries are excluded.
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $navigationXaml } `
        @($UiReviewScenarios.Keys) "New shared navigation container"
    $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
    $navigationBase = $xaml.Replace('<Grid x:Name="RootGrid">', '<Grid x:Name="RootGrid"><NavigationView />')
    Set-Content -LiteralPath $xamlPath -Value $navigationBase
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Existing navigation")
    $originalBase = $base
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $navigationXaml } @("Devices") "Menu-only change"
    $base = $originalBase
    Test-Change @{ "src\FingVibe.App\MainWindow.DeviceDetails.cs" = "changed" } `
        @("Devices", "DeviceDetails", "DeviceHistory") "Device details code"
    foreach ($path in @("src\FingVibe.App\PageHeaderSizing.cs", "tests\PageHeaders.Ui.Helpers.ps1")) {
        Test-Change @{ $path = "changed" } `
            @("Devices", "DeviceDetails", "DeviceHistory", "SpeedTest", "Troubleshooting", "About",
                "FingImport", "SqlEditor", "DatabaseBackups", "Settings") "Back header owners"
    }
    foreach ($path in @("src\FingVibe.App\DeviceDetailsPresentation.cs", "src\FingVibe.App\Views\DeviceDetailValue.cs",
        "src\FingVibe.App\Views\DeviceScanHistoryItem.cs")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "DeviceHistory") "Device details presentation"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.UsageCategories.cs", "src\FingVibe.App\UsageCategoryPresentation.cs",
        "src\FingVibe.App\Views\DeviceDetailsPageView.Usage.cs", "src\FingVibe.Core\Models\DeviceUsageCategory.cs",
        "tests\UsageCategory.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "Settings") "Usage categories"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.DeviceActivity.cs",
        "src\FingVibe.App\Views\DeviceDetailsPageView.Activity.cs",
        "tests\DeviceActivity.Ui.Tests.ps1", "tests\DeviceActivity.Fixture.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceHistory") "Device activity"
    }
    foreach ($path in @("src\FingVibe.App\DeviceActivityPresentation.cs", "src\FingVibe.App\DeviceActivityReviewHold.cs",
        "src\FingVibe.App\Views\ActivityGridRenderer.cs", "src\FingVibe.Core\Models\DeviceActivity.cs",
        "tests\ActivityGrid.Ui.Helpers.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network", "DeviceHistory", "PersonDetails") "Shared activity grid"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.NetworkActivity.cs",
        "src\FingVibe.App\Views\NetworkPageView.Activity.cs", "tests\NetworkActivity.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network") "Network activity"
    }
    foreach ($path in @("src\FingVibe.App\NetworkActivityPresentation.cs", "src\FingVibe.Core\Models\NetworkActivity.cs",
        "tests\NetworkActivity.Fixture.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network", "PersonDetails") "Shared count grids"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.EquipmentActivity.cs", "src\FingVibe.App\EquipmentActivityPresentation.cs",
        "src\FingVibe.App\Views\PersonDetailsPageView.Activity.cs", "src\FingVibe.Core\Models\EquipmentActivity.cs",
        "tests\EquipmentActivity.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "PersonDetails") "Equipment activity"
    }
    $asyncSurfaceScenarios = @("Devices", "Network", "DeviceDetails", "DeviceHistory", "PersonDetails", "Tools", "Troubleshooting", "DatabaseBackups")
    $rowScenarios = @("Devices", "Overview", "Network", "DeviceDetails", "DeviceHistory", "People", "PersonDetails", "Rooms", "RoomMap", "RoomDetails", "Settings", "DevicesEmpty")
    $analyticsScenarios = @("Devices", "Network", "DeviceDetails", "DeviceHistory", "PersonDetails", "Settings")
    Test-Change @{ "src\FingVibe.App\AsyncSurfaceSession.cs" = "changed" } $asyncSurfaceScenarios "Shared asynchronous surface consumers"
    Test-Change @{ "src\FingVibe.App\ScanResultRow.cs" = "changed" } $rowScenarios "Shared device row consumers"
    Test-Change @{ "src\FingVibe.Core\Storage\DeviceInventoryStore.Analytics.cs" = "changed" } $analyticsScenarios "Shared analytics evidence consumers"
    Test-Change @{ "src\FingVibe.App\AsyncSurfaceSession.cs" = "changed"; "src\FingVibe.Core\Storage\DeviceInventoryStore.Analytics.cs" = "changed"
        "src\FingVibe.App\Tools\SqlEditorPage.xaml" = "changed" } `
        @("Devices", "Network", "DeviceDetails", "DeviceHistory", "PersonDetails", "Tools", "Troubleshooting", "SqlEditor", "DatabaseBackups", "Settings") `
        "Shared contracts union with each other and with page-specific coverage"
    Test-Change @{ "src\FingVibe.App\AsyncSurfaceSession.cs" = "changed"; "src\FingVibe.App\ScanResultRow.cs" = "changed"
        "src\FingVibe.Core\Storage\DeviceInventoryStore.Analytics.cs" = "changed"; "src\FingVibe.App\Tools\AboutPage.xaml" = "changed" } `
        @("Devices", "Overview", "Network", "DeviceDetails", "DeviceHistory", "People", "PersonDetails", "Rooms", "RoomMap", "Tools",
            "Troubleshooting", "About", "DatabaseBackups", "RoomDetails", "Settings", "DevicesEmpty") `
        "All shared contracts keep catalog order and unrelated explicit page coverage"
    foreach ($path in @("src\FingVibe.Core\Models\DeviceInventory.cs", "src\FingVibe.Core\Models\PrivateVirtualDevice.cs",
        "src\FingVibe.Core\Models\DeviceHistorySummary.cs",
        "src\FingVibe.Core\Models\DeviceDiscovery.cs", "src\FingVibe.App\MainWindow.DiscoveryNotifications.cs",
        "src\FingVibe.App\DiscoveryPopup.xaml", "src\FingVibe.App\DiscoveryPopup.xaml.cs",
        "src\FingVibe.App\DiscoveryNotificationPresentation.cs", "src\FingVibe.App\DiscoveryNotificationStore.cs",
        "src\FingVibe.App\WindowsDiscoveryNotifications.cs", "src\FingVibe.App\Assets\DiscoveryCaution.png",
        "src\FingVibe.App\MainWindow.Scan.cs", "tests\DeviceDiscovery.Ui.Tests.ps1",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.cs", "src\FingVibe.App\MainWindow.Snapshots.cs",
        "tests\DeviceScanHistory.Ui.Tests.ps1", "tests\DeviceScanHistory.Ui.Tests.Shared.ps1",
        "tests\DeviceScanHistory.Ui.Tests.Summary.ps1", "tests\DeviceScanHistory.Ui.Tests.Observations.ps1",
        "tests\DeviceScanHistory.Ui.Tests.FixturePhase.ps1", "tests\DeviceScanHistory.Ui.Tests.StatePhases.ps1",
        "tests\DeviceScanHistory.Ui.Tests.PagingPhase.ps1", "tests\Inventory.Sqlite.Helpers.ps1",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.Json.cs", "src\FingVibe.Core\Models\AppendedScanHistory.cs",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.History.cs", "src\FingVibe.Core\Storage\SqliteScanHistory.cs",
        "src\FingVibe.Core\Models\DeviceHistoryQuery.cs")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "DeviceHistory") "Device scan history"
    }
    foreach ($iconPath in @("src\FingVibe.App\PeopleRoomsIcons.cs", "src\FingVibe.App\Views\PeopleRoomsIconPicker.cs",
        "src\FingVibe.App\PeopleRoomsPresentation.cs", "src\FingVibe.App\Views\PeopleRoomsDialogs.cs")) {
        Test-Change @{ $iconPath = "changed" } `
            @("Devices", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomMap", "RoomDetails") "People/Rooms icon surfaces"
    }
    Test-Change @{ "src\FingVibe.App\MainWindow.NetworkIdentity.cs" = "changed" } `
        @("Devices", "Overview", "Network", "DeviceDetails", "PersonDetails", "RoomMap", "Troubleshooting") "Network identity code"
    Test-Change @{ "src\FingVibe.App\MainWindow.RoomMap.cs" = "changed" } `
        @("Devices", "RoomMap") "Room map shell owner"
    Test-Change @{ "src\FingVibe.Core\Models\RoomMapLayout.cs" = "changed" } `
        @("Devices", "RoomMap") "Room map projection/layout"
    Test-Change @{ "src\FingVibe.Core\Networking\AdvertisedEndpointVerifier.cs" = "changed" } `
        @("Devices", "DeviceDetails") "Service-discovery evidence"
    Test-Change @{ "src\FingVibe.App\ServiceDiscoveryPresentation.cs" = "changed" } `
        @("Devices", "DeviceDetails") "Service-discovery presentation"
    Test-Change @{ "src\FingVibe.App\MainWindow.Results.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Results and empty state"
    Test-Change @{ "src\FingVibe.App\DeviceResultFilter.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Multi-select matching and empty state"
    Test-Change @{ "src\FingVibe.App\DeviceResultSort.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Devices sort keys and direction"
    Test-Change @{ "src\FingVibe.App\App.xaml" = "changed" } @($UiReviewScenarios.Keys) "Shared theme"
    $applicationXaml = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\MainWindow.xaml") -Raw
    $applicationDocument = [System.Xml.XmlDocument]::new()
    $applicationDocument.LoadXml($applicationXaml)
    foreach ($attribute in $applicationDocument.SelectNodes("//@*")) {
        if ($attribute.Value.StartsWith("{ThemeResource ") -and -not $attribute.Value.EndsWith("}")) {
            throw "Unclosed ThemeResource expression on $($attribute.OwnerElement.Name).$($attribute.Name)."
        }
    }
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $applicationXaml } `
        @($UiReviewScenarios.Keys) "Actual application pages all have capture scenarios"
    Test-Change @{ "src\FingVibe.Core\NewModel.cs" = "changed" } @("Devices") "Core dependency baseline"
    Test-Change @{ ".github\scripts\UiReviewNavigation.ps1" = "changed" } @("Devices") "Pipeline baseline"
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml.cs" = "changed" } @("Devices") "Shell code baseline"
    Test-Change @{ "src\FingVibe.App\Tools\SpeedTestPage.xaml" = "changed" } @("Devices", "Tools", "SpeedTest", "Troubleshooting", "About", "FingImport", "SqlEditor", "DatabaseBackups") "Tools views"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml" = "changed" } @("Devices", "RoomMap", "Tools", "Troubleshooting") "Troubleshooting view"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml.cs" = "changed" } @("Devices", "RoomMap", "Tools", "Troubleshooting") "Troubleshooting behavior"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml" = "changed" } @("Devices", "About", "Settings") "About view"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml.cs" = "changed" } @("Devices", "About", "Settings") "About behavior"
    foreach ($updateOwner in @("src\FingVibe.App\Tools\AboutPage.Updates.cs", "src\FingVibe.App\MainWindow.Updates.cs",
        "src\FingVibe.App\Updates\ReleaseUpdateActions.cs", "src\FingVibe.Core\Updates\ReleaseUpdateSession.cs",
        "tests\ReleaseUpdates.Ui.Tests.ps1")) {
        Test-Change @{ $updateOwner = "changed" } @("Devices", "About", "Settings") "Update owner selects Settings and About: $updateOwner"
    }
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml" = "changed" } @("Devices", "Tools", "FingImport") "Fing import view"
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml.cs" = "changed" } @("Devices", "Tools", "FingImport") "Fing import behavior"
    Test-Change @{ "src\FingVibe.App\Tools\SqlEditorPage.xaml" = "changed" } @("Devices", "Tools", "SqlEditor") "SQL editor view"
    Test-Change @{ "src\FingVibe.App\Tools\DatabaseBackupsPage.xaml" = "changed" } @("Devices", "Tools", "DatabaseBackups") "Database backups view"
    Test-Change @{ "src\FingVibe.Core\Storage\InventoryBackupStore.cs" = "changed" } @("Devices", "Tools", "DatabaseBackups") "Backup storage behavior"
    Test-Change @{ "src\FingVibe.Core\Storage\InventoryQueryService.cs" = "changed" } @("Devices", "Tools", "SqlEditor") "SQL query behavior"
    Test-Change @{ "src\FingVibe.App\MainWindow.Inventory.cs" = "changed" } `
        @("Devices", "Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomMap", "FingImport", "SqlEditor", "RoomDetails") "Inventory surfaces"
    $viewScenarios = @{
        OverviewPageView = @("Devices", "Overview")
        NetworkPageView = @("Devices", "Network")
        DevicesPageView = @("Devices", "Settings", "DevicesEmpty")
        DeviceDetailsPageView = @("Devices", "DeviceDetails", "DeviceHistory")
        PeopleRoomsPageView = @("Devices", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomMap", "RoomDetails")
        PersonDetailsPageView = @("Devices", "DeviceDetails", "People", "PersonDetails")
        RoomDetailsPageView = @("Devices", "DeviceDetails", "Rooms", "RoomDetails")
        RoomMapPageView = @("Devices", "RoomMap")
        SettingsPageView = @($UiReviewScenarios.Keys)
    }
