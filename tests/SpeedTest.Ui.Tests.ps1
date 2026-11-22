param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = 'Stop'
# The fixed header stays above the scrolling body, which shows only the Test, Live measurement and Results cards, in that order.
$speedDocument = [System.Xml.XmlDocument]::new()
$speedDocument.Load((Join-Path $PSScriptRoot '..\src\FingVibe.App\Tools\SpeedTestPage.xaml'))
$xamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
$speedScroll = $speedDocument.SelectSingleNode("//*[local-name()='ScrollViewer']")
$pageChildren = @($speedDocument.SelectNodes("//*[local-name()='ScrollViewer']/*[local-name()='StackPanel']/*"))
$cardNames = @($pageChildren | ForEach-Object { $_.GetAttribute('Name', $xamlNamespace) })
if (-not $speedScroll -or $speedScroll.PreviousSibling.LocalName -ne 'Grid' -or
    -not $speedScroll.PreviousSibling.SelectSingleNode(".//*[local-name()='PageBackButton' and @Destination='Tools']") -or
    $pageChildren.Count -ne 3 -or @($pageChildren | Where-Object LocalName -ne 'Border').Count -ne 0 -or
    ($cardNames -join ',') -ne 'TestCard,LiveMeasurementCard,ResultsCard') {
    throw 'The Speed test page must keep its header fixed above the Test, Live measurement and Results cards, in order, with no loose paragraphs.'
}
foreach ($membership in @(
    @{ Card = 'TestCard'; Names = @('StatusText', 'TestProgress', 'StartTestButton', 'CancelTestButton') },
    @{ Card = 'LiveMeasurementCard'; Names = @('LiveGauges', 'DownloadGauge', 'UploadGauge') },
    @{ Card = 'ResultsCard'; Names = @('DownloadResultText', 'DownloadRatingText', 'UploadResultText', 'UploadRatingText', 'LatencyResultText', 'LocationResultText') })) {
    $card = $speedDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($membership.Card)']")
    foreach ($name in $membership.Names) {
        if (-not $card -or -not $card.SelectSingleNode(".//*[@*[local-name()='Name']='$name']")) {
            throw "$name must belong to the Speed test $($membership.Card)."
        }
    }
}

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Speed test UI checks require a disposable GitHub-hosted desktop.'
}
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewScreenshot.ps1')
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewAppearance.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
if (-not ('SidebarReviewKeyboard' -as [type])) {
    . (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Controls.Helpers.ps1')
}

function Find-SpeedElement([string] $Property, [string] $Value) {
    if (-not $script:root) { return $null }
    $propertyId = if ($Property -eq 'Name') { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value))
}

function Wait-SpeedElement([string] $Property, [string] $Value, [string] $Description) {
    Wait-UiRegressionState { Find-SpeedElement $Property $Value } $Description
}

function Invoke-SpeedElement($Element) {
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Show-SpeedTargets([string[]] $Names, [string] $Description) {
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-SpeedElement AutomationId SpeedTestScroll } `
        -GetTargets { foreach ($name in $Names) { Find-SpeedElement Name $name } } -GetWindow { $script:root } `
        -Description $Description
}

function Wait-SpeedStatus([string] $Expected) {
    $null = Wait-UiRegressionState { (Find-SpeedElement AutomationId StatusText).Current.Name -eq $Expected } "status '$Expected'"
}

function Select-SpeedNavigation([string] $Id) {
    $item = Find-SpeedElement AutomationId $Id
    if (-not (Test-UiRegressionElementVisible $item)) { Invoke-SpeedElement (Find-SpeedElement AutomationId TogglePaneButton) }
    (Find-SpeedElement AutomationId $Id).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Start-SpeedApp {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    $null = Wait-UiRegressionState {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Speed test review app exited: $($script:process.ExitCode)." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    } 'speed test review window' -TimeoutMilliseconds 30000
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    $null = Wait-SpeedElement AutomationId ToolsNavItem 'Tools navigation readiness'
}

function Stop-SpeedApp {
    Stop-UiRegressionApp $script:process
    if ($script:process) { $script:process.Dispose() }
    $script:process = $null
    $script:root = $null
}

function Open-SpeedTestPage {
    Select-SpeedNavigation ToolsNavItem
    $card = Wait-SpeedElement AutomationId SpeedTestCard 'Speed test Tools card'
    $card.SetFocus()
    $scrollItem = $null
    if ($card.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
        $scrollItem.ScrollIntoView()
    }
    $null = Wait-UiRegressionState { Test-UiRegressionElementVisible (Find-SpeedElement AutomationId SpeedTestCard) } 'reachable Speed test card'
    Invoke-SpeedElement (Find-SpeedElement AutomationId SpeedTestCard)
    $null = Wait-UiRegressionState { Test-UiRegressionElementVisible (Find-SpeedElement AutomationId StartTestButton) } 'Speed test page'
    foreach ($text in @('Test', 'Cloudflare', "Measure this PC's internet connection using Cloudflare. Windows chooses the internet route; the LAN scanner's selected adapter is not used.",
        'Before each run, FingVibe explains data use and Cloudflare result reporting and asks for your confirmation.', 'Live measurement')) {
        Show-SpeedTargets @($text) "Speed test '$text'"
    }
    $test = (Find-SpeedElement Name 'Test').Current.BoundingRectangle
    $start = (Find-SpeedElement AutomationId StartTestButton).Current.BoundingRectangle
    $live = (Find-SpeedElement Name 'Live measurement').Current.BoundingRectangle
    if (-not ($test.Bottom -le $start.Top -and $start.Bottom -le $live.Top)) {
        throw 'Start and its Test card must precede the Live measurement card.'
    }
}

function Start-SpeedFixtureRun {
    Show-SpeedTargets @('Start Cloudflare speed test') 'Start test'
    $start = Find-SpeedElement AutomationId StartTestButton
    $start.SetFocus()
    $null = Wait-UiRegressionState { (Find-SpeedElement AutomationId StartTestButton).Current.HasKeyboardFocus } 'keyboard focus on Start test'
    Invoke-SpeedElement $start
    # Per-run consent is unchanged: the fixture only replaces the engine after confirmation.
    $null = Wait-SpeedElement Name "Cloudflare's official engine sends measurement results to Cloudflare. This is not a local-only test." 'data-use confirmation'
    $confirm = Wait-UiRegressionState {
        $button = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Start test'),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button)))
        if (Test-UiRegressionElementVisible $button) { $button }
    } 'confirmation Start test button'
    Invoke-SpeedElement $confirm
}

function Wait-SpeedResults([string] $Theme) {
    foreach ($name in @('Download speed: 312.4 Mbps, Good', 'Upload speed: 18.6 Mbps, Fair', 'Results')) {
        $null = Wait-SpeedElement Name $name "final result '$name'"
    }
    Wait-SpeedStatus 'Speed test complete. The official engine attempted to report results to Cloudflare.'
    Show-SpeedTargets @('Download speed: 312.4 Mbps, Good', 'Upload speed: 18.6 Mbps, Fair') "$Theme results"
    $live = (Find-SpeedElement Name 'Live measurement').Current.BoundingRectangle
    $results = (Find-SpeedElement Name 'Results').Current.BoundingRectangle
    if ($results.Top -le $live.Bottom) { throw 'The Results card must follow the Live measurement card.' }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "speed-test-results-$Theme.png")
}

$environment = Save-UiRegressionEnvironment @('FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_SPEED_TEST')
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-speed-test-ui-$([Guid]::NewGuid().ToString('N'))"
$contrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
$script:process = $null
$script:root = $null
$phase = $null
$failure = $null
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $env:FINGVIBE_UI_REVIEW = '1'
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture 'device-inventory.json'
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture 'unused-snapshot.json'
    $env:FINGVIBE_UI_REVIEW_SPEED_TEST = 'provisional,failed,results'
    [SidebarReviewKeyboard]::SetHighContrastFlags($contrast -band (-bnot [uint32]1))

    $phase = Step-UiRegressionPhase $phase 'SpeedTest/provisional-cancel' -Directory $ScreenshotDirectory
    Start-SpeedApp
    Open-SpeedTestPage
    Start-SpeedFixtureRun
    foreach ($name in @('Download provisional speed: 62.5 Mbps, Fair', 'Upload provisional speed: 3.2 Mbps, Slow')) {
        $null = Wait-SpeedElement Name $name "provisional gauge '$name'"
    }
    $cancel = Find-SpeedElement AutomationId CancelTestButton
    if (-not $cancel.Current.IsEnabled -or -not $cancel.Current.IsKeyboardFocusable) {
        throw 'Cancel must be enabled and keyboard reachable while a speed test runs.'
    }
    Show-SpeedTargets @('Download provisional speed: 62.5 Mbps, Fair', 'Upload provisional speed: 3.2 Mbps, Slow') 'provisional gauges'
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'speed-test-provisional.png')
    Invoke-SpeedElement $cancel
    Wait-SpeedStatus 'Test cancelled. No completed results were recorded.'
    foreach ($name in @('Download provisional speed: no sample', 'Upload provisional speed: no sample')) {
        $null = Wait-SpeedElement Name $name "cleared gauge '$name'"
    }

    $phase = Step-UiRegressionPhase $phase 'SpeedTest/failed' -Directory $ScreenshotDirectory
    Start-SpeedFixtureRun
    Wait-SpeedStatus 'The Cloudflare measurement timed out. Check the connection and retry.'
    if (Find-SpeedElement Name 'Results') { throw 'A failed run must not show the Results card.' }

    $phase = Step-UiRegressionPhase $phase 'SpeedTest/results-light' -Directory $ScreenshotDirectory
    Start-SpeedFixtureRun
    Wait-SpeedResults 'light'

    $phase = Step-UiRegressionPhase $phase 'SpeedTest/results-dark-narrow' -Directory $ScreenshotDirectory
    Select-SpeedNavigation DevicesNavItem
    $settings = Find-SpeedElement Name 'Settings'
    if (-not (Test-UiRegressionElementVisible $settings)) {
        Invoke-SpeedElement (Find-SpeedElement AutomationId TogglePaneButton)
        $settings = Find-SpeedElement Name 'Settings'
    }
    $settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Expand-UiReviewSettingsSection -Root $script:root -Section AppearanceSection
    $null = Wait-SpeedElement AutomationId ModePicker 'appearance settings'
    Set-UiReviewTheme -Root $script:root -Theme 'Standard Dark'
    Open-SpeedTestPage
    Start-SpeedFixtureRun
    Wait-SpeedResults 'dark'
    $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero, 0, 0, 640, 760, 0x0044)
    $gauges = @('Download provisional speed: no sample', 'Upload provisional speed: no sample')
    $null = Wait-UiRegressionState {
        $download = (Find-SpeedElement Name $gauges[0]).Current.BoundingRectangle
        $upload = (Find-SpeedElement Name $gauges[1]).Current.BoundingRectangle
        $upload.Top -gt $download.Bottom
    } 'stacked narrow gauges'
    foreach ($name in @('Start Cloudflare speed test', $gauges[0], $gauges[1], 'Download speed: 312.4 Mbps, Good', 'Upload speed: 18.6 Mbps, Fair')) {
        Show-SpeedTargets @($name) "narrow '$name'"
        if (-not (Test-UiRegressionElementWithin (Find-SpeedElement Name $name) (Find-SpeedElement AutomationId SpeedTestScroll) $script:root)) {
            throw "'$name' must stay inside the narrow Speed test page without horizontal scrolling."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'speed-test-narrow-dark.png')

    $phase = Step-UiRegressionPhase $phase 'SpeedTest/high-contrast' -Directory $ScreenshotDirectory
    Stop-SpeedApp
    [SidebarReviewKeyboard]::SetHighContrastFlags($contrast -bor 1)
    $env:FINGVIBE_UI_REVIEW_SPEED_TEST = 'results'
    Start-SpeedApp
    Open-SpeedTestPage
    Start-SpeedFixtureRun
    Wait-SpeedResults 'high-contrast'
}
catch {
    $failure = $_
    Write-Host $failure
    Write-Host $failure.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory 'speed-test-failure.png') }
        catch { Write-Warning "Could not capture speed test failure: $_" }
    }
    throw $failure
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed ($null -ne $failure) -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded ($null -eq $failure) } },
        { Stop-SpeedApp },
        { [SidebarReviewKeyboard]::SetHighContrastFlags($contrast) },
        { Restore-UiRegressionEnvironment $environment },
        { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    )
}
