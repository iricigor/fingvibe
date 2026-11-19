$ErrorActionPreference = "Stop"
$skill = Join-Path $PSScriptRoot "..\.github\skills\loop4-epic-chart\scripts"
. (Join-Path $skill "Publish-EpicChart.ps1") -EvidencePath "unused"
function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
function Event([string] $Kind, [string] $At, [string] $Label) {
    @{ event = $Kind; created_at = $At; label = @{ name = $Label } }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-epic-chart-test-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $root
try {
    $now = [DateTimeOffset] "2026-11-16T13:30:00Z"
    $children = @(
        @{ number = 1; state = "closed"; state_reason = "completed"; created_at = "2026-11-15T00:00:00Z"; labels = @() },
        @{ number = 2; state = "open"; created_at = "2026-11-15T00:00:00Z"; labels = @(@{ name = "status:review" }) },
        @{ number = 3; state = "open"; created_at = "2026-11-16T12:15:00Z"; labels = @() }
    )
    $histories = @{
        1 = @((Event labeled "2026-11-16T10:20:00Z" active), (Event closed "2026-11-16T12:10:00Z"))
        2 = @((Event labeled "2026-11-16T11:00:00Z" active),
            (Event unlabeled "2026-11-16T11:30:00Z" active),
            (Event labeled "2026-11-16T11:30:00Z" status:review))
        3 = @()
    }
    $report = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-11-16T10:00:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True (($report.snapshots.completed -join ",") -eq "0,0,0,1,1") "Closure, not submission, determines completion."
    Assert-True (($report.snapshots.inProgress -join ",") -eq "0,2,2,1,1") "Exact hour starts and review waits stay in progress."
    Assert-True (($report.snapshots.notStarted -join ",") -eq "3,1,1,1,1") "All current children must remain in the cohort."
    Assert-True ($report.warnings.Count -eq 1) "Creation after Epic must disclose historical cohort limitation."
    foreach ($row in $report.snapshots) {
        Assert-True (($row.completed + $row.inProgress + $row.notStarted) -eq 3) "Stack total must match native cohort."
    }
    Assert-True ($report.forecast.status -eq "estimated" -and $report.forecast.windowHours -eq 3.5 -and
        $report.forecast.remainingHours -eq 7) "Young Epics use exact elapsed time and include all unfinished tasks."
    Assert-True ([DateTimeOffset] $report.forecast.finishAt -eq $now.AddHours(7)) "Finish must extrapolate from completed progress."
    $summary = Format-EpicChartForecast $report
    Assert-True ($summary -like "*2026-11-16 20:30 +00:00*7h 0m remaining (2 tasks)*0.29 tasks/hour*3.5 elapsed hours*not a deadline guarantee*") "Summary must disclose local finish, duration, rate, window and assumptions."
    foreach ($case in @(
        @{ extra = 49; finish = "2026-11-16 20:30"; duration = "7h 0m" },
        @{ extra = 50; finish = "2026-11-16 20:35"; duration = "7h 0m" },
        @{ extra = 51; finish = "2026-11-16 20:35"; duration = "7h 0m" },
        @{ extra = 74; finish = "2026-11-16 20:35"; duration = "7h 0m" },
        @{ extra = 75; finish = "2026-11-16 20:35"; duration = "7h 5m" },
        @{ extra = 76; finish = "2026-11-16 20:35"; duration = "7h 5m" }
    )) {
        # With two tasks left, each extra elapsed second moves the finish three seconds.
        $rounded = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-11-16T10:00:00Z") (
            $now.AddSeconds($case.extra)) ([TimeZoneInfo]::Utc)
        $text = Format-EpicChartForecast $rounded
        Assert-True ($text.Contains("$($case.finish) +00:00") -and $text.Contains("$($case.duration) remaining")) "Finish and duration rounding must handle either side of their five-minute midpoints."
    }
    $zeroWindow = Get-EpicChartSnapshots $children $histories $now $now ([TimeZoneInfo]::Utc)
    Assert-True ($zeroWindow.forecast.status -eq "unavailable" -and
        (Format-EpicChartForecast $zeroWindow) -like "*no elapsed observation time*") "Zero elapsed time cannot produce an ETA."
    $missing = $histories.Clone(); $missing.Remove(1)
    Assert-Fails { Get-EpicChartSnapshots $children $missing $now $now ([TimeZoneInfo]::Utc) } "*Missing lifecycle*"
    $oldReason = $children[0].state_reason; $children[0].state_reason = "not_planned"
    $nonCompleted = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-11-16T10:00:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True ($nonCompleted.snapshots[-1].total -eq 2 -and $nonCompleted.snapshots[-1].completed -eq 0) "Non-completed closures are excluded from the cohort, not counted as completed."
    Assert-True (($nonCompleted.warnings -join "`n") -like "*#1 has non-completed closure reason(s): not_planned; excluded from chart cohort.*") "Exclusions must be disclosed in warnings."
    $children[0].state_reason = $oldReason
    $oldEvents = $histories[2]; $histories[2] = @()
    Assert-Fails { Get-EpicChartSnapshots $children $histories $now $now ([TimeZoneInfo]::Utc) } "*Missing start evidence*"
    $histories[2] = $oldEvents
    $children[0].state = "open"
    $histories[1][1].state_reason = "completed"
    $original = $histories[1]
    $histories[1] += Event reopened "2026-11-16T13:00:00Z"
    $reopened = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-11-16T10:00:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True ($reopened.snapshots[-1].completed -eq 0 -and $reopened.snapshots[-1].inProgress -eq 2) "An evidenced reopened task resumes progress."
    Assert-True ($reopened.forecast.status -eq "unavailable" -and $reopened.forecast.netCompleted -eq 0 -and
        (Format-EpicChartForecast $reopened) -like "*no positive net completion progress*") "A closure followed by reopening provides no net throughput."
    $negative = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-11-16T12:30:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True ($negative.forecast.status -eq "unavailable" -and $negative.forecast.netCompleted -eq -1) "Negative completion progress cannot produce an ETA."
    $histories[1][1].Remove("state_reason")
    Assert-Fails { Get-EpicChartSnapshots $children $histories $now $now ([TimeZoneInfo]::Utc) } "*Historical closure reason*"
    $histories[1] = $original; $children[0].state = "closed"
    $longReport = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-10-01T00:00:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True ($longReport.snapshots.Count -eq 25) "Keep 24 hourly boundaries plus partial snapshot."
    $dst = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] "2026-10-01T00:00:00Z") $now (
        [TimeZoneInfo]::FindSystemTimeZoneById("Central European Standard Time"))
    Assert-True ($dst.snapshots[-1].label -like "*14:30*+01:00") "Local labels must include explicit UTC offset."
    Assert-True ((Format-EpicChartForecast $dst) -like "*2026-11-18 14:30 +01:00*") "Forecast must use the report timezone and finish-date offset."

    $rollingChildren = @(1..4 | ForEach-Object {
        @{ number = $_; state = $(if ($_ -le 2) { "closed" } else { "open" })
            state_reason = "completed"; created_at = "2026-11-01T00:00:00Z"; labels = @() }
    })
    $rollingHistories = @{
        1 = @((Event labeled "2026-11-15T10:00:00Z" active), (Event closed "2026-11-15T13:15:00Z"))
        2 = @((Event labeled "2026-11-15T10:00:00Z" active), (Event closed "2026-11-15T13:45:00Z"))
        3 = @(); 4 = @()
    }
    $rolling = Get-EpicChartSnapshots $rollingChildren $rollingHistories (
        [DateTimeOffset] "2026-11-01T00:00:00Z") $now ([TimeZoneInfo]::Utc)
    Assert-True ($rolling.forecast.windowHours -eq 24 -and $rolling.forecast.netCompleted -eq 1 -and
        $rolling.forecast.remainingHours -eq 48) "Use the exact 24-hour baseline, not the oldest rendered hour or lifetime completions."
    $stalled = Get-EpicChartSnapshots $rollingChildren $rollingHistories (
        [DateTimeOffset] "2026-11-01T00:00:00Z") $now.AddDays(2) ([TimeZoneInfo]::Utc)
    Assert-True ($stalled.forecast.status -eq "unavailable") "Old completions cannot disguise a stalled recent window."
    foreach ($number in 3..4) {
        $rollingChildren[$number - 1].state = "closed"
        $rollingHistories[$number] = @((Event labeled "2026-11-16T10:00:00Z" active),
            (Event closed "2026-11-16T12:00:00Z"))
    }
    $done = Get-EpicChartSnapshots $rollingChildren $rollingHistories $now $now ([TimeZoneInfo]::Utc)
    Assert-True ((Format-EpicChartForecast $done) -eq "**Estimated finish:** All tasks completed.") "A completed cohort needs no extrapolation even with zero elapsed time."

    $published = Get-EpicChartMarker 448 published
    $comments = @(@{ body = $published; updatedAt = "2026-11-16T12:30:00Z"; url = "fixture://chart" })
    Assert-True (Test-EpicChartDue $comments 448 $now) "Exactly 60 minutes permits publication."
    Assert-True (-not (Test-EpicChartDue $comments 448 $now.AddTicks(-1))) "Less than 60 minutes stays throttled."
    Import-Module (Join-Path $skill "EpicChart.psm1") -Force
    Assert-True (-not (Test-EpicChartDue $comments 448 $now.AddMinutes(-1))) "Durable comment survives module/context restart."
    Assert-True (Test-EpicChartDue $comments 92 $now) "Different Epics have independent throttles."
    Assert-Fails { Test-EpicChartDue $comments 448 $now.AddHours(-2) } "*future*"
    Assert-Fails { Test-EpicChartDue @(@{ body = (Get-EpicChartMarker 448 pending); url = "fixture://pending" }) 448 $now } "*human reconciliation*"

    $image = Join-Path $root "chart.png"
    Save-EpicChart $report 448 $image
    $bitmap = [Drawing.Bitmap]::new($image)
    try {
        Assert-True ($bitmap.Width -ge 1200 -and $bitmap.Height -eq 720) "PNG dimensions must support readable labels."
        # Last bar has one completed, one in progress, one unstarted: sample inside each segment, away from text/lines.
        $x = [int] (65 + (($bitmap.Width - 105) / 5) * 4.5 - 20)
        Assert-True ($bitmap.GetPixel($x, 520).ToArgb() -eq [Drawing.ColorTranslator]::FromHtml("#22c55e").ToArgb()) "Completed must be green."
        Assert-True ($bitmap.GetPixel($x, 390).ToArgb() -eq [Drawing.ColorTranslator]::FromHtml("#f59e0b").ToArgb()) "In progress must stack orange over completed."
        Assert-True ($bitmap.GetPixel($x, 260).ToArgb() -eq [Drawing.ColorTranslator]::FromHtml("#ef4444").ToArgb()) "Not started must stack red, not total."
    } finally { $bitmap.Dispose() }

    $script:comments = @(); $script:writes = 0; $script:uploads = 0; $script:lostUpdate = $false
    function Invoke-ChartGraphQl([string] $Query, [hashtable] $Variables) {
        if ($Query.Contains("nameWithOwner")) {
            return @{ repository = @{ nameWithOwner = "TestOwner/TestRepo"; discussion = @{
                id = "D1"; url = "https://github.com/TestOwner/TestRepo/discussions/9"
                body = "<!-- fingvibe:epic=448 -->"; category = @{ name = "🧭 Epic coordination" }
            } } }
        }
        if ($Query.Contains("comments(first:")) {
            return @{ node = @{ comments = @{ nodes = @($script:comments); pageInfo = @{ hasNextPage = $false } } } }
        }
        if ($Query.Contains("addDiscussionComment")) {
            $script:writes++
            $comment = @{ id = "C1"; body = $Variables.body; url = "fixture://C1"; updatedAt = [DateTimeOffset]::UtcNow.ToString("o") }
            $script:comments += $comment
            return @{ addDiscussionComment = @{ comment = $comment } }
        }
        if ($Query.Contains("updateDiscussionComment")) {
            $script:comments[0].body = $Variables.body
            $script:comments[0].updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
            if ($script:lostUpdate) { throw "Response lost after successful mutation." }
            return @{ updateDiscussionComment = @{ comment = @{ id = "C1" } } }
        }
        if ($Query.Contains("... on DiscussionComment")) { return @{ node = $script:comments[0] } }
        throw "Unexpected GraphQL operation: $Query"
    }
    function Send-ChartImage { $script:uploads++; "https://github.com/user-attachments/assets/fixture-image" }
    $script:freshReads = 0
    $script:restFixtures = @{}
    function gh {
        $global:LASTEXITCODE = 0
        $endpoint = $args[-1]
        if ($script:restFixtures.ContainsKey($endpoint)) {
            $script:freshReads++
            $value = $script:restFixtures[$endpoint]
            if ($args -notcontains "--slurp") {
                return (ConvertTo-Json -InputObject $value -Depth 20 -Compress)
            }
        } else {
            $value = @(@{ event = "labeled"; created_at = [DateTimeOffset]::UtcNow.AddHours(-1).ToString("o"); label = @{ name = "active" } })
        }
        $pages = [Collections.Generic.List[object]]::new()
        $pages.Add(@($value))
        ConvertTo-Json -InputObject $pages.ToArray() -Depth 10 -Compress
    }
    $evidencePath = Join-Path $root "evidence.json"
    $evidence = @{
        schema = "fingvibe-loop4-evidence-v1"; repository = "TestOwner/TestRepo"; epic = 448
        utc = [DateTimeOffset]::UtcNow.ToString("o")
        discussions = @(@{ number = 9; category = @{ name = "🧭 Epic coordination" }; body = "<!-- fingvibe:epic=448 -->" })
        reads = @{
            "repos/TestOwner/TestRepo|False|" = @{ id = 100; full_name = "TestOwner/TestRepo" }
            "repos/TestOwner/TestRepo/issues/448|False|" = @{ number = 448; labels = @(@{ name = "type:epic" }); created_at = [DateTimeOffset]::UtcNow.AddHours(-2).ToString("o") }
            "repos/TestOwner/TestRepo/issues/448/sub_issues?per_page=100|True|" = @(
                @{ number = 1; state = "open"; created_at = "2026-11-01T00:00:00Z"; labels = @(@{ name = "active" }) })
        }
    }
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $evidencePath
    $script:lostUpdate = $true
    Assert-Fails { Publish-EpicChart $evidencePath "UTC" $root } "*Reconcile*Response lost*"
    Assert-True ($script:uploads -eq 1 -and $script:writes -eq 1) "One reservation and one upload per attempt."
    $script:lostUpdate = $false
    $retry = Publish-EpicChart $evidencePath "UTC" $root
    Assert-True ($retry.status -eq "throttled" -and $script:uploads -eq 1 -and $script:writes -eq 1) "A lost successful-write response must not duplicate publication."
    $script:comments[0].body = Get-EpicChartMarker 448 pending
    Assert-Fails { Publish-EpicChart $evidencePath "UTC" $root } "*human reconciliation*"
    Assert-True ($script:uploads -eq 1 -and $script:writes -eq 1) "Uncertain pending write blocks even after restart."
    $script:comments = @()
    $result = Publish-EpicChart $evidencePath "UTC" $root
    Assert-True ($result.status -eq "published" -and $script:comments.Count -eq 1) "Successful reporting updates the reservation, not a second comment."
    Assert-True ($script:comments[0].body.Contains("https://github.com/user-attachments/assets/") -and
        -not $script:comments[0].body.Contains($root)) "Published image must be hosted, never a local path."
    Assert-True ($script:comments[0].body -like "*ETA unavailable - no positive net completion progress*") "Publication must include an explicit forecast even without completions."
    $script:comments = @()
    $evidence.utc = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString("o")
    $script:restFixtures = @{
        "repos/TestOwner/TestRepo" = $evidence.reads["repos/TestOwner/TestRepo|False|"]
        "repos/TestOwner/TestRepo/issues/448" = $evidence.reads["repos/TestOwner/TestRepo/issues/448|False|"]
        "repos/TestOwner/TestRepo/issues/448/sub_issues?per_page=100" = $evidence.reads["repos/TestOwner/TestRepo/issues/448/sub_issues?per_page=100|True|"]
    }
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $evidencePath
    $afterLongCycle = Publish-EpicChart $evidencePath "UTC" $root
    Assert-True ($afterLongCycle.status -eq "published" -and $script:freshReads -eq 3) "Final-step reporting refreshes only reporting inventory after long coordination."
    Write-Host "Epic chart tests passed."
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
