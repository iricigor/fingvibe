$savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$savedCurrentSnapshot = $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT
$savedNetwork = $env:FINGVIBE_UI_REVIEW_NETWORK
$inventory = Join-Path $fixtureDirectory 'virtual-expansion-inventory.json'
$snapshot = Join-Path $fixtureDirectory 'virtual-expansion-scan.json'
$time = [DateTimeOffset]::new(2026, 11, 18, 6, 0, 0, [TimeSpan]::Zero)
$devices = @{}
$history = @()
foreach ($index in 1..6) {
    $mac = "D0C907{0:D6}" -f $index
    $seen = $time.AddMinutes($index).ToString('o')
    $observation = @{
        networkId = 'ui-review-network'; subnet = '127.0.0.1/32'
        address = "127.0.0.$index"; hostname = $null; vendor = if ($index -eq 1) { "Long expansion vendor $index" } else { "Private" }
        ports = @(); latency = $index; probeDuration = '00:00:00.001'
        # Members must stay Unknown: PrivateVirtualDevice excludes MACs with known type/OS evidence from grouping.
        classification = @{ type = 0; operatingSystem = 0; typeEvidence = 'Synthetic'; operatingSystemEvidence = 'Synthetic' }
        firstSeen = $seen; lastSeen = $seen; lastChecked = $seen; present = $index -eq 6
    }
    $devices[$mac] = @{ mac = $mac; imported = @{}; observations = @($observation); scanHistory = @() }
    $history += @{ mac = $mac; observation = $observation; inferred = $true }
}
$devices["001122334455"] = @{
    mac = "001122334455"; imported = @{ name = "Expansion normal" }
    observations = @(@{
        networkId = 'ui-review-network'; subnet = '127.0.0.1/32'; address = '127.0.0.20'
        hostname = 'normal'; vendor = 'Example'; ports = @(); latency = 1; probeDuration = '00:00:00.001'
        # Unknown type, like the virtual row, so neither shows a secondary type line and only the chevron differs.
        classification = @{ type = 0; operatingSystem = 2; typeEvidence = 'Synthetic'; operatingSystemEvidence = 'Synthetic' }
        firstSeen = $time.ToString('o'); lastSeen = $time.ToString('o'); lastChecked = $time.ToString('o'); present = $true
    }); scanHistory = @()
}
$data = @{
    revision = [Guid]::NewGuid().ToString(); devices = $devices; names = @{}; classifications = @{}
    peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }; discoveryBaselines = @()
    virtualDevices = @(@{
        id = [Guid]::NewGuid().ToString(); networkId = 'ui-review-network'; subnet = '127.0.0.1/32'
        prefix = 'D0C907'; number = 1; lastActiveMac = 'D0C907000006'; lastChecked = $time.AddMinutes(6).ToString('o')
        present = $true; name = 'Expansion virtual'; history = $history; scanHistory = @()
    })
}
@{ version = 4; data = $data } | ConvertTo-Json -Depth 18 |
    Set-Content -LiteralPath $inventory -Encoding UTF8
@{ version = 3; subnet = '127.0.0.1/32'; completedAt = $time.AddMinutes(6).ToString('o')
   duration = '00:00:00.100'; results = @() } | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $snapshot -Encoding UTF8

function Find-ExpansionRow {
    @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
}

function Find-ExpansionParts($Row, [string] $Id) {
    @($Row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)))
}

function Test-ExpansionInk([object[]] $Elements, [int[]] $SystemColors) {
    # Require real high-contrast ink while allowing anti-aliased coverage of a small icon.
    $capture = Save-DeviceCapture 'devices-mac-expansion-high-contrast'
    $window = Get-UiReviewWindowBounds $windowHandle
    $bitmap = [Drawing.Bitmap]::new($capture)
    try {
        foreach ($element in $Elements) {
            $bounds = $element.Current.BoundingRectangle
            # Re-laid-out or virtualized peers can briefly report empty or infinite bounds; wait for real geometry.
            if ($bounds.IsEmpty -or -not ([double]::IsFinite($bounds.Left) -and [double]::IsFinite($bounds.Top) -and
                    [double]::IsFinite($bounds.Width) -and [double]::IsFinite($bounds.Height))) { return $false }
            $left = [int][Math]::Ceiling($bounds.Left - $window.Left)
            $top = [int][Math]::Ceiling($bounds.Top - $window.Top)
            $right = [int][Math]::Floor([Math]::Min($bounds.Right - $window.Left, $bitmap.Width))
            $bottom = [int][Math]::Floor([Math]::Min($bounds.Bottom - $window.Top, $bitmap.Height))
            if ($left -lt 0 -or $top -lt 0 -or $right -le $left -or $bottom -le $top) { return $false }
            $background = $bitmap.GetPixel($left, $top)
            $inked = $false
            foreach ($color in $SystemColors) {
                $expected = [Drawing.Color]::FromArgb($color -band 255, ($color -shr 8) -band 255, ($color -shr 16) -band 255)
                $redDelta = [int]$expected.R - $background.R
                $greenDelta = [int]$expected.G - $background.G
                $blueDelta = [int]$expected.B - $background.B
                $lengthSquared = $redDelta * $redDelta + $greenDelta * $greenDelta + $blueDelta * $blueDelta
                if ($lengthSquared -le 32 * 32) { continue }
                for ($y = $top; $y -lt $bottom -and -not $inked; $y++) {
                    for ($x = $left; $x -lt $right -and -not $inked; $x++) {
                        $pixel = $bitmap.GetPixel($x, $y)
                        $redPixelDelta = [int]$pixel.R - $background.R
                        $greenPixelDelta = [int]$pixel.G - $background.G
                        $bluePixelDelta = [int]$pixel.B - $background.B
                        $coverage = [Math]::Max(0d, [Math]::Min(1d,
                            [double]($redPixelDelta * $redDelta + $greenPixelDelta * $greenDelta +
                                $bluePixelDelta * $blueDelta) / $lengthSquared))
                        $compositedRed = $background.R + $coverage * $redDelta
                        $compositedGreen = $background.G + $coverage * $greenDelta
                        $compositedBlue = $background.B + $coverage * $blueDelta
                        $rasterError = [Math]::Max([Math]::Abs($pixel.R - $compositedRed),
                            [Math]::Max([Math]::Abs($pixel.G - $compositedGreen),
                                [Math]::Abs($pixel.B - $compositedBlue)))
                        $inked = $coverage -ge 0.8 -and $rasterError -le 8
                    }
                }
                if ($inked) { break }
            }
            if (-not $inked) {
                Write-Host "High-contrast ink missing for '$($element.Current.AutomationId)' at $bounds; background $background."
                return $false
            }
        }
        return $true
    }
    finally { $bitmap.Dispose() }
}

function Test-MacExpansionHighContrast {
    $flags = [DeviceFilterReviewContrast]::Get()
    $contrastFailed = $true
    try {
        Set-DeviceFilterContrastFlags -Flags ($flags -bor 1)
        Wait-DeviceFilterContrastReady -Enabled $true
        # Window text, highlight text (selected row) and button text are the high-contrast foregrounds in use.
        $systemColors = @(8, 14, 18 | ForEach-Object { [DeviceFilterReviewContrast]::GetSysColor($_) })
        $chevron = Wait-UiRegressionState -Description 'expanded MAC row rendered in high contrast' -Condition {
            $candidate = Find-ExpansionRow
            if (-not $candidate) { return $null }
            $labels = Find-ExpansionParts $candidate 'DeviceMacExpansionLabel'
            $button = Find-ExpansionParts $candidate 'DeviceMacExpansionButton'
            $more = Find-ExpansionParts $candidate 'DeviceMacExpansionMore'
            if ($labels.Count -ne 3 -or $button.Count -ne 1 -or $more.Count -ne 1) { return $null }
            if (Test-ExpansionInk (@($button[0], $more[0]) + $labels) $systemColors) { $button[0] }
        }
        # State is announced by name and help text, not by color.
        $bounds = $chevron.Current.BoundingRectangle
        if ($chevron.Current.Name -cne 'Hide 5 more MAC addresses' -or $chevron.Current.HelpText -cne '5 more MAC addresses, expanded' -or
            $bounds.Width -lt 23.5 * $scale -or $bounds.Height -lt 23.5 * $scale) {
            throw "The high-contrast chevron must stay a named 24-DIP target: $($chevron.Current.Name) / $($chevron.Current.HelpText) / $bounds."
        }
        $contrastFailed = $false
    }
    finally {
        Invoke-UiRegressionCleanup -PrimaryFailed $contrastFailed -Steps @(
            { Set-DeviceFilterContrastFlags -Flags $flags },
            { Wait-DeviceFilterContrastReady -Enabled (($flags -band 1) -ne 0) })
    }
}

$expansionTextScale = @{}
function Set-ExpansionTextScale {
    # The app reads the Windows text scale at startup, so call this while the app is closed.
    $appDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $AppPath).Path
    Add-Type -Path (Join-Path $appDirectory 'WinRT.Runtime.dll')
    Add-Type -Path (Join-Path $appDirectory 'Microsoft.Windows.SDK.NET.dll')
    $settings = [Windows.UI.ViewManagement.UISettings]::new()
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    try {
        $value = $key.GetValue('TextScaleFactor', $null)
        $expansionTextScale.Settings = $settings
        $expansionTextScale.Scale = $settings.TextScaleFactor
        $expansionTextScale.Value = $value
        $expansionTextScale.Kind = if ($null -ne $value) { $key.GetValueKind('TextScaleFactor') } else { $null }
        $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    finally { $key.Dispose() }
    [DeviceFilterReviewContrast]::NotifyTextScaleChanged()
    $null = Wait-UiRegressionState -Description 'effective Windows text scale of 200 percent' -Condition {
        [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
    }
}

function Restore-ExpansionTextScale {
    if (-not $expansionTextScale.Settings) { return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
    try {
        if ($null -eq $expansionTextScale.Value) { $key.DeleteValue('TextScaleFactor', $false) }
        else { $key.SetValue('TextScaleFactor', $expansionTextScale.Value, $expansionTextScale.Kind) }
    }
    finally { $key.Dispose() }
    [DeviceFilterReviewContrast]::NotifyTextScaleChanged()
    $null = Wait-UiRegressionState -Description 'restored Windows text scale' -Condition {
        [Math]::Abs($expansionTextScale.Settings.TextScaleFactor - $expansionTextScale.Scale) -lt 0.01
    }
    $expansionTextScale.Clear()
}

function Test-MacExpansionTextScale {
    $row = Wait-UiRegressionState -Description 'collapsed MAC row at 200% text scale' -Condition { Find-ExpansionRow }
    $normal = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion normal'))
    } | Select-Object -First 1
    if (-not $normal -or [Math]::Abs($normal.Current.BoundingRectangle.Height - $row.Current.BoundingRectangle.Height) -gt $scale) {
        throw "Collapsed multi-MAC rows must keep single-MAC row height at 200% text scale. Normal=$($normal.Current.BoundingRectangle); collapsed=$($row.Current.BoundingRectangle); scale=$scale."
    }
    $chevron = @(Find-ExpansionParts $row 'DeviceMacExpansionButton')
    $rowBounds = $row.Current.BoundingRectangle
    if ($chevron.Count -ne 1 -or -not $rowBounds.Contains($chevron[0].Current.BoundingRectangle) -or
        $chevron[0].Current.BoundingRectangle.Width -lt 23.5 * $scale -or $chevron[0].Current.BoundingRectangle.Height -lt 23.5 * $scale) {
        throw "The chevron must stay a whole 24-DIP target inside its row at 200% text scale. Row=$rowBounds."
    }
    $chevron[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $lines = Wait-UiRegressionState -Description 'three earlier MAC lines at 200% text scale' -Condition {
        $candidate = Find-ExpansionRow
        if (-not $candidate) { return $null }
        $labels = @(Find-ExpansionParts $candidate 'DeviceMacExpansionLabel')
        $more = @(Find-ExpansionParts $candidate 'DeviceMacExpansionMore')
        if ($labels.Count -eq 3 -and $more.Count -eq 1) { , (@($labels | Sort-Object { $_.Current.BoundingRectangle.Top }) + $more) }
    }
    # At 200% text scale the list viewport (about 192 px) is shorter than the expanded row, and UIA clips peer
    # bounds to the scroll viewport, reporting the clip edge as a clipped line's bottom. Sample a bounded set of
    # scroll positions, take each line's largest observed height as its unclipped height, and check each adjacent
    # pair (in tree order) at a position where both show that full height inside the list.
    $list = Find-DeviceElement ResultsList
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $listBounds = $list.Current.BoundingRectangle
    $window = $root.Current.BoundingRectangle
    $positions = if ($scroll.Current.VerticallyScrollable) { 0..50 | ForEach-Object { $_ * 2 } } else { @(-1) }
    $isVisible = {
        param($Bounds)
        -not $Bounds.IsEmpty -and [double]::IsFinite($Bounds.Top) -and [double]::IsFinite($Bounds.Height) -and
            $Bounds.Top -ge $listBounds.Top - 0.5 -and $Bounds.Bottom -le $listBounds.Bottom + 0.5
    }
    $samples = [System.Collections.Generic.List[object]]::new()
    foreach ($percent in $positions) {
        if ($percent -ge 0) { $scroll.SetScrollPercent(-1, $percent); Start-Sleep -Milliseconds 50 }
        $candidate = Find-ExpansionRow
        if (-not $candidate) { continue }
        $labels = @(Find-ExpansionParts $candidate 'DeviceMacExpansionLabel')
        $more = @(Find-ExpansionParts $candidate 'DeviceMacExpansionMore')
        if ($labels.Count -ne 3 -or $more.Count -ne 1) { continue }
        $samples.Add(@((@($labels) + $more) | ForEach-Object { $_.Current.BoundingRectangle }))
    }
    $fullHeights = foreach ($index in 0..3) {
        ($samples | ForEach-Object { $_[$index] } | Where-Object { & $isVisible $_ } |
            Measure-Object -Property Height -Maximum).Maximum
    }
    foreach ($index in 0..2) {
        $pair = $samples | Where-Object {
            (& $isVisible $_[$index]) -and (& $isVisible $_[$index + 1]) -and
                $_[$index].Height -ge $fullHeights[$index] - 0.5 -and $_[$index + 1].Height -ge $fullHeights[$index + 1] - 0.5
        } | ForEach-Object { , @($_[$index], $_[$index + 1]) } | Select-Object -First 1
        if (-not $pair) {
            throw "Earlier MAC lines $index and $($index + 1) were never fully visible together at 200% text scale. List=$listBounds; full heights=$($fullHeights -join ', '); samples=$($samples.Count)."
        }
        foreach ($bounds in $pair) {
            if ($bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right -or $bounds.Height -lt 24 * $scale) {
                throw "Earlier MAC lines must stay readable and unclipped at 200% text scale. Line=$bounds; list=$listBounds; window=$window; scale=$scale."
            }
        }
        if ($pair[1].Top -lt $pair[0].Bottom - $scale) {
            throw "Earlier MAC lines must not overlap at 200% text scale. Lines=$($pair[0]) / $($pair[1]); scale=$scale."
        }
    }    $null = Save-DeviceCapture 'devices-mac-expansion-text-scale-200'
}
Stop-UiRegressionApp -Process $process
$expansionFailed = $true
try {
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '0'
    $env:FINGVIBE_UI_REVIEW_NETWORK = 'ui-review-network'
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
    $row = Wait-UiRegressionState -Description 'virtual row expansion fixture' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    $normal = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion normal'))
    } | Select-Object -First 1
    if (-not $normal) { throw 'The expansion fixture must retain a normal single-MAC row.' }
    $normalChevron = $normal.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    if ($normalChevron) { throw 'A single-MAC row must not expose a MAC expansion chevron.' }
    if ([Math]::Abs($normal.Current.BoundingRectangle.Height - $row.Current.BoundingRectangle.Height) -gt $scale) {
        throw "Collapsed multi-MAC rows must retain the same height as single-MAC rows. Normal=$($normal.Current.BoundingRectangle); collapsed=$($row.Current.BoundingRectangle)."
    }
    $chevron = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    if (-not $chevron -or $chevron.Current.Name -ne 'Show 5 more MAC addresses') {
        throw 'A multi-MAC virtual row must expose the count-aware collapsed chevron.'
    }
    $chevron.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'three earlier MAC rows' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $more = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionMore'))
    if (-not $more -or $more.Current.Name -notlike '+2 more MAC addresses*') {
        throw 'The expanded row must summarize MACs beyond the three-line preview.'
    }
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x25)
    $null = Wait-UiRegressionState -Description 'keyboard-collapsed MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 0
    }
    [DevicesReviewInput]::Tap(0x27)
    $null = Wait-UiRegressionState -Description 'keyboard-expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $rowName = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceNameText'))
    $nameBounds = $rowName.Current.BoundingRectangle
    [DevicesReviewInput]::MoveTo(
        [int]($nameBounds.Left + $nameBounds.Width / 2),
        [int]($nameBounds.Top + $nameBounds.Height / 2))
    [DevicesReviewInput]::Click()
    $null = Find-DeviceElement DeviceDetailsScroll
    (Find-DeviceElement DeviceBackButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $row = Wait-UiRegressionState -Description 'MAC expansion retained across page navigation' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    if ($row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -ne 3) {
        throw 'MAC expansion state must survive opening Device Details and returning.'
    }
    (Find-DeviceElement NameSortButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'MAC expansion retained across sorting' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x25)
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue('D0-C9-07-00-00-01')
    $null = Wait-UiRegressionState -Description 'search-revealed earlier MAC' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 4
    }
    $search.SetValue('')
    $null = Wait-UiRegressionState -Description 'previous collapsed MAC state restored after search' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 0
    }
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x27)
    $null = Wait-UiRegressionState -Description 'wide expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    Save-DeviceCapture 'devices-mac-expansion-wide'
    $disposableDesktop = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_OS -eq 'Windows'
    if ($disposableDesktop) { Test-MacExpansionHighContrast }
    Set-DeviceWidth 640
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $narrowChevron = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    $null = Wait-UiRegressionState -Description 'narrow expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $narrowChevron.SetFocus()
    Save-DeviceCapture 'devices-mac-expansion-narrow'
    Stop-UiRegressionApp -Process $process
    # System text scale and high contrast are changed only on disposable CI desktops.
    if ($disposableDesktop) { Set-ExpansionTextScale }
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
    $restarted = Wait-UiRegressionState -Description 'MAC expansion reset after restart' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    if ($restarted.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -ne 0) {
        throw 'MAC row expansion must start collapsed after an application restart.'
    }
    if ($disposableDesktop) { Test-MacExpansionTextScale }
    Write-Host 'Virtual-device chevron, extra MAC lines, search restore, keyboard and round-trip state passed.'
    $expansionFailed = $false
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $expansionFailed -Steps @(
        { Stop-UiRegressionApp -Process $process },
        { Restore-ExpansionTextScale })
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = $savedCurrentSnapshot
    $env:FINGVIBE_UI_REVIEW_NETWORK = $savedNetwork
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
}
