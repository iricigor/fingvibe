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
    Test-Change @{ "src\FingVibe.App\MainWindow.DeviceDetails.cs" = "changed" } `
        @("Devices", "DeviceDetails") "Device details code"
    Test-Change @{ "src\FingVibe.App\MainWindow.NetworkIdentity.cs" = "changed" } `
        @("Devices", "Overview", "Network") "Network identity code"
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
    Test-Change @{ "src\FingVibe.Core\NewModel.cs" = "changed" } @($UiReviewScenarios.Keys) "Unrecognized app dependency"
    Test-Change @{ ".github\scripts\UiReviewNavigation.ps1" = "changed" } @($UiReviewScenarios.Keys) "Pipeline self-coverage"

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
    function Find-WebDriverElement([string] $Using, [string] $Value) {
        if ($Using -eq "xpath") {
            if ($Value -match "^//ListItem\[@Name='(.+)'\]$") { return "menu-$($Matches[1])" }
            if ($Value -eq "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]") { return "online-row" }
            if ($Value -eq "//List[@Name='People']/ListItem[.//*[@Name='UI review person']]") { return "person-row" }
            if ($Value -eq "//List[@Name='Rooms']/ListItem[.//*[@Name='UI review room']]") { return "room-row" }
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
                    "control-Filter scan results" { $script:currentPage -eq "Devices" }
                    "control-Online" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "online-row" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "person-row" { $script:currentPage -eq "People" }
                    "room-row" { $script:currentPage -eq "Rooms" }
                    "control-No hosts match the current filter." { $script:currentPage -eq "Devices" -and $script:empty }
                    "control-Back to devices" { $script:currentPage -eq "DeviceDetails" }
                    "control-Device name" { $script:currentPage -eq "DeviceDetails" }
                    "control-Assignments" { $script:currentPage -eq "DeviceDetails" }
                    "control-Scan additional ports" { $script:currentPage -eq "DeviceDetails" }
                    "control-Online devices" { $script:currentPage -eq "Overview" }
                    "control-Public IP address" { $script:currentPage -eq "Network" }
                    "control-Speed test" { $script:currentPage -eq "Tools" }
                    "control-Start Cloudflare speed test" { $script:currentPage -eq "SpeedTest" }
                    "control-Search people" { $script:currentPage -eq "People" }
                    "control-Search rooms" { $script:currentPage -eq "Rooms" }
                    "control-Back to people" { $script:currentPage -eq "PersonDetails" }
                    "control-Back to rooms" { $script:currentPage -eq "RoomDetails" }
                    "control-Assigned devices" { $script:currentPage -in @("PersonDetails", "RoomDetails") }
                    "control-Assign devices" { $script:currentPage -in @("PersonDetails", "RoomDetails") }
                    "control-Window backdrop" { $script:currentPage -eq "Settings" }
                    default { throw "Unexpected control '$id'." }
                }
                return @{ value = ($visible -and $id -ne $script:hiddenControl) }
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
    $script:hiddenControl = "control-Public IP address"
    Assert-Throws { Show-UiReviewCaptureScenario "Network" } "*not visible*"
    $script:hiddenControl = ""
    $script:hiddenControl = "control-Scan additional ports"
    Show-UiReviewCaptureScenario "DeviceDetails"
    $script:hiddenControl = "control-Assignments"
    Assert-Throws { Show-UiReviewCaptureScenario "DeviceDetails" } "*not visible*"
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
