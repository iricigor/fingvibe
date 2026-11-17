# Fixture phase: inventory, snapshot and review environment.
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "history/fixture" $ScreenshotDirectory
    $history = @(0..4 | ForEach-Object {
        @{ completedAt = "2026-11-01T12:0${_}:00+00:00"; networkId = "ui-review-network"
           subnet = "127.0.0.1/32"; present = ($_ -notin @(2, 3)) }
    })
    function New-HistoryObservation([string] $Address, [bool] $Present, [string] $Vendor) {
        @{ networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = $Address
           hostname = $null; vendor = $Vendor; ports = @(); latency = 1; probeDuration = "00:00:00.001"
           classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Synthetic fixture"; operatingSystemEvidence = "Synthetic fixture" }
           firstSeen = "2026-11-01T12:00:00+00:00"; lastSeen = "2026-11-01T12:04:00+00:00"
           lastChecked = "2026-11-01T12:04:00+00:00"; present = $Present }
    }
    $old = New-HistoryObservation "127.0.0.1" $false "Private"
    $current = New-HistoryObservation "127.0.0.1" $true "Private"
    $normal = New-HistoryObservation "127.0.0.1" $true "Example"
    $legacy = New-HistoryObservation "127.0.0.1" $true "Example"
    $unmatched = New-HistoryObservation "127.0.0.1" $true "Example"
    $unmatched.networkId = "another-network"
    $decoyHistory = @(
        @{ completedAt = "2026-10-01T12:00:00+00:00"; networkId = "another-network"; subnet = "127.0.0.1/32"; present = $true },
        @{ completedAt = "2026-11-02T12:00:00+00:00"; networkId = "ui-review-network"; subnet = "192.0.2.0/24"; present = $false }
    )
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "020000000001" = @{ mac = "020000000001"; imported = @{ name = "History normal" }
                observations = @($normal, $unmatched); scanHistory = $history + $decoyHistory }
            "D0C907000001" = @{ mac = "D0C907000001"; imported = @{}; observations = @($old); scanHistory = @() }
            "D0C907000002" = @{ mac = "D0C907000002"; imported = @{}; observations = @($current); scanHistory = @() }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "History imported" }; observations = @(); scanHistory = @() }
            "001122334477" = @{ mac = "001122334477"; imported = @{ name = "History legacy" }; observations = @($legacy); scanHistory = @() }
            "001122334488" = @{ mac = "001122334488"; imported = @{ name = "History unmatched" }; observations = @($unmatched); scanHistory = $decoyHistory }
        }
        names = @{}; classifications = @{}; peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @(@{
            id = [Guid]::NewGuid().ToString(); networkId = "ui-review-network"; subnet = "127.0.0.1/32"
            prefix = "D0C907"; number = 1; lastActiveMac = "D0C907000002"; lastChecked = "2026-11-01T12:04:00+00:00"
            present = $true; name = "History virtual"; scanHistory = $history
            history = @(@{ mac = "D0C907000001"; observation = $old; inferred = $true },
                @{ mac = "D0C907000002"; observation = $current; inferred = $true })
        })
    }
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = "2026-11-01T12:04:00+00:00"; results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding UTF8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $hold
