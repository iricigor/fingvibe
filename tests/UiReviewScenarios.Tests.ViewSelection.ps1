# Scenario selection: extracted page views and unsupported pages.
    foreach ($view in $viewScenarios.Keys) {
        foreach ($extension in @("xaml", "xaml.cs")) {
            Test-Change @{ "src\FingVibe.App\Views\$view.$extension" = "changed" } `
                $viewScenarios[$view] "Extracted $view $extension"
        }
    }
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\Views\UnknownPageView.xaml" = "changed" } @() "Unsupported page view"
    } "*has no selection rule*"
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\Tools\UnknownPage.xaml" = "changed" } @() "Unsupported extracted page"
    } "*has no selection rule*"
    $base = Invoke-UiReviewGit $repository @("rev-parse", "$originalBase")
    $oldXaml = $navigationBase.Replace('<Grid x:Name="ToolsPage"><TextBlock Text="ToolsPage" /></Grid>', '')
    $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
    Set-Content -LiteralPath $xamlPath -Value $oldXaml
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Before Tools")
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")
    Test-Change @{
        "src\FingVibe.App\MainWindow.xaml" = $navigationXaml.Replace('<Grid x:Name="ToolsPage">', '<!-- Tools --><Grid x:Name="ToolsPage">')
        "src\FingVibe.App\MainWindow.xaml.cs" = "Tools routing"
        "src\FingVibe.App\MainWindow.Scan.cs" = "Activity coordination"
        "src\FingVibe.App\FingVibe.App.csproj" = "WebView2 dependency"
        "src\FingVibe.App\Tools\ToolsPage.xaml" = "Tools"
        "src\FingVibe.App\Tools\SpeedTestPage.xaml" = "Speed test"
        "src\FingVibe.App\Assets\SpeedTest\speedtest.js" = "engine"
        ".github\scripts\UiReviewScenarios.ps1" = "New scenarios"
        ".github\scripts\UiReviewNavigation.ps1" = "New navigation"
        "tests\UiReviewScenarios.Tests.ps1" = "New tests"
        "README.md" = "Tools documentation"
    } @("Devices", "DeviceDetails", "DeviceHistory", "RoomMap", "Tools", "SpeedTest", "NetworkHealth", "ServiceStatus", "About", "FingImport", "SqlEditor", "DatabaseBackups") "Tools structural changes include all tools and scan discovery"
    $base = $originalBase
