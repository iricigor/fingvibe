$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "NetworkActivity.Fixture.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
foreach ($name in @("NetworkActivity.Fixture.ps1", "NetworkActivity.Ui.Tests.ps1")) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "; ") }
}
$ui = Get-Content (Join-Path $PSScriptRoot "NetworkActivity.Ui.Tests.ps1") -Raw
foreach ($required in @('$env:GITHUB_ACTIONS -ne "true"', 'Wait-UiRegressionSurfaceState',
    'Assert-UiRegressionPeers', 'Stop-UiRegressionApp', 'Complete-UiRegressionPhase',
    'NetworkActivityRoom', 'NetworkActivityType', 'NetworkActivityCategory', 'NetworkActivityCell-29-23',
    'BEGIN EXCLUSIVE', 'cancelled', 'network-activity-failure')) {
    if (-not $ui.Contains($required)) { throw "Missing Network activity native contract: $required" }
}
$view = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\NetworkPageView.Activity.cs") -Raw
if ($view -notmatch 'AsyncSurfaceSession' -or
    $view -notmatch 'AutomationProperties.SetItemStatus\(NetworkActivityScroll, _activitySession.Status\)' -or
    $view -notmatch 'Task.Run' -or $view -notmatch '_activitySession.Cancel\(\)') { throw "Network activity lifecycle wiring is incomplete." }
$xaml = [xml](Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\NetworkPageView.xaml") -Raw)
$namespaces = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
$namespaces.AddNamespace("ui", "http://schemas.microsoft.com/winfx/2006/xaml/presentation")
$namespaces.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")
$cards = $xaml.SelectNodes("//ui:ScrollViewer[@x:Name='NetworkPage']/ui:StackPanel/ui:Border", $namespaces)
if ($cards.Count -ne 3 -or
    -not $cards[0].SelectSingleNode(".//ui:TextBlock[@x:Name='PublicAddressText']", $namespaces) -or
    -not $cards[1].SelectSingleNode(".//ui:TextBlock[@x:Name='SubnetSizeText']", $namespaces) -or
    -not $cards[2].SelectSingleNode(".//ui:ComboBox[@x:Name='NetworkActivityPeriod']", $namespaces)) {
    throw "Network identity, subnet details and Activity must remain separate top-level cards in that order."
}
$bin = Join-Path $PSScriptRoot "FingVibe.Core.Tests\bin\Release\net8.0"
$null = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $bin "runtimes\win-x64\native\e_sqlite3.dll"))
foreach ($name in @("FingVibe.Core.dll", "SQLitePCLRaw.core.dll", "SQLitePCLRaw.provider.e_sqlite3.dll",
    "SQLitePCLRaw.batteries_v2.dll", "Microsoft.Data.Sqlite.dll")) {
    $null = [Reflection.Assembly]::LoadFrom((Join-Path $bin $name))
}
[SQLitePCL.Batteries_V2]::Init()
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-network-script-$([Guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $fixture
    New-NetworkActivityFixture $fixture
    $token = [Threading.CancellationToken]::None
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new((Join-Path $fixture "inventory.sqlite"))
    $data = $store.LoadMetadataAsync($token).GetAwaiter().GetResult()
    $request = [FingVibe.Core.Models.AnalyticsEvidenceRequest]::new(
        "ui-review-network", "127.0.0.1/32", [DateTimeOffset]::UtcNow, 30, [TimeZoneInfo]::Local, $data.Revision)
    $evidence = $store.QueryAnalyticsAsync($request, $token).GetAwaiter().GetResult()
    if ($evidence.Devices.Count -ne 1000) { throw "Native fixture must contain 1,000 logical devices." }
    $contributors = [FingVibe.Core.Models.ActivityContributor[]]@($evidence.Devices | ForEach-Object {
        [FingVibe.Core.Models.ActivityContributor]::new($_.Identity, $null, 0, 0)
    })
    $buckets = [FingVibe.Core.Models.DeviceActivity]::Group($evidence, 1, $token)
    $days = [FingVibe.Core.Models.NetworkActivity]::Count($buckets, $contributors, [FingVibe.Core.Models.ActivityCountFilter]::new(), $token)
    $yesterday = [DateOnly]::FromDateTime([DateTime]::Today.AddDays(-1))
    foreach ($expected in @(@(12, 3, "Exact"), @(13, 0, "Exact"), @(14, 2, "Partial"), @(15, 0, "Unknown"))) {
        $day = @($days | Where-Object { $_.Date -eq $yesterday -and $_.StartHour -eq $expected[0] })[0]
        if ($day.Count -ne $expected[1] -or $day.Coverage.ToString() -ne $expected[2]) { throw "Incorrect native count fixture at $($expected[0]): $day" }
    }
    $week = [FingVibe.Core.Models.NetworkActivity]::ByWeekday($days, $token)
    $wednesday = @($week | Where-Object { $_.Day.ToString() -eq "Wednesday" -and $_.StartHour -eq 9 })[0]
    if ($wednesday.Mean -ne 12 -or $wednesday.ExactDates -ne 3) { throw "Native exact weekday fixture is incorrect." }
    Invoke-InventoryMalformedTimestamp -Path (Join-Path $fixture 'inventory.sqlite') -Table scan_evidence -WhileMalformed {
        $malformedError = $null
        try { $null = $store.QueryAnalyticsAsync($request, $token).GetAwaiter().GetResult() }
        catch { $malformedError = $_.Exception.GetBaseException() }
        if ($malformedError -isnot [IO.InvalidDataException] -or $malformedError.Message -notlike "*inconsistent timestamps*") {
            throw "The malformed Network/equipment fixture must exercise InvalidDataException: $malformedError"
        }
    }
    $restored = $store.QueryAnalyticsAsync($request, $token).GetAwaiter().GetResult()
    if ($restored.Scans.Count -ne $evidence.Scans.Count) { throw "Restoring malformed Network/equipment evidence changed the fixture." }
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Network activity production-query fixture, union/zero/partial/weekday, malformed-evidence restoration and lifecycle contracts passed."
