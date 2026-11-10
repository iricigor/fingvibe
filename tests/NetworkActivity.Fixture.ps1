function New-NetworkActivityFixture([string] $Directory, [switch] $Empty, [switch] $Equipment) {
    $today = [DateTime]::Today
    $yesterday = $today.AddDays(-1)
    $first = $today.AddDays(-40).AddHours(9)
    $room = "00000000-0000-0000-0000-000000000001"
    $scans = [Collections.Generic.List[object]]::new()
    foreach ($hour in @(12, 12.5, 13, 14)) {
        $scans.Add(@{ Time = $yesterday.AddHours($hour); Id = [Guid]::NewGuid().ToString(); Hour = $hour })
    }
    $wednesdays = @(-29..-1 | ForEach-Object { $today.AddDays($_) } | Where-Object DayOfWeek -eq Wednesday | Select-Object -First 3)
    for ($index = 0; $index -lt $wednesdays.Count; $index++) {
        $scans.Add(@{ Time = $wednesdays[$index].AddHours(9); Id = [Guid]::NewGuid().ToString(); Count = 10 + 2 * $index })
    }
    if ($Equipment) {
        $scans.Add(@{ Time = $yesterday.AddHours(16); Id = [Guid]::NewGuid().ToString(); Hour = 16 })
        for ($index = 0; $index -lt 2; $index++) {
            $scans.Add(@{ Time = $wednesdays[$index].AddHours(10); Id = [Guid]::NewGuid().ToString(); Count = 1 + $index })
        }
    }
    $devices = @{}
    for ($index = 0; $index -lt 1000; $index++) {
        $mac = "001122{0:X6}" -f $index
        $history = [Collections.Generic.List[object]]::new()
        if (-not $Empty) {
            $history.Add(@{ completedAt = ([DateTimeOffset]$first).ToString("o"); networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = $true })
            foreach ($scan in $scans) {
                if ($scan.Hour -eq 14 -and $index -eq 999) { continue }
                $present = if ($scan.ContainsKey("Count")) { $index -lt $scan.Count }
                    elseif ($scan.Hour -eq 12) { $index -in @(0, 1) }
                    elseif ($scan.Hour -eq 12.5) { $index -in @(1, 2) }
                    elseif ($scan.Hour -in @(14, 16)) { $index -lt 2 }
                    else { $false }
                $history.Add(@{ completedAt = ([DateTimeOffset]$scan.Time).ToString("o"); networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = $present })
            }
        }
        $observation = @{
            networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = "127.0.0.1"
            hostname = "network-$index"; vendor = "Example"; ports = @(); latency = 1; probeDuration = "00:00:00.001"
            classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Fixture"; operatingSystemEvidence = "Fixture" }
            firstSeen = ([DateTimeOffset]$first).ToString("o"); lastSeen = ([DateTimeOffset]$first).ToString("o")
            lastChecked = ([DateTimeOffset]$yesterday.AddHours(14)).ToString("o"); present = $false
        }
        $devices[$mac] = @{ mac = $mac; imported = @{}; observations = @($observation); scanHistory = @($history) }
    }
    $devices["001122000000"].usageCategoryOverride = 1
    $devices["001122000001"].usageCategoryOverride = 3
    $data = @{
        revision = [Guid]::NewGuid().ToString(); devices = $devices
        names = @{}; classifications = @{ "001122000000" = @{ type = 1 }; "001122000001" = @{ type = 2 } }
        peopleRooms = @{ people = @(); rooms = @(@{ id = $room; name = "Office"; shortName = "OFF" })
            assignments = @{ "001122000000" = @{ roomId = $room }; "001122000001" = @{ roomId = $room } } }
        virtualDevices = @(); discoveryBaselines = @()
    }
    if ($Equipment) {
        $person = "00000000-0000-0000-0000-000000000241"
        $data.peopleRooms.people = @(
            @{ id = $person; name = "Equipment person"; shortName = "EP" },
            @{ id = "00000000-0000-0000-0000-000000000242"; name = "No equipment"; shortName = "NE" })
        foreach ($index in @(0, 1, 999)) {
            $mac = "001122{0:X6}" -f $index
            if (-not $data.peopleRooms.assignments.ContainsKey($mac)) { $data.peopleRooms.assignments[$mac] = @{} }
            $data.peopleRooms.assignments[$mac].personId = $person
        }
    }
    @{ version = 4; data = $data } | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath (Join-Path $Directory "inventory.json") -Encoding utf8
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = ([DateTimeOffset]$yesterday.AddHours(14)).ToString("o"); results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory "snapshot.json") -Encoding utf8
    $database = Join-Path $Directory "inventory.sqlite"
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new($database)
    $null = $store.LoadMetadataAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($Empty) { return }
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    try {
        $connection.Open()
        foreach ($scan in $scans) {
            $command = $connection.CreateCommand()
            try {
                $command.CommandText = @"
INSERT INTO scan_evidence(scan_id,network_id,subnet,completed_at,completed_ticks,state,unidentified_responses)
VALUES(`$id,'ui-review-network','127.0.0.1/32',`$time,`$ticks,0,0);
UPDATE scan_history SET scan_id=`$id WHERE completed_ticks=`$ticks;
"@
                $null = $command.Parameters.AddWithValue('$id', $scan.Id)
                $null = $command.Parameters.AddWithValue('$time', ([DateTimeOffset]$scan.Time).ToString("o"))
                $null = $command.Parameters.AddWithValue('$ticks', ([DateTimeOffset]$scan.Time).UtcTicks)
                $null = $command.ExecuteNonQuery()
            } finally { $command.Dispose() }
        }
    } finally { $connection.Dispose() }
}
