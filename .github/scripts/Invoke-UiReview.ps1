[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotPath,

    [string] $WinAppDriverPath =
        "${env:ProgramFiles(x86)}\Windows Application Driver\WinAppDriver.exe"
)

$ErrorActionPreference = "Stop"
$serverUrl = "http://127.0.0.1:4723"
$sessionId = $null
$driverProcess = $null
$succeeded = $false
$logDirectory = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
}
else {
    [System.IO.Path]::GetTempPath()
}
$standardOutputPath = Join-Path $logDirectory "fingvibe-winappdriver.stdout.log"
$standardErrorPath = Join-Path $logDirectory "fingvibe-winappdriver.stderr.log"

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

function Save-WebDriverScreenshot {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $response = Invoke-WebDriverRequest -Method Get `
        -Endpoint "/session/$sessionId/screenshot"
    $bytes = [Convert]::FromBase64String([string] $response.value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        if ($bitmap.Width -lt 640 -or $bitmap.Height -lt 480) {
            throw "The screenshot rendered at an invalid size: $($bitmap.Width)x$($bitmap.Height)."
        }

        $colors = [System.Collections.Generic.HashSet[int]]::new()
        $xStep = [Math]::Max([int] ($bitmap.Width / 20), 1)
        $yStep = [Math]::Max([int] ($bitmap.Height / 20), 1)
        for ($x = 0; $x -lt $bitmap.Width; $x += $xStep) {
            for ($y = 0; $y -lt $bitmap.Height; $y += $yStep) {
                $null = $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
            }
        }

        if ($colors.Count -lt 8) {
            throw "The screenshot appears blank or failed to render."
        }
    }
    finally {
        $bitmap.Dispose()
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

    $elements = @{}
    foreach ($expectedName in @("FingVibe", "Detected network", "Scan LAN", "Cancel")) {
        $elements[$expectedName] = Find-WebDriverElement -Using name -Value $expectedName
    }

    if (-not (Get-WebDriverElementEnabled -ElementId $elements["Scan LAN"])) {
        throw "The primary 'Scan LAN' action is disabled."
    }

    Invoke-WebDriverElement -ElementId $elements["Scan LAN"]

    $interactionDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $scanEnteredExpectedState = $false
    do {
        if (Get-WebDriverElementEnabled -ElementId $elements["Cancel"]) {
            $scanEnteredExpectedState = $true
            break
        }

        $completion = Find-WebDriverElement `
            -Using xpath `
            -Value "//*[starts-with(@Name, 'Complete in ')]" `
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

    Save-WebDriverScreenshot -Path $ScreenshotPath

    if (Get-WebDriverElementEnabled -ElementId $elements["Cancel"]) {
        Invoke-WebDriverElement -ElementId $elements["Cancel"]
    }

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
        if (Test-Path -LiteralPath $standardOutputPath) {
            Get-Content -LiteralPath $standardOutputPath | Write-Host
        }
        if (Test-Path -LiteralPath $standardErrorPath) {
            Get-Content -LiteralPath $standardErrorPath | Write-Host
        }
    }
}

Write-Host "UI smoke test passed and screenshot saved to '$ScreenshotPath'."
