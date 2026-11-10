$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "NetworkActivity.Fixture.ps1")
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "EquipmentActivity.Ui.Tests.ps1"), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors.Message -join "; ") }
$ui = Get-Content (Join-Path $PSScriptRoot "EquipmentActivity.Ui.Tests.ps1") -Raw
foreach ($required in @('$env:GITHUB_ACTIONS -ne "true"', 'Wait-UiRegressionSurfaceState', 'Assert-UiRegressionPeers',
    'Stop-UiRegressionApp', 'Complete-UiRegressionPhase', 'EquipmentActivityCell-29-23', 'BEGIN EXCLUSIVE', 'cancelled')) {
    if (-not $ui.Contains($required)) { throw "Missing Equipment native contract: $required" }
}
$bin = Join-Path $PSScriptRoot "FingVibe.Core.Tests\bin\Release\net8.0"
$null = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $bin "runtimes\win-x64\native\e_sqlite3.dll"))
foreach ($name in @("FingVibe.Core.dll", "SQLitePCLRaw.core.dll", "SQLitePCLRaw.provider.e_sqlite3.dll",
    "SQLitePCLRaw.batteries_v2.dll", "Microsoft.Data.Sqlite.dll")) {
    $null = [Reflection.Assembly]::LoadFrom((Join-Path $bin $name))
}
[SQLitePCL.Batteries_V2]::Init()
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-equipment-script-$([Guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $fixture
    New-NetworkActivityFixture $fixture -Equipment
    $token = [Threading.CancellationToken]::None
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new((Join-Path $fixture "inventory.sqlite"))
    $data = $store.LoadMetadataAsync($token).GetAwaiter().GetResult()
    $person = [Guid]"00000000-0000-0000-0000-000000000241"
    $selection = [FingVibe.Core.Models.EquipmentActivity]::Select($data, $person, "ui-review-network", "127.0.0.1/32")
    $request = [FingVibe.Core.Models.AnalyticsEvidenceRequest]::new(
        "ui-review-network", "127.0.0.1/32", [DateTimeOffset]::UtcNow, 30, [TimeZoneInfo]::Local, $data.Revision, $selection.QueryDevices)
    $evidence = $store.QueryAnalyticsAsync($request, $token).GetAwaiter().GetResult()
    if ($data.Devices.Count -ne 1000 -or $evidence.Devices.Count -ne 3) { throw "Equipment query did not isolate three assignments from the large inventory." }
    $latest = [FingVibe.Core.Models.EquipmentActivity]::Latest($evidence)
    if ($latest.State.ToString() -ne "Online" -or $latest.Responded -ne 2 -or $latest.Total -ne 3) { throw "Native latest-scan fixture is incorrect." }
    $contributors = [FingVibe.Core.Models.ActivityContributor[]]@($evidence.Devices | ForEach-Object {
        [FingVibe.Core.Models.ActivityContributor]::new($_.Identity, $null, 0, 0)
    })
    $buckets = [FingVibe.Core.Models.DeviceActivity]::Group($evidence, 1, $token)
    $days = [FingVibe.Core.Models.NetworkActivity]::Count($buckets, $contributors, [FingVibe.Core.Models.ActivityCountFilter]::new(), $token)
    $yesterday = [DateOnly]::FromDateTime([DateTime]::Today.AddDays(-1))
    foreach ($expected in @(@(12, 2, "Exact"), @(13, 0, "Exact"), @(14, 2, "Partial"), @(15, 0, "Unknown"))) {
        $day = @($days | Where-Object { $_.Date -eq $yesterday -and $_.StartHour -eq $expected[0] })[0]
        if ($day.Count -ne $expected[1] -or $day.Coverage.ToString() -ne $expected[2]) { throw "Incorrect equipment count fixture at $($expected[0]): $day" }
    }
    $week = [FingVibe.Core.Models.NetworkActivity]::ByWeekday($days, $token)
    $wednesday = @($week | Where-Object { $_.Day.ToString() -eq "Wednesday" -and $_.StartHour -eq 10 })[0]
    if ($wednesday.Mean -ne 1.5 -or $wednesday.ExactDates -ne 2) { throw "Native equipment weekday fixture is incorrect." }
    $empty = [FingVibe.Core.Models.EquipmentActivity]::Select($data,
        [Guid]"00000000-0000-0000-0000-000000000242", "ui-review-network", "127.0.0.1/32")
    if ($empty.QueryDevices.Count -ne 0) { throw "No-equipment person inherited another person's assignments." }
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Equipment production-query fixture, indicator, counts, weekday and empty-selection checks passed."
