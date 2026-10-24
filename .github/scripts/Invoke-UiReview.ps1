[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory,

    [string] $CapturePlanPath,

    [string] $WinAppDriverPath =
        "${env:ProgramFiles(x86)}\Windows Application Driver\WinAppDriver.exe"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")
. (Join-Path $PSScriptRoot "UiReviewNavigation.ps1")
$capturePlan = if ($CapturePlanPath) {
    @(Read-UiReviewCapturePlan -Path $CapturePlanPath)
}
else {
    @(Get-UiReviewCapturePlan -RepositoryPath (Get-Location).Path)
}

$serverUrl = "http://127.0.0.1:4723"
$sessionId = $null
$driverProcess = $null
$succeeded = $false
$reviewStartedAt = Get-Date
$logDirectory = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
}
else {
    [System.IO.Path]::GetTempPath()
}
$standardOutputPath = Join-Path $logDirectory "fingvibe-winappdriver.stdout.log"
$standardErrorPath = Join-Path $logDirectory "fingvibe-winappdriver.stderr.log"
$startupLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-ui-review-startup.log"
if (Test-Path -LiteralPath $startupLogPath) {
    Remove-Item -LiteralPath $startupLogPath
}

function Invoke-WebDriverRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Delete", "Get", "Post")]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Endpoint,

        [hashtable] $Body
    )

    $parameters = @{
        Method = $Method
        Uri = "$serverUrl$Endpoint"
        TimeoutSec = 30
    }
    if ($PSBoundParameters.ContainsKey("Body")) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    Invoke-RestMethod @parameters
}

function Get-WebDriverElementId {
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    $w3cElementKey = "element-6066-11e4-a52e-4f735466cecf"
    if ($Response.value.PSObject.Properties.Name -contains $w3cElementKey) {
        return $Response.value.$w3cElementKey
    }
    if ($Response.value.PSObject.Properties.Name -contains "ELEMENT") {
        return $Response.value.ELEMENT
    }

    throw "WinAppDriver returned an element without an identifier."
}

function Find-WebDriverElement {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("name", "xpath")]
        [string] $Using,

        [Parameter(Mandatory)]
        [string] $Value,

        [int] $TimeoutSeconds = 15,

        [switch] $Optional
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebDriverRequest -Method Post `
                -Endpoint "/session/$sessionId/element" `
                -Body @{
                    using = $Using
                    value = $Value
                }
            return Get-WebDriverElementId -Response $response
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                if ($Optional) {
                    return $null
                }

                throw "Could not find UI element '$Value' within $TimeoutSeconds seconds. $($_.Exception.Message)"
            }

            Start-Sleep -Milliseconds 250
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($Optional) {
        return $null
    }

    throw "Could not find UI element '$Value' within $TimeoutSeconds seconds."
}

function Get-WebDriverElementEnabled {
    param(
        [Parameter(Mandatory)]
        [string] $ElementId
    )

    $response = Invoke-WebDriverRequest -Method Get `
        -Endpoint "/session/$sessionId/element/$ElementId/enabled"
    return [bool] $response.value
}

function Invoke-WebDriverElement {
    param(
        [Parameter(Mandatory)]
        [string] $ElementId
    )

    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$ElementId/click" `
        -Body @{ }
}

function Set-UiReviewAssignment {
    param([string] $Category, [string] $Label, [string] $Status)
    $picker = Assert-VisibleUiReviewElement -Using xpath -Value "//ComboBox[@Name='$Category']"
    Invoke-WebDriverElement -ElementId $picker
    $item = Assert-VisibleUiReviewElement -Using xpath -Value "//ListItem[@Name='$Label']"
    Invoke-WebDriverElement -ElementId $item
    $null = Assert-VisibleUiReviewElement -Value $Status
    $selected = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$picker/text"
    if ($selected.value -ne $Label) {
        throw "$Category assignment must remain selected: expected '$Label', got '$($selected.value)'."
    }
}

function Assert-UiReviewText {
    param([string] $ElementId, [string] $Expected)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $text = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$ElementId/text"
        if ($text.value -ceq $Expected) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected text '$Expected', got '$($text.value)'."
}

function Test-UiReviewNameSuggestion {
    param([string] $Category, [string] $FirstWord, [string] $SecondWord, [string] $Initials)
    Show-UiReviewCaptureScenario -Scenario $(if ($Category -eq "Person") { "People" } else { "Rooms" })
    $add = Assert-VisibleUiReviewElement -Using xpath -Value "//Button[@AutomationId='Add${Category}Button']"
    Invoke-WebDriverElement -ElementId $add
    $name = Assert-VisibleUiReviewElement -Value "Full name"
    $shortName = Assert-VisibleUiReviewElement -Value "Short name"
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @($FirstWord) }
    Assert-UiReviewText $shortName $Initials.Substring(0, 1)
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @(" " + $SecondWord.Substring(0, 1)) }
    Assert-UiReviewText $shortName $Initials
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @($SecondWord.Substring(1) + " Third") }
    Assert-UiReviewText $shortName $Initials
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$shortName/clear" -Body @{}
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$shortName/value" `
        -Body @{ value = @("ZZ") }
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @(" Fourth") }
    Assert-UiReviewText $shortName "ZZ"
    $cancel = Assert-VisibleUiReviewElement -Value "Cancel"
    Invoke-WebDriverElement -ElementId $cancel
}

function Assert-StatusFilterSelection {
    param(
        [Parameter(Mandatory)]
        [string] $SelectedId,

        [Parameter(Mandatory)]
        [string] $UnselectedId
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $selected = Invoke-WebDriverRequest -Method Get `
            -Endpoint "/session/$sessionId/element/$SelectedId/selected"
        $unselected = Invoke-WebDriverRequest -Method Get `
            -Endpoint "/session/$sessionId/element/$UnselectedId/selected"
        if ($selected.value -and -not $unselected.value) {
            return
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The All / Alive switch did not preserve mutually exclusive selection (expected selected: $($selected.value), expected unselected: $($unselected.value))."
}

function Assert-StatusFilterLayout {
    param(
        [Parameter(Mandatory)][string] $FilterId,
        [Parameter(Mandatory)][string] $AllId,
        [Parameter(Mandatory)][string] $AliveId,
        [Parameter(Mandatory)][string] $SearchId
    )

    $bounds = @{}
    foreach ($id in @($FilterId, $AllId, $AliveId, $SearchId)) {
        $location = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/location"
        $size = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$id/size"
        $bounds[$id] = @{
            X = $location.value.x
            Y = $location.value.y
            Width = $size.value.width
            Height = $size.value.height
        }
    }

    $filter = $bounds[$FilterId]
    $all = $bounds[$AllId]
    $alive = $bounds[$AliveId]
    $search = $bounds[$SearchId]
    if ([Math]::Abs($all.Width - $alive.Width) -gt 1 -or
        [Math]::Abs($all.Height - $alive.Height) -gt 1 -or
        [Math]::Abs($all.Y - $alive.Y) -gt 1 -or
        $all.X + $all.Width -ge $alive.X -or
        $all.X -le $filter.X -or $all.Y -le $filter.Y -or
        $alive.X + $alive.Width -ge $filter.X + $filter.Width -or
        $alive.Y + $alive.Height -ge $filter.Y + $filter.Height -or
        $search.X + $search.Width -ge $filter.X) {
        throw "The rounded status filter must have equal, separated, inset segments without overlapping search."
    }
}

if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
    throw "The published application was not found at '$AppPath'."
}
if (-not (Test-Path -LiteralPath $WinAppDriverPath -PathType Leaf)) {
    throw "WinAppDriver was not found at '$WinAppDriverPath'."
}

$driverProcess = Start-Process `
    -FilePath $WinAppDriverPath `
    -ArgumentList "127.0.0.1", "4723" `
    -PassThru `
    -RedirectStandardOutput $standardOutputPath `
    -RedirectStandardError $standardErrorPath

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($driverProcess.HasExited) {
            throw "WinAppDriver exited with code $($driverProcess.ExitCode) before accepting connections."
        }

        try {
            $null = Invoke-WebDriverRequest -Method Get -Endpoint "/status"
            break
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "WinAppDriver did not accept connections within 30 seconds."
            }

            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $sessionResponse = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session" `
        -Body @{
            desiredCapabilities = @{
                app = $AppPath
                deviceName = "WindowsPC"
                platformName = "Windows"
            }
        }
    $sessionId = if ($sessionResponse.sessionId) {
        $sessionResponse.sessionId
    }
    else {
        $sessionResponse.value.sessionId
    }
    if (-not $sessionId) {
        throw "WinAppDriver did not return a session identifier."
    }

    $windowResponse = Invoke-WebDriverRequest -Method Get `
        -Endpoint "/session/$sessionId/window_handle"
    $windowHandle = [IntPtr]::new([Convert]::ToInt64([string] $windowResponse.value, 16))
    Initialize-UiReviewWindow -WindowHandle $windowHandle

    $elements = @{}
    foreach ($expectedName in @("FingVibe", "Detected network", "Scan LAN")) {
        $elements[$expectedName] = Find-WebDriverElement -Using name -Value $expectedName
    }

    if (-not (Get-WebDriverElementEnabled -ElementId $elements["Scan LAN"])) {
        throw "The primary 'Scan LAN' action is disabled."
    }

    Invoke-WebDriverElement -ElementId $elements["Scan LAN"]

    $interactionDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $scanEnteredExpectedState = $false
    do {
        if (-not (Get-WebDriverElementEnabled -ElementId $elements["Scan LAN"])) {
            $null = Assert-VisibleUiReviewElement -Value "Cancel"
            $scanEnteredExpectedState = $true
            break
        }

        $completion = Find-WebDriverElement `
            -Using xpath `
            -Value "//*[starts-with(@Name, 'Updated ')]" `
            -TimeoutSeconds 1 `
            -Optional
        if ($completion) {
            $scanEnteredExpectedState = $true
            break
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $interactionDeadline)

    if (-not $scanEnteredExpectedState) {
        throw "Invoking 'Scan LAN' did not enter or complete the expected scanning state."
    }

    $devicesMenuItem = Find-WebDriverElement `
        -Using xpath `
        -Value "//ListItem[@Name='Devices']"
    Invoke-WebDriverElement -ElementId $devicesMenuItem

    $allHosts = Find-WebDriverElement -Using xpath -Value "//List[@Name='Show hosts']/ListItem[@Name='All']"
    $aliveHosts = Find-WebDriverElement -Using xpath -Value "//List[@Name='Show hosts']/ListItem[@Name='Alive']"
    $statusFilter = Find-WebDriverElement -Using name -Value "Show hosts"
    $search = Find-WebDriverElement -Using name -Value "Filter scan results"
    Assert-StatusFilterLayout -FilterId $statusFilter -AllId $allHosts -AliveId $aliveHosts -SearchId $search
    Assert-StatusFilterSelection -SelectedId $allHosts -UnselectedId $aliveHosts
    Invoke-WebDriverElement -ElementId $aliveHosts
    Assert-StatusFilterSelection -SelectedId $aliveHosts -UnselectedId $allHosts
    Invoke-WebDriverElement -ElementId $aliveHosts
    Assert-StatusFilterSelection -SelectedId $aliveHosts -UnselectedId $allHosts

    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$aliveHosts/value" `
        -Body @{ value = @([string] [char] 0xE012) }
    Assert-StatusFilterSelection -SelectedId $allHosts -UnselectedId $aliveHosts
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$allHosts/value" `
        -Body @{ value = @([string] [char] 0xE014) }
    Assert-StatusFilterSelection -SelectedId $aliveHosts -UnselectedId $allHosts

    $result = Find-WebDriverElement `
        -Using xpath `
        -Value "//*[@Name='Online' or @Name='Offline']" `
        -TimeoutSeconds 30 `
        -Optional
    if (-not $result) {
        throw "The scan did not render a result with an accessible Online or Offline badge."
    }

    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/value" `
        -Body @{ value = @("fingvibe-no-matching-host") }
    $null = Find-WebDriverElement -Using name -Value "No hosts match the current filter."
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/clear" `
        -Body @{ }
    $null = Find-WebDriverElement -Using xpath -Value "//*[@Name='Online']"
    Assert-StatusFilterSelection -SelectedId $aliveHosts -UnselectedId $allHosts

    $scanStoppedDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Get-WebDriverElementEnabled -ElementId $elements["Scan LAN"])) {
        if ([DateTime]::UtcNow -ge $scanStoppedDeadline) {
            throw "The scan did not complete within 60 seconds before capturing the required views."
        }
        Start-Sleep -Milliseconds 100
    }

    # Summary navigation must replace stale filters and leave its port filter visible and reversible.
    $portsFilter = Assert-VisibleUiReviewElement -Value "Only devices with open ports"
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/value" `
        -Body @{ value = @("fingvibe-no-matching-host") }
    $overview = Find-WebDriverElement -Using xpath -Value "//ListItem[@Name='Overview']"
    Invoke-WebDriverElement -ElementId $overview
    $portsCard = Assert-VisibleUiReviewElement -Value "See devices with open ports"
    Invoke-WebDriverElement -ElementId $portsCard
    Assert-StatusFilterSelection -SelectedId $allHosts -UnselectedId $aliveHosts
    $checked = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$portsFilter/selected"
    if (-not $checked.value) { throw "The open-port summary did not enable the visible port filter." }
    $searchValue = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$search/text"
    if ($searchValue.value) { throw "Summary navigation did not clear the stale text filter." }

    Invoke-WebDriverElement -ElementId $overview
    $onlineCard = Assert-VisibleUiReviewElement -Value "See online devices"
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$onlineCard/value" `
        -Body @{ value = @([string] [char] 0xE007) }
    $null = Assert-VisibleUiReviewElement -Value "Only devices with open ports"
    Assert-StatusFilterSelection -SelectedId $aliveHosts -UnselectedId $allHosts
    $checked = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$portsFilter/selected"
    if ($checked.value) { throw "The online summary retained a stale port filter." }
    $null = Assert-VisibleUiReviewElement -Value "Online"

    $captureDirectory = [System.IO.Path]::GetFullPath($ScreenshotDirectory)
    $null = New-Item -ItemType Directory -Path $captureDirectory -Force
    foreach ($capture in $capturePlan) {
        Write-Host "Capturing $($capture.Label): $($capture.Reasons -join ' ')"
        try {
            Show-UiReviewCaptureScenario -Scenario $capture.Scenario
            $path = Join-Path $captureDirectory $capture.FileName
            Save-UiReviewWindowScreenshot -WindowHandle $windowHandle -Path $path
        }
        catch {
            throw "Required capture '$($capture.Label)' failed: $($_.Exception.Message)"
        }
    }
    Test-UiReviewNameSuggestion "Person" "Igor" "Iric" "II"
    Test-UiReviewNameSuggestion "Room" "Living" "Room" "LR"
    Write-Host "People and Rooms native short-name suggestion regression tests passed."
    Show-UiReviewCaptureScenario -Scenario "DeviceDetails"
    Set-UiReviewAssignment "Room" "UI · UI review room" "Room assignment saved."
    Set-UiReviewAssignment "Person" "UI · UI review person" "Person assignment saved."
    Set-UiReviewAssignment "Room" "Unassigned" "Room assignment saved."
    Set-UiReviewAssignment "Person" "Unassigned" "Person assignment saved."
    Write-Host "People and Rooms native assignment regression tests passed."

    # Publish a manifest only after every required view/state was verified and captured.
    ConvertTo-Json -InputObject @($capturePlan) -Depth 5 |
        Set-Content -LiteralPath (Join-Path $captureDirectory "capture-manifest.json") -Encoding utf8

    $succeeded = $true
}
finally {
    if ($sessionId) {
        try {
            $null = Invoke-WebDriverRequest -Method Delete -Endpoint "/session/$sessionId"
        }
        catch {
            Write-Warning "Could not close the WinAppDriver session: $($_.Exception.Message)"
        }
    }

    if ($driverProcess -and -not $driverProcess.HasExited) {
        Stop-Process -Id $driverProcess.Id
        $null = $driverProcess.WaitForExit(10000)
    }

    if (-not $succeeded) {
        if (Test-Path -LiteralPath $startupLogPath) {
            Get-Content -LiteralPath $startupLogPath | Write-Host
        }
        try {
            Get-WinEvent -FilterHashtable @{
                LogName = "Application"
                ProviderName = @(".NET Runtime", "Application Error")
                StartTime = $reviewStartedAt
            } -ErrorAction Stop |
                Where-Object { $_.Message -like "*FingVibe.App*" } |
                ForEach-Object { Write-Host $_.Message }
        }
        catch {
            Write-Warning "No application crash events were available: $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $standardOutputPath) {
            Get-Content -LiteralPath $standardOutputPath | Write-Host
        }
        if (Test-Path -LiteralPath $standardErrorPath) {
            Get-Content -LiteralPath $standardErrorPath | Write-Host
        }
    }
}

Write-Host "UI smoke test passed and $($capturePlan.Count) required screenshot(s) captured."
