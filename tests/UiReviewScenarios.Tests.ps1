$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScenarios.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewNavigation.ps1")

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$($Expected -join ', ')', got '$($Actual -join ', ')'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$repository = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-scenarios-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $repository
try {
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
    foreach ($scenario in @("Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails", "Tools", "SpeedTest", "Settings", "Devices")) {
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
        @("Devices", "DeviceDetails") "Device details code"
    Test-Change @{ "src\FingVibe.App\MainWindow.NetworkIdentity.cs" = "changed" } `
        @("Devices", "Overview", "Network", "Troubleshooting") "Network identity code"
    Test-Change @{ "src\FingVibe.App\MainWindow.Results.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Results and empty state"
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
    Test-Change @{ "src\FingVibe.App\Tools\SpeedTestPage.xaml" = "changed" } @("Devices", "Tools", "SpeedTest", "Troubleshooting", "About", "FingImport") "Tools views"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml" = "changed" } @("Devices", "Tools", "Troubleshooting") "Troubleshooting view"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml.cs" = "changed" } @("Devices", "Tools", "Troubleshooting") "Troubleshooting behavior"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml" = "changed" } @("Devices", "Tools", "About") "About view"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml.cs" = "changed" } @("Devices", "Tools", "About") "About behavior"
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml" = "changed" } @("Devices", "Tools", "FingImport") "Fing import view"
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml.cs" = "changed" } @("Devices", "Tools", "FingImport") "Fing import behavior"
    Test-Change @{ "src\FingVibe.App\MainWindow.Inventory.cs" = "changed" } `
        @("Devices", "Overview", "DeviceDetails", "People", "PersonDetails", "Rooms", "FingImport", "RoomDetails") "Inventory surfaces"
    $viewScenarios = @{
        OverviewPageView = @("Devices", "Overview")
        NetworkPageView = @("Devices", "Network")
        DevicesPageView = @("Devices", "Settings", "DevicesEmpty")
        DeviceDetailsPageView = @("Devices", "DeviceDetails")
        PeoplePageView = @("Devices", "DeviceDetails", "People", "PersonDetails")
        RoomsPageView = @("Devices", "DeviceDetails", "Rooms", "RoomDetails")
        PersonDetailsPageView = @("Devices", "DeviceDetails", "People", "PersonDetails")
        RoomDetailsPageView = @("Devices", "DeviceDetails", "Rooms", "RoomDetails")
        SettingsPageView = @($UiReviewScenarios.Keys)
    }
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
    $toolsDocument = [System.Xml.XmlDocument]::new()
    $toolsDocument.Load((Join-Path $appDirectory "Tools\ToolsPage.xaml"))
    $toolIcons = @(
        @{ Page = "SpeedTestPage"; Title = "Speed test"; Card = "SpeedTestCard"; Click = "SpeedTestCard_Click"; Glyph = 0xEC4A },
        @{ Page = "NetworkTroubleshootingPage"; Title = "Network troubleshooting"; Card = "TroubleshootingCard"; Click = "TroubleshootingCard_Click"; Glyph = 0xE90F },
        @{ Page = "AboutPage"; Title = "About FingVibe"; Card = "AboutCard"; Click = "AboutCard_Click"; Glyph = 0xE946 },
        @{ Page = "FingImportPage"; Title = "Import from Fing"; Card = "FingImportCard"; Click = "FingImportCard_Click"; Glyph = 0xE8B5 }
    )
    foreach ($tool in $toolIcons) {
        $pageDocument = [System.Xml.XmlDocument]::new()
        $pageDocument.Load((Join-Path $appDirectory "Tools\$($tool.Page).xaml"))
        $card = $toolsDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($tool.Card)']")
        if ($card.LocalName -cne "Button" -or $card.GetAttribute("Click") -cne $tool.Click -or
            $card.GetAttribute("AutomationProperties.Name") -cne $tool.Title -or
            $card.SelectNodes(".//*[local-name()='Button' or local-name()='HyperlinkButton']").Count -ne 0) {
            throw "$($tool.Title) must remain one landing button with its existing handler and accessible name."
        }
        $pageTitle = $pageDocument.SelectSingleNode("//*[local-name()='TextBlock' and @Text='$($tool.Title)' and @Style='{StaticResource ScannerPageTitleStyle}']")
        $cardTitle = $card.SelectSingleNode(".//*[local-name()='TextBlock' and @Text='$($tool.Title)']")
        foreach ($title in @($pageTitle, $cardTitle)) {
            if (-not $title -or $title.GetAttribute("TextWrapping") -cne "Wrap" -or
                $title.GetAttribute("Grid.Column") -cne "1" -or $title.GetAttribute("VerticalAlignment") -cne "Center") {
                throw "$($tool.Title) must wrap and center beside its icon."
            }
            $header = $title.ParentNode
            $columns = $header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*[local-name()='ColumnDefinition']")
            if ($header.LocalName -cne "Grid" -or $header.GetAttribute("ColumnSpacing") -cne "12" -or
                $columns.Count -ne 2 -or $columns[0].GetAttribute("Width") -cne "Auto" -or
                $columns[1].GetAttribute("Width") -cne "*") {
                throw "$($tool.Title) must reserve icon space and constrain the title for wrapping."
            }
            $icons = $header.SelectNodes("./*[local-name()='FontIcon']")
            if ($icons.Count -ne 1) { throw "$($tool.Title) must have exactly one decorative header icon." }
            $icon = $icons[0]
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
        $viewCode = Get-Content (Join-Path $appDirectory "Views\$view.xaml.cs") -Raw
        if ($viewCode -match '(?m)^\s*(public|internal)\s+(TextBlock|TextBox|ComboBox|Button|ListView|ScrollViewer|Grid|Image|FontIcon|Expander)\??\s+\w+\s*(\{|=>)') {
            throw "$view must not expose its child controls."
        }
        foreach ($child in $viewDocument.SelectNodes("//*[@*[local-name()='Name']]")) {
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
    }
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
    } @("Devices", "Tools", "SpeedTest", "Troubleshooting", "About", "FingImport") "Tools structural changes include all tools"
    $base = $originalBase

    $planPath = Join-Path $repository "plan.json"
    $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network"))
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Equal @(Read-UiReviewCapturePlan $planPath).Scenario @("Devices", "Network") "Manifest roundtrip"
    $plan[1].FileName = "..\unexpected.png"
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*Invalid capture definition*"
    '[]' | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*must include the Devices baseline*"
    $plan = @(Get-UiReviewCapturePlan $repository)
    ConvertTo-Json -InputObject @($plan[0], $plan[0]) -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*duplicate capture scenario*"

    $savedToken = $env:GH_TOKEN
    $savedOutput = $env:GITHUB_OUTPUT
    $savedTemp = $env:RUNNER_TEMP
    try {
        $env:GH_TOKEN = "test-placeholder"
        $env:GITHUB_OUTPUT = Join-Path $repository "output.txt"
        $env:RUNNER_TEMP = $repository
        function gh { $global:LASTEXITCODE = 0 }
        function git {
            $global:LASTEXITCODE = if ($args[0] -eq "ls-remote") { 2 } else { 0 }
            if ($args -contains "diff") { $global:LASTEXITCODE = 1 }
        }
        $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network", "DevicesEmpty"))
        ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
        foreach ($capture in $plan) {
            Set-Content -LiteralPath (Join-Path $repository $capture.FileName) -Value "capture fixture"
        }
        $publishScript = Join-Path $PSScriptRoot "..\.github\scripts\Publish-UiReviewScreenshot.ps1"
        & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 456
        $comment = Get-Content (Join-Path $repository "pr-comment.md") -Raw
        foreach ($capture in $plan) {
            $publishedPath = Join-Path $repository "fingvibe-ui-review-pages\ui-review\pr-123\run-456\$($capture.FileName)"
            if (-not (Test-Path -LiteralPath $publishedPath)) { throw "Missing published capture $($capture.Scenario)." }
            $url = "https://test.github.io/repo/ui-review/pr-123/run-456/$($capture.FileName)"
            $heading = "### $($capture.Label)"
            $image = "[![$($capture.Label)]($url)]($url)"
            if ([regex]::Matches($comment, [regex]::Escape($image)).Count -ne 1 -or
                [regex]::Matches($comment, [regex]::Escape($heading)).Count -ne 1) {
                throw "PR comment must include every capture's heading and inline image exactly once."
            }
            foreach ($reason in $capture.Reasons) {
                if ($comment.Contains($reason)) {
                    throw "Detailed selection reasons belong in the capture plan and logs, not the screenshot comment."
                }
            }
        }
        $savedPlan = @(Read-UiReviewCapturePlan $planPath)
        Assert-Equal $savedPlan[0].Reasons $plan[0].Reasons "Keep detailed reasons in the capture manifest"
        if (-not $comment.Contains("<!-- fingvibe-ui-review -->")) { throw "Missing stable comment marker." }
        Remove-Item -LiteralPath (Join-Path $repository $plan[1].FileName)
        Assert-Throws {
            & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 457
        } "*Required screenshot*was not found*"
    }
    finally {
        Remove-Item Function:\git, Function:\gh
        $env:GH_TOKEN = $savedToken
        $env:GITHUB_OUTPUT = $savedOutput
        $env:RUNNER_TEMP = $savedTemp
    }

    # A stateful WebDriver double checks navigation and page sentinels without launching WinUI.
    $sessionId = "test"
    $script:currentPage = "Overview"
    $script:empty = $false
    $script:hiddenControl = ""
    $script:brokenNavigation = $false
    $script:toolsScrollPercent = 0
    $script:toolsScrollCalls = 0
    $script:offscreenToolsCard = ""
    function Get-UiReviewToolsScroll([string] $Name) {
        $scroll = [pscustomobject]@{}
        $scroll | Add-Member ScriptMethod SetScrollPercent {
            param($Horizontal, $Vertical)
            if ($Horizontal -ne -1) { throw "Tools scrolling must preserve horizontal position." }
            $script:toolsScrollPercent = $Vertical
            $script:toolsScrollCalls += 1
        }
        return $scroll
    }
    function Find-WebDriverElement([string] $Using, [string] $Value) {
        if ($Using -eq "xpath") {
            if ($Value -match "^//ListItem\[@Name='(.+)'\]$") { return "menu-$($Matches[1])" }
            if ($Value -eq "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]") { return "online-row" }
            if ($Value -eq "//List[@Name='People']/ListItem[.//*[@Name='UI review person']]") { return "person-row" }
            if ($Value -eq "//List[@Name='Rooms']/ListItem[.//*[@Name='UI review room']]") { return "room-row" }
            if ($Value -eq "//Button[@Name='About FingVibe']") { return "control-About FingVibe" }
            if ($Value -eq "//Button[@Name='Speed test']") { return "control-Speed test" }
            if ($Value -eq "//Button[@Name='Network troubleshooting']") { return "control-Network troubleshooting" }
            if ($Value -eq "//Button[@Name='Import from Fing']") { return "control-Import from Fing" }
            throw "Unexpected XPath '$Value'."
        }
        return "control-$Value"
    }
    function Invoke-WebDriverElement([string] $ElementId) {
        if ($ElementId -like "menu-*") {
            if (-not $script:brokenNavigation) { $script:currentPage = $ElementId.Substring(5) }
        }
        elseif ($ElementId -eq "online-row") { $script:currentPage = "DeviceDetails" }
        elseif ($ElementId -eq "control-Speed test") { $script:currentPage = "SpeedTest" }
        elseif ($ElementId -eq "control-About FingVibe") { $script:currentPage = "About" }
        elseif ($ElementId -eq "control-Network troubleshooting") { $script:currentPage = "Troubleshooting" }
        elseif ($ElementId -eq "control-Import from Fing") { $script:currentPage = "FingImport" }
        elseif ($ElementId -eq "person-row") { $script:currentPage = "PersonDetails" }
        elseif ($ElementId -eq "room-row") { $script:currentPage = "RoomDetails" }
        else { throw "Unexpected click '$ElementId'." }
    }
    function Invoke-WebDriverRequest([string] $Method, [string] $Endpoint, [hashtable] $Body) {
        if ($Endpoint -notmatch '/element/(.+)/(displayed|selected|clear|value)$') {
            throw "Unexpected request '$Endpoint'."
        }
        $id, $operation = $Matches[1], $Matches[2]
        switch ($operation) {
            "selected" { return @{ value = ($script:currentPage -eq $id.Substring(5)) } }
            "clear" { $script:empty = $false; return @{} }
            "value" { $script:empty = $true; return @{} }
            "displayed" {
                if ($id -like "menu-*") { return @{ value = $true } }
                $visible = switch ($id) {
                    "control-Search devices" { $script:currentPage -eq "Devices" }
                    "control-Online" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "online-row" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "person-row" { $script:currentPage -eq "People" }
                    "room-row" { $script:currentPage -eq "Rooms" }
                    "control-No devices match the current filter." { $script:currentPage -eq "Devices" -and $script:empty }
                    "control-Back to devices" { $script:currentPage -eq "DeviceDetails" }
                    "control-Device name" { $script:currentPage -eq "DeviceDetails" }
                    "control-Assignments" { $script:currentPage -eq "DeviceDetails" }
                    "control-Scan additional ports" { $script:currentPage -eq "DeviceDetails" }
                    "control-Online devices" { $script:currentPage -eq "Overview" }
                    "control-Public IP address" { $script:currentPage -eq "Network" }
                    "control-Speed test" { $script:currentPage -eq "Tools" }
                    "control-Start Cloudflare speed test" { $script:currentPage -eq "SpeedTest" }
                    "control-About FingVibe" { $script:currentPage -eq "Tools" }
                    "control-Network troubleshooting" { $script:currentPage -eq "Tools" }
                    "control-Import from Fing" { $script:currentPage -eq "Tools" }
                    "control-Browse Fing export" { $script:currentPage -eq "FingImport" }
                    "control-Analyze again" { $script:currentPage -eq "FingImport" }
                    "control-Run network troubleshooting" { $script:currentPage -eq "Troubleshooting" }
                    "control-Router WAN IPv4 address" { $script:currentPage -eq "Troubleshooting" }
                    "control-Back to Tools" { $script:currentPage -in @("About", "Troubleshooting", "FingImport") }
                    "control-FingVibe LAN Scanner" { $script:currentPage -eq "About" }
                    "control-Search people" { $script:currentPage -eq "People" }
                    "control-Search rooms" { $script:currentPage -eq "Rooms" }
                    "control-Back to people" { $script:currentPage -eq "PersonDetails" }
                    "control-Back to rooms" { $script:currentPage -eq "RoomDetails" }
                    "control-Assigned devices" { $script:currentPage -in @("PersonDetails", "RoomDetails") }
                    "control-Assign devices" { $script:currentPage -in @("PersonDetails", "RoomDetails") }
                    "control-Window backdrop" { $script:currentPage -eq "Settings" }
                    default { throw "Unexpected control '$id'." }
                }
                $offscreen = $id -eq $script:offscreenToolsCard -and $script:toolsScrollPercent -lt 70
                return @{ value = ($visible -and $id -ne $script:hiddenControl -and -not $offscreen) }
            }
        }
    }
    foreach ($scenario in $UiReviewScenarios.Keys) {
        Show-UiReviewCaptureScenario $scenario
        $expectedPage = if ($scenario -eq "DevicesEmpty") { "Devices" } else { $scenario }
        Assert-Equal $script:currentPage $expectedPage "Navigation: $scenario"
    }
    Show-UiReviewCaptureScenario "Devices"
    Assert-Equal $script:empty $false "Returning from empty results restores the baseline"
    Test-UiReviewNavigation
    Assert-Equal $script:toolsScrollCalls 0 "Visible Tools cards must not scroll"
    $script:offscreenToolsCard = "control-About FingVibe"
    Show-UiReviewCaptureScenario "About"
    Assert-Equal $script:currentPage "About" "Offscreen About card navigation"
    Assert-Equal $script:toolsScrollPercent 70 "Scroll until the Tools card is visible"
    Assert-Equal $script:toolsScrollCalls 8 "Stop scrolling immediately after visibility"
    $script:offscreenToolsCard = ""
    $script:hiddenControl = "control-About FingVibe"
    $callsBeforeFailure = $script:toolsScrollCalls
    Assert-Throws { Show-UiReviewCaptureScenario "About" } "*not visible*"
    Assert-Equal ($script:toolsScrollCalls - $callsBeforeFailure) 11 "Invisible Tools cards retain a bounded failure"
    $script:hiddenControl = "control-Public IP address"
    Assert-Throws { Test-UiReviewNavigation } "*not visible*"
    Assert-Throws { Show-UiReviewCaptureScenario "Network" } "*not visible*"
    $script:hiddenControl = ""
    $script:hiddenControl = "control-Scan additional ports"
    Show-UiReviewCaptureScenario "DeviceDetails"
    $script:hiddenControl = "control-Assignments"
    Assert-Throws { Show-UiReviewCaptureScenario "DeviceDetails" } "*not visible*"
    $script:hiddenControl = "control-Run network troubleshooting"
    Show-UiReviewCaptureScenario "Troubleshooting"
    $script:hiddenControl = "control-Router WAN IPv4 address"
    Assert-Throws { Show-UiReviewCaptureScenario "Troubleshooting" } "*not visible*"
    $script:hiddenControl = ""
    foreach ($scenario in @("PersonDetails", "RoomDetails")) {
        $script:hiddenControl = "control-Assign devices"
        Assert-Throws { Show-UiReviewCaptureScenario $scenario } "*not visible*"
    }
    $script:hiddenControl = ""
    $script:brokenNavigation = $true
    Assert-Throws { Show-UiReviewCaptureScenario "Overview" } "*Navigation did not select*"
    Write-Host "UI review scenario selection, manifest, publishing, and navigation regression tests passed."
}
finally {
    Remove-Item -LiteralPath $repository -Recurse -Force
}
