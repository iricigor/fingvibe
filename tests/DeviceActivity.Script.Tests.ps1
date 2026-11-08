$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DeviceActivity.Fixture.ps1")
foreach ($name in @("DeviceActivity.Ui.Tests.ps1", "DeviceActivity.Fixture.ps1")) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "; ") }
}
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewDeviceTabs.ps1"), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors.Message -join "; ") }
$ui = Get-Content -LiteralPath (Join-Path $PSScriptRoot "DeviceActivity.Ui.Tests.ps1") -Raw
if ($ui -notmatch '\$env:GITHUB_ACTIONS -ne "true"' -or $ui -match 'Stop-Process -Name') {
    throw "Native checks must remain isolated to the disposable runner and owned processes."
}
if ($ui -notmatch 'FINGVIBE_UI_REVIEW_ACTIVITY_HOLD' -or $ui -match 'BEGIN EXCLUSIVE') {
    throw "Loading/cancellation captures need a cancellable test hold, not a writer lock beyond the query's 100ms busy budget."
}
$loader = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\FingVibe.App\MainWindow.DeviceActivity.cs") -Raw
if ($loader -notmatch 'IsUiReview && Environment.GetEnvironmentVariable\("FINGVIBE_UI_REVIEW_ACTIVITY_HOLD"\)' -or
    $loader -notmatch 'await Task.Delay\(25, cancellation\)' -or $loader -notmatch 'AddSeconds\(30\)') {
    throw "Activity test holds must remain UI-review-only, cancellable and bounded."
}
[xml]$page = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml") -Raw
$card = $page.SelectSingleNode("//*[@*[local-name()='Name']='DeviceActivityCard']")
if (-not $card -or -not $card.NextSibling.SelectSingleNode(".//*[@Text='Scan history']")) { throw "Activity must precede existing scan history." }
if (-not $card.SelectSingleNode("ancestor::*[@*[local-name()='Name']='HistoryTab']")) { throw "Activity must be on History." }
foreach ($id in @("ActivityPeriod", "ActivityHours", "ActivityStatus", "ActivityScroll", "ActivityDetail", "ActivityRefresh")) {
    if (-not $card.SelectSingleNode(".//*[@*[local-name()='Name']='$id']")) { throw "Missing native activity control $id." }
}
if ($card.SelectSingleNode(".//*[@*[local-name()='Name']='ActivityGrid']").GetAttribute("TabFocusNavigation") -cne "Once") {
    throw "Activity grid must expose one Tab stop through TabFocusNavigation=Once."
}
if ((Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.Activity.cs") -Raw) -match 'IsTabStop') {
    throw "Activity cells must remain keyboard focusable for UI Automation; do not disable IsTabStop."
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-activity-script-$([Guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $fixture
    New-DeviceActivityFixture $fixture
    $bin = Join-Path $PSScriptRoot "FingVibe.Core.Tests\bin\Release\net8.0"
    $null = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $bin "runtimes\win-x64\native\e_sqlite3.dll"))
    foreach ($name in @("FingVibe.Core.dll", "SQLitePCLRaw.core.dll", "SQLitePCLRaw.provider.e_sqlite3.dll",
        "SQLitePCLRaw.batteries_v2.dll", "Microsoft.Data.Sqlite.dll")) {
        $null = [Reflection.Assembly]::LoadFrom((Join-Path $bin $name))
    }
    [SQLitePCL.Batteries_V2]::Init()
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new((Join-Path $fixture "inventory.sqlite"))
    $token = [Threading.CancellationToken]::None
    $saved = $store.LoadMetadataAsync($token).GetAwaiter().GetResult()
    $identity = [FingVibe.Core.Models.LogicalDeviceId]::Mac("001122334455")
    $ids = [FingVibe.Core.Models.LogicalDeviceId[]]@($identity)
    $request = [FingVibe.Core.Models.AnalyticsEvidenceRequest]::new(
        "ui-review-network", "127.0.0.1/32", [DateTimeOffset]::UtcNow, 30, [TimeZoneInfo]::Local, $saved.Revision, $ids)
    $evidence = $store.QueryAnalyticsAsync($request, $token).GetAwaiter().GetResult()
    $buckets = [FingVibe.Core.Models.DeviceActivity]::Group($evidence, 1, $token)
    $yesterday = [DateOnly]::FromDateTime([DateTime]::Today.AddDays(-1))
    $positive = @($buckets.Days | Where-Object { $_.Date -eq $yesterday -and $_.StartHour -eq 11 })[0]
    $negative = @($buckets.Days | Where-Object { $_.Date -eq $yesterday -and $_.StartHour -eq 12 })[0]
    $unknown = @($buckets.Days | Where-Object { $_.Date -eq $yesterday -and $_.StartHour -eq 13 })[0]
    if ($positive.Devices[0].Responded -ne 1 -or $positive.Devices[0].DidNotRespond -ne 2 -or
        $negative.Devices[0].Response.ToString() -ne "DidNotRespond" -or $unknown.Devices[0].Response.ToString() -ne "Unknown") {
        throw "Native daily fixture must expose exactly response+2 negatives, known negative and unknown."
    }
    $weekdays = [FingVibe.Core.Models.DeviceActivity]::ByWeekday($buckets, 0, $token)
    $wednesday = @($weekdays | Where-Object { $_.Day.ToString() -eq "Wednesday" -and $_.StartHour -eq 9 })[0]
    if ($wednesday.RespondingDates -ne 3 -or $wednesday.ApplicableDates -notin @(4, 5) -or
        $wednesday.UnknownDates -ne $wednesday.ApplicableDates - 3) { throw "Native weekday fixture denominator is incorrect." }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Device Activity native script syntax, placement and exact migrated evidence fixture passed without desktop automation."
