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
. (Join-Path $PSScriptRoot "UiReviewDeviceTabs.ps1")
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
$logDirectory = [System.IO.Path]::GetFullPath($ScreenshotDirectory)
$null = New-Item -ItemType Directory -Path $logDirectory -Force
$standardOutputPath = Join-Path $logDirectory "fingvibe-winappdriver.stdout.log"
$standardErrorPath = Join-Path $logDirectory "fingvibe-winappdriver.stderr.log"
$startupLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-ui-review-startup.log"
$savedScanHold = $env:FINGVIBE_UI_REVIEW_SCAN_HOLD
$scanHoldPath = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-smoke-refresh-$([Guid]::NewGuid().ToString('N')).hold"
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

function Wait-UiReviewScan {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $scan = Find-WebDriverElement -Using name -Value "Scan LAN" -TimeoutSeconds 1 -Optional
        if ($scan -and (Get-WebDriverElementEnabled -ElementId $scan)) { return $scan }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The scan did not restore its idle action within 60 seconds."
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
    $picker = Show-UiReviewAssignmentPicker $Category
    Invoke-WebDriverElement -ElementId $picker
    $item = Assert-VisibleUiReviewElement -Using xpath -Value "//ListItem[@Name='$Label']"
    Invoke-WebDriverElement -ElementId $item
    # The aligned feedback line sits at the bottom of the tall Assignments card, below the first viewport.
    $null = Show-UiReviewDetailsControl -Value $Status
    Assert-UiReviewAssignment $Category $Label
}

function Assert-UiReviewAssignment {
    param([string] $Category, [string] $Label)
    $picker = Show-UiReviewAssignmentPicker $Category
    Invoke-WebDriverElement -ElementId $picker
    $item = Assert-VisibleUiReviewElement -Using xpath -Value "//ListItem[@Name='$Label']"
    $selected = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$item/selected"
    if (-not $selected.value) {
        throw "$Category assignment '$Label' did not remain selected."
    }
    Invoke-WebDriverElement -ElementId $picker
}

function Show-UiReviewAssignmentPicker {
    param([string] $Category)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    Select-UiReviewDeviceTab -Root $root -Tab Overview
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $Category),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ComboBox)))
    if (-not $element) { throw "Missing $Category assignment picker." }
    $element.SetFocus()
    $viewport = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceDetailsScroll"))
    if (-not $viewport) { throw "Missing Overview viewport for $Category assignment." }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $bounds = $element.Current.BoundingRectangle
        $area = $viewport.Current.BoundingRectangle
        if (-not $element.Current.IsOffscreen -and $bounds.Width -gt 0 -and $area.Contains($bounds) -and
            $root.Current.BoundingRectangle.Contains($bounds)) {
            return Assert-VisibleUiReviewElement -Using xpath -Value "//ComboBox[@Name='$Category']"
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Category assignment picker did not fit the physical window after keyboard focus."
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
    Invoke-WebDriverElement -ElementId $name
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @($FirstWord) }
    Assert-UiReviewText $name $FirstWord
    Assert-UiReviewText $shortName $Initials.Substring(0, 1)
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @(" " + $SecondWord.Substring(0, 1)) }
    Assert-UiReviewText $name ($FirstWord + " " + $SecondWord.Substring(0, 1))
    Assert-UiReviewText $shortName $Initials
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @($SecondWord.Substring(1) + " Third") }
    Assert-UiReviewText $name "$FirstWord $SecondWord Third"
    Assert-UiReviewText $shortName $Initials
    Invoke-WebDriverElement -ElementId $shortName
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$shortName/clear" -Body @{}
    Assert-UiReviewText $shortName ""
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$shortName/value" `
        -Body @{ value = @("ZZ") }
    Assert-UiReviewText $shortName "ZZ"
    Invoke-WebDriverElement -ElementId $name
    $null = Invoke-WebDriverRequest -Method Post -Endpoint "/session/$sessionId/element/$name/value" `
        -Body @{ value = @([string] [char] 0xE010, " Fourth") }
    Assert-UiReviewText $name "$FirstWord $SecondWord Third Fourth"
    Assert-UiReviewText $shortName "ZZ"
    $cancel = Assert-VisibleUiReviewElement -Value "Cancel"
    Invoke-WebDriverElement -ElementId $cancel
}

if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
    throw "The published application was not found at '$AppPath'."
}
if (-not (Test-Path -LiteralPath $WinAppDriverPath -PathType Leaf)) {
    throw "WinAppDriver was not found at '$WinAppDriverPath'."
}

try {
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $scanHoldPath
    $driverProcess = Start-Process `
        -FilePath $WinAppDriverPath `
        -ArgumentList "127.0.0.1", "4723" `
        -PassThru `
        -RedirectStandardOutput $standardOutputPath `
        -RedirectStandardError $standardErrorPath
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
    foreach ($expectedName in @("FingVibe", "Network:")) {
        $elements[$expectedName] = Find-WebDriverElement -Using name -Value $expectedName
    }
    $devicesMenuItem = Find-WebDriverElement -Using xpath -Value "//ListItem[@Name='Devices']"
    Invoke-WebDriverElement -ElementId $devicesMenuItem
    $elements["Scan LAN"] = Assert-VisibleUiReviewElement -Value "Scan LAN"

    if (-not (Get-WebDriverElementEnabled -ElementId $elements["Scan LAN"])) {
        throw "The primary 'Scan LAN' action is disabled."
    }

    Invoke-WebDriverElement -ElementId $elements["Scan LAN"]

    $interactionDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $scanEnteredExpectedState = $false
    do {
        $cancel = Find-WebDriverElement -Using name -Value "Cancel scan" -TimeoutSeconds 1 -Optional
        if ($cancel) {
            $null = Assert-VisibleUiReviewElement -Value "Cancel scan"
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

    $search = Assert-VisibleUiReviewElement -Value "Search devices"
    $removedSwitch = Find-WebDriverElement -Using name -Value "Show hosts" -TimeoutSeconds 1 -Optional
    if ($removedSwitch) { throw "The removed All / Alive switch is still present." }

    $elements["Scan LAN"] = Wait-UiReviewScan
    $null = Assert-VisibleUiReviewElement -Value "Online"
    $offline = Find-WebDriverElement -Using name -Value "Offline" -TimeoutSeconds 1 -Optional
    if ($offline) { throw "Nonresponding addresses must not appear in Devices." }

    $retainedRow = Assert-VisibleUiReviewElement -Using xpath `
        -Value "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]"
    [IO.File]::WriteAllText($scanHoldPath, "Hold the refresh until retained-list interaction has been verified.")
    Invoke-WebDriverElement -ElementId $elements["Scan LAN"]
    $cancel = Assert-VisibleUiReviewElement -Value "Cancel scan"
    $null = Assert-VisibleUiReviewElement -Value "Online"
    $null = Assert-VisibleUiReviewElement -Using xpath `
        -Value "//*[contains(@Name, 'Displaying retained results')]"
    Invoke-WebDriverElement -ElementId $retainedRow
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$retainedRow/value" `
        -Body @{ value = @([string] [char] 0xE007) }
    $null = Assert-VisibleUiReviewElement -Value "Search devices"
    $details = Find-WebDriverElement -Using name -Value "Back to devices" -TimeoutSeconds 1 -Optional
    if ($details) { throw "A retained row opened device details during scanning." }
    Invoke-WebDriverElement -ElementId $cancel
    Remove-Item -LiteralPath $scanHoldPath
    $elements["Scan LAN"] = Wait-UiReviewScan
    $null = Assert-VisibleUiReviewElement -Value "Online"

    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/value" `
        -Body @{ value = @("fingvibe-no-matching-host") }
    $null = Find-WebDriverElement -Using name -Value "No devices match the current filter."
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/clear" `
        -Body @{ }
    $null = Find-WebDriverElement -Using xpath -Value "//*[@Name='Online']"

    $elements["Scan LAN"] = Wait-UiReviewScan

    # Summary navigation must replace stale filters and expose hidden restrictions through the funnel.
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$search/value" `
        -Body @{ value = @("fingvibe-no-matching-host") }
    $overview = Find-WebDriverElement -Using xpath -Value "//ListItem[@Name='Overview']"
    Invoke-WebDriverElement -ElementId $overview
    $portsCard = Assert-VisibleUiReviewElement -Value "See devices with open ports"
    Invoke-WebDriverElement -ElementId $portsCard
    $count = Assert-VisibleUiReviewElement -Using xpath -Value "//*[@AutomationId='ActiveFilterCount']"
    $countText = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$count/text"
    if ($countText.value -ne "1") { throw "The open-port summary must expose one active secondary category." }
    $funnel = Assert-VisibleUiReviewElement -Using xpath -Value "//*[@AutomationId='FilterExpander']"
    Invoke-WebDriverElement -ElementId $funnel
    $null = Assert-VisibleUiReviewElement -Value "Ports: With open ports"
    $null = Assert-VisibleUiReviewElement -Value "Clear all Devices filters"
    $searchValue = Invoke-WebDriverRequest -Method Get -Endpoint "/session/$sessionId/element/$search/text"
    if ($searchValue.value) { throw "Summary navigation did not clear the stale text filter." }

    Invoke-WebDriverElement -ElementId $overview
    $onlineCard = Assert-VisibleUiReviewElement -Value "See online devices"
    $null = Invoke-WebDriverRequest -Method Post `
        -Endpoint "/session/$sessionId/element/$onlineCard/value" `
        -Body @{ value = @([string] [char] 0xE007) }
    $null = Assert-VisibleUiReviewElement -Value "Ports: All"
    $null = Assert-VisibleUiReviewElement -Value "Online"

    $captureDirectory = [System.IO.Path]::GetFullPath($ScreenshotDirectory)
    $null = New-Item -ItemType Directory -Path $captureDirectory -Force
    foreach ($capture in $capturePlan) {
        Write-Host "Capturing $($capture.Label): $($capture.Reasons -join ' ')"
        try {
            Show-UiReviewCaptureScenario -Scenario $capture.Scenario
            $path = Join-Path $captureDirectory $capture.FileName
            Save-UiReviewWindowScreenshot -WindowHandle $windowHandle -Path $path
            if ($capture.Scenario -eq "DeviceDetails") {
                Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
                Select-UiReviewDeviceTab -Root $root -Tab History
                $null = Assert-VisibleUiReviewElement -Value "Back to devices"
                $null = Assert-VisibleUiReviewElement -Value "Activity"
                Save-UiReviewWindowScreenshot -WindowHandle $windowHandle `
                    -Path (Join-Path $captureDirectory "fingvibe-device-history.png")
                Select-UiReviewDeviceTab -Root $root -Tab Overview
            }
        }
        catch {
            throw "Required capture '$($capture.Label)' failed: $($_.Exception.Message)"
        }
    }
    Test-UiReviewNavigation
    Test-UiReviewNameSuggestion "Person" "Igor" "Iric" "II"
    Test-UiReviewNameSuggestion "Room" "Living" "Room" "LR"
    Write-Host "People and Rooms native short-name suggestion regression tests passed."
    Show-UiReviewCaptureScenario -Scenario "DeviceDetails"
    Set-UiReviewAssignment "Room" "UI · UI review room" "Room assignment saved."
    Set-UiReviewAssignment "Person" "UI · UI review person" "Person assignment saved."
    Assert-UiReviewAssignment "Room" "UI · UI review room"
    Set-UiReviewAssignment "Room" "Unassigned" "Room assignment saved."
    Assert-UiReviewAssignment "Person" "UI · UI review person"
    Set-UiReviewAssignment "Person" "Unassigned" "Person assignment saved."
    Show-UiReviewCaptureScenario -Scenario "DeviceDetails"
    Assert-UiReviewAssignment "Room" "Unassigned"
    Assert-UiReviewAssignment "Person" "Unassigned"
    Write-Host "People and Rooms native assignment regression tests passed."

    # Publish a manifest only after every required view/state was verified and captured.
    ConvertTo-Json -InputObject @($capturePlan) -Depth 5 |
        Set-Content -LiteralPath (Join-Path $captureDirectory "capture-manifest.json") -Encoding utf8

    $succeeded = $true
}
finally {
    if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $savedScanHold
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
            Copy-Item -LiteralPath $startupLogPath -Destination $logDirectory -Force
            Get-Content -LiteralPath $startupLogPath | Write-Host
        }
        try {
            Get-WinEvent -FilterHashtable @{
                LogName = "Application"
                ProviderName = @(".NET Runtime", "Application Error")
                StartTime = $reviewStartedAt
            } -ErrorAction Stop |
                Where-Object { $_.Message -like "*FingVibe.App*" } |
                ForEach-Object { $_.Message } |
                Tee-Object -FilePath (Join-Path $logDirectory "application-crashes.log") |
                Write-Host
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
