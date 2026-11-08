function New-DeviceActivityFixture([string] $Directory) {
    $today = [DateTime]::Today
    $yesterday = $today.AddDays(-1)
    $history = [Collections.Generic.List[object]]::new()
    function Add-ActivitySample([DateTime] $Time, [bool] $Present) {
        $history.Add(@{
            completedAt = ([DateTimeOffset]$Time).ToString("o")
            networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = $Present
        })
    }
    Add-ActivitySample $today.AddDays(-40).AddHours(9) $true
    $wednesdays = @(-29..-1 | ForEach-Object { $today.AddDays($_) } | Where-Object DayOfWeek -eq Wednesday)
    foreach ($day in @($wednesdays | Select-Object -First 3)) { Add-ActivitySample $day.AddHours(9) $true }
    Add-ActivitySample $yesterday.AddHours(11) $true
    Add-ActivitySample $yesterday.AddHours(11).AddMinutes(20) $false
    Add-ActivitySample $yesterday.AddHours(11).AddMinutes(40) $false
    Add-ActivitySample $yesterday.AddHours(12) $false
    $first = ([DateTimeOffset]$today.AddDays(-40)).ToString("o")
    $last = ([DateTimeOffset]$yesterday.AddHours(12)).ToString("o")
    $observation = @{
        networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = "127.0.0.1"
        hostname = "activity-laptop"; vendor = "Example"; ports = @(); latency = 1; probeDuration = "00:00:00.001"
        classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Fixture"; operatingSystemEvidence = "Fixture" }
        firstSeen = $first; lastSeen = $last; lastChecked = $last; present = $false
    }
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "001122334455" = @{ mac = "001122334455"; imported = @{}; observations = @($observation); scanHistory = @($history) }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "Activity imported" }; observations = @(); scanHistory = @() }
        }
        names = @{ "001122334455" = "Activity laptop" }; classifications = @{}
        peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @(); discoveryBaselines = @()
    }
    @{ version = 4; data = $data } | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath (Join-Path $Directory "inventory.json") -Encoding utf8
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = $last; results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory "snapshot.json") -Encoding utf8
}
