$ErrorActionPreference = "Stop"

function Get-EpicChartMarker([int] $Epic, [ValidateSet("pending", "published")] [string] $Status) {
    "<!-- fingvibe:epic-chart=v1 epic=$Epic status=$Status -->"
}

function Test-EpicChartDue($Comments, [int] $Epic, [DateTimeOffset] $Now) {
    $pending = Get-EpicChartMarker $Epic pending
    $published = Get-EpicChartMarker $Epic published
    foreach ($comment in $Comments) {
        if ("$($comment.body)".Contains($pending)) {
            throw "Uncertain chart publication requires human reconciliation: $($comment.url)"
        }
    }
    $latest = @($Comments | Where-Object { "$($_.body)".Contains($published) } |
        Sort-Object { [DateTimeOffset] $_.updatedAt } -Descending | Select-Object -First 1)
    if (-not $latest.Count) { return $true }
    if (-not $latest[0].updatedAt) { throw "Missing chart publication timestamp." }
    $elapsed = $Now - [DateTimeOffset] $latest[0].updatedAt
    if ($elapsed.TotalSeconds -lt 0) { throw "Chart publication timestamp is in the future; check clock." }
    $elapsed.TotalMinutes -ge 60
}

function Get-EpicChartSnapshots($Children, [hashtable] $Histories, [DateTimeOffset] $Created,
    [DateTimeOffset] $Now, [TimeZoneInfo] $TimeZone) {
    if ($Now -lt $Created -or -not @($Children).Count) { throw "Invalid Epic reporting interval or empty child cohort." }
    $warnings = [Collections.Generic.List[string]]::new()
    $records = @(foreach ($child in $Children) {
        $number = [int] $child.number
        if ($child.state -notin @("open", "closed")) { throw "Missing or invalid issue state for #$number." }
        if (-not $Histories.ContainsKey($number)) { throw "Missing lifecycle history for #$number." }
        $events = @($Histories[$number] | Where-Object {
            $_.event -in @("closed", "reopened") -or
            ($_.event -eq "labeled" -and $_.label.name -in @("active", "status:review"))
        } | Sort-Object { [DateTimeOffset] $_.created_at })
        if (@($events | Where-Object { -not $_.created_at }).Count) { throw "Missing lifecycle timestamp for #$number." }
        if (@($events | Where-Object { [DateTimeOffset] $_.created_at -gt $Now }).Count) {
            throw "Lifecycle changed during collection for #$number; collect a fresh packet."
        }
        $started = @($events | Where-Object event -EQ labeled)
        $stateEvents = @($events | Where-Object { $_.event -in @("closed", "reopened") })
        $closed = $stateEvents.Count -gt 0 -and $stateEvents[-1].event -eq "closed"
        if ($closed -ne ($child.state -eq "closed")) { throw "Inconsistent closure history for #$number." }
        foreach ($closure in @($stateEvents | Where-Object event -EQ closed)) {
            $reason = $closure.state_reason
            if (-not $reason -and $closed -and $closure -eq $stateEvents[-1]) { $reason = $child.state_reason }
            if (-not $reason) { throw "Historical closure reason is unavailable for #$number; reconcile evidence." }
            if ($reason -ne "completed") { throw "Non-completed closure for #$number cannot be represented as completed." }
        }
        if (-not $started.Count -and ($closed -or
            @($child.labels | Where-Object { $_.name -in @("active", "status:review") }).Count)) {
            throw "Missing start evidence for #$number; historical status is unavailable."
        }
        if (-not $child.created_at) { throw "Missing creation timestamp for #$number." }
        if ([DateTimeOffset] $child.created_at -gt $Created) {
            $warnings.Add("#$number was created after the Epic; earlier snapshots include it as not started.")
        }
        @{ number = $number; events = $events }
    })
    $localNow = [TimeZoneInfo]::ConvertTime($Now, $TimeZone)
    # Walk UTC hours from the current local-hour boundary to preserve repeated DST hours.
    $boundary = $Now.AddTicks(-($localNow.Minute * [TimeSpan]::TicksPerMinute +
        $localNow.Second * [TimeSpan]::TicksPerSecond + $localNow.Ticks % [TimeSpan]::TicksPerSecond))
    $times = [Collections.Generic.List[DateTimeOffset]]::new()
    for ($i = 23; $i -ge 0; $i--) {
        $at = $boundary.AddHours(-$i)
        if ($at -ge $Created -and $at -lt $Now) { $times.Add($at) }
    }
    $times.Add($Now)
    $forecastStart = if ($Created -gt $Now.AddHours(-24)) { $Created } else { $Now.AddHours(-24) }
    # Evaluate the exact forecast baseline separately from the rendered hourly boundaries.
    $evaluated = @(foreach ($at in (@($forecastStart) + $times.ToArray())) {
        $completed = 0; $progress = 0
        foreach ($record in $records) {
            $started = $false; $closed = $false
            foreach ($event in $record.events) {
                if ([DateTimeOffset] $event.created_at -gt $at) { break }
                switch ($event.event) {
                    labeled { $started = $true }
                    closed { $closed = $true }
                    reopened { $closed = $false; $started = $true }
                }
            }
            if ($closed) { $completed++ } elseif ($started) { $progress++ }
        }
        @{
            at = $at.ToUniversalTime().ToString("o")
            label = [TimeZoneInfo]::ConvertTime($at, $TimeZone).ToString("MM-dd`nHH:mm`nzzz")
            completed = $completed; inProgress = $progress; notStarted = $records.Count - $completed - $progress
            total = $records.Count
        }
    })
    $snapshots = @($evaluated | Select-Object -Skip 1)
    $last = $snapshots[-1]
    $hours = ($Now - $forecastStart).TotalHours
    $gain = $last.completed - $evaluated[0].completed
    $forecast = @{
        status = "unavailable"; windowHours = $hours; netCompleted = $gain
        remaining = $last.total - $last.completed
    }
    if ($forecast.remaining -eq 0) {
        $forecast.status = "completed"
    } elseif ($hours -gt 0 -and $gain -gt 0) {
        $forecast.rate = $gain / $hours
        $remainingTicks = [decimal] ($Now - $forecastStart).Ticks * $forecast.remaining / $gain
        $forecast.remainingHours = [double] ($remainingTicks / [TimeSpan]::TicksPerHour)
        if ($remainingTicks -le ([DateTimeOffset]::MaxValue - $Now).Ticks) {
            $forecast.finishAt = $Now.AddTicks([long] [Math]::Round($remainingTicks, 0,
                [MidpointRounding]::AwayFromZero)).ToUniversalTime().ToString("o")
            $forecast.status = "estimated"
        } else {
            $forecast.reason = "projected finish exceeds the supported date range"
        }
    } else {
        $forecast.reason = if ($hours -le 0) { "no elapsed observation time" } else { "no positive net completion progress" }
    }
    @{ snapshots = $snapshots; warnings = @($warnings); timeZone = $TimeZone.Id; forecast = $forecast }
}

function Format-EpicChartForecast($Report) {
    $forecast = $Report.forecast
    if ($forecast.status -eq "completed") { return "**Estimated finish:** All tasks completed." }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $window = $forecast.windowHours.ToString("0.##", $culture)
    $basis = "$($forecast.netCompleted) net completed over $window elapsed hours (including idle time)"
    if ($forecast.status -eq "unavailable") {
        return "**Estimated finish:** ETA unavailable - $($forecast.reason). Observed $basis."
    }
    $finishUtc = [DateTimeOffset] $forecast.finishAt
    $interval = 5 * [TimeSpan]::TicksPerMinute
    $remainder = $finishUtc.Ticks % $interval
    $roundedFinish = $finishUtc.AddTicks(-$remainder)
    if ($remainder -ge $interval / 2) { $roundedFinish = $roundedFinish.AddMinutes(5) }
    $finish = [TimeZoneInfo]::ConvertTime($roundedFinish,
        [TimeZoneInfo]::FindSystemTimeZoneById($Report.timeZone)).ToString("yyyy-MM-dd HH:mm zzz")
    $remainingTicks = ($finishUtc - [DateTimeOffset] $Report.snapshots[-1].at).Ticks
    $minutes = [long] (5 * [Math]::Round(([decimal] $remainingTicks / $interval), 0, [MidpointRounding]::AwayFromZero))
    $remaining = "$([Math]::Floor($minutes / 60))h $($minutes % 60)m"
    $rate = $forecast.rate.ToString("0.##", $culture)
    "**Estimated finish:** ~$finish | ~$remaining remaining ($($forecast.remaining) tasks), rounded to 5 minutes. Based on $rate tasks/hour; $basis. Assumes equally weighted tasks, steady pace and unchanged scope; not a deadline guarantee."
}

function Save-EpicChart($Report, [int] $Epic, [string] $Path) {
    if (-not $IsWindows) { throw "Chart rendering requires local Windows System.Drawing." }
    Add-Type -AssemblyName System.Drawing
    $rows = @($Report.snapshots)
    if (-not $rows.Count) { throw "No chart snapshots." }
    $width = [Math]::Max(1200, 100 + 105 * $rows.Count)
    $height = 720; $left = 65; $right = $width - 40; $bottom = 570; $top = 180
    $step = ($right - $left) / $rows.Count; $barWidth = [Math]::Min(68, $step * 0.65)
    $total = [int] $rows[-1].total
    if ($total -le 0) { throw "Positive task total required." }
    $scale = ($bottom - $top) / $total
    $resources = [Collections.Generic.List[IDisposable]]::new()
    function Own($Resource) { $resources.Add($Resource); $Resource }
    $bitmap = Own ([Drawing.Bitmap]::new($width, $height))
    $g = Own ([Drawing.Graphics]::FromImage($bitmap))
    try {
        $g.SmoothingMode = "AntiAlias"
        $background = [Drawing.ColorTranslator]::FromHtml("#17191c")
        $g.Clear($background)
        $font = Own ([Drawing.Font]::new("Segoe UI", 11))
        $title = Own ([Drawing.Font]::new("Segoe UI", 20, [Drawing.FontStyle]::Bold))
        $white = Own ([Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml("#e5e7eb")))
        $muted = Own ([Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml("#aeb5bf")))
        $colors = @("#22c55e", "#f59e0b", "#ef4444")
        $brushes = @($colors | ForEach-Object { Own ([Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($_))) })
        $grid = Own ([Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml("#34383e"), 1))
        $totalPen = Own ([Drawing.Pen]::new($muted.Color, 2)); $totalPen.DashStyle = "Dash"
        $center = Own ([Drawing.StringFormat]::new()); $center.Alignment = "Center"; $center.LineAlignment = "Center"
        $now = [TimeZoneInfo]::ConvertTime([DateTimeOffset] $rows[-1].at, [TimeZoneInfo]::FindSystemTimeZoneById($Report.timeZone))
        $g.DrawString("Epic $Epic - hourly task status", $title, $white, 45, 20)
        $g.DrawString("Snapshot: $($now.ToString('yyyy-MM-dd HH:mm zzz')) | $($Report.timeZone)", $font, $muted, 47, 65)
        $names = @("Completed", "In progress (including CI/review)", "Not started")
        $positions = @(50, 230, 565)
        for ($j = 0; $j -lt 3; $j++) {
            $g.FillRectangle($brushes[$j], $positions[$j], 111, 17, 17)
            $g.DrawString($names[$j], $font, $white, ($positions[$j] + 25), 106)
        }
        $g.DrawLine($totalPen, 760, 120, 790, 120)
        $g.DrawString("Total: $total", $font, $muted, 800, 107)
        $tickStep = [Math]::Max(1, [int] [Math]::Ceiling($total / 8.0))
        for ($n = 0; $n -le $total; $n += $tickStep) {
            $y = [single] ($bottom - $n * $scale)
            $g.DrawLine($grid, $left, $y, $right, $y)
            $g.DrawString("$n", $font, $muted, 22, ($y - 10))
        }
        $g.DrawLine($totalPen, $left, $top, $right, $top)
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $rows[$i]; $x = [single] ($left + $step * ($i + 0.5) - $barWidth / 2)
            $y = [single] $bottom
            $counts = @($row.completed, $row.inProgress, $row.notStarted)
            for ($j = 0; $j -lt 3; $j++) {
                $h = [single] ($counts[$j] * $scale); $y -= $h
                if ($h -le 0) { continue }
                $g.FillRectangle($brushes[$j], $x, $y, [single] $barWidth, $h)
                if ($h -ge 20) {
                    $g.DrawString("$($counts[$j])", $font, [Drawing.Brushes]::Black,
                        [Drawing.RectangleF]::new($x, $y, $barWidth, $h), $center)
                }
            }
            $g.DrawString($row.label, $font, $white,
                [Drawing.RectangleF]::new(($x - 18), ($bottom + 7), ($barWidth + 36), 70), $center)
        }
        $halo = Own ([Drawing.Pen]::new($background, 7))
        for ($j = 0; $j -lt 3; $j++) {
            $pen = Own ([Drawing.Pen]::new($brushes[$j].Color, 3))
            $points = [Drawing.PointF[]] @(for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                $value = switch ($j) { 0 { $row.completed }; 1 { $row.completed + $row.inProgress }; 2 { $row.total } }
                [Drawing.PointF]::new(($left + $step * ($i + 0.5)), ($bottom - $value * $scale))
            })
            if ($points.Count -gt 1) { $g.DrawLines($halo, $points); $g.DrawLines($pen, $points) }
            foreach ($point in $points) {
                $g.FillEllipse($brushes[$j], ($point.X - 4), ($point.Y - 4), 8, 8)
                $g.DrawEllipse([Drawing.Pens]::White, ($point.X - 4), ($point.Y - 4), 8, 8)
            }
        }
        $g.DrawString("Lines follow cumulative stack tops. Current child cohort; latest 24 hourly snapshots + current partial hour.",
            $font, $muted, 45, 663)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        for ($i = $resources.Count - 1; $i -ge 0; $i--) { $resources[$i].Dispose() }
    }
}

Export-ModuleMember -Function Get-EpicChartMarker, Test-EpicChartDue, Get-EpicChartSnapshots, Format-EpicChartForecast, Save-EpicChart
