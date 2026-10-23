function Assert-VisibleUiReviewElement {
    param([string] $Using = "name", [Parameter(Mandatory)][string] $Value)
    $id = Find-WebDriverElement -Using $Using -Value $Value
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $response = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/displayed"
        if ($response.value) { return $id }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $response.value) {
        throw "Required capture control '$Value' is not visible."
    }
}

function Show-UiReviewCaptureScenario {
    param([Parameter(Mandatory)][string] $Scenario)
    $menu = switch ($Scenario) {
        "DeviceDetails" { "Devices" }
        "DevicesEmpty" { "Devices" }
        default { $Scenario }
    }
    $menuId = Assert-VisibleUiReviewElement -Using xpath -Value "//ListItem[@Name='$menu']"
    Invoke-WebDriverElement -ElementId $menuId
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $selected = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$menuId/selected"
        if ($selected.value) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $selected.value) { throw "Navigation did not select '$menu'." }

    if ($menu -eq "Devices") {
        $searchId = Assert-VisibleUiReviewElement -Value "Filter scan results"
        $null = Invoke-WebDriverRequest -Method Post `
            -Endpoint "/session/$sessionId/element/$searchId/clear" -Body @{}
        $null = Assert-VisibleUiReviewElement -Value "Online"
        if ($Scenario -eq "DeviceDetails") {
            $rowId = Assert-VisibleUiReviewElement -Using xpath `
                -Value "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]"
            Invoke-WebDriverElement -ElementId $rowId
            $null = Assert-VisibleUiReviewElement -Value "Back to devices"
            $null = Assert-VisibleUiReviewElement -Value "Device name"
            $null = Assert-VisibleUiReviewElement -Value "Scan additional ports"
        }
        elseif ($Scenario -eq "DevicesEmpty") {
            $null = Invoke-WebDriverRequest -Method Post `
                -Endpoint "/session/$sessionId/element/$searchId/value" `
                -Body @{ value = @("fingvibe-no-matching-host") }
            $null = Assert-VisibleUiReviewElement -Value "No hosts match the current filter."
        }
        return
    }

    $sentinel = switch ($Scenario) {
        "Overview" { "Online devices" }
        "Network" { "Public IP address" }
        "People" { "Search people" }
        "Rooms" { "Search rooms" }
        "Settings" { "Window backdrop" }
        default { throw "No navigation is implemented for capture scenario '$Scenario'." }
    }
    $null = Assert-VisibleUiReviewElement -Value $sentinel
}
