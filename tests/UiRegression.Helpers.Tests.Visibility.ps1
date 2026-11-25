# Shared foundation: scroll targets and element-within-viewport checks.
& {
    function New-TestRectangle([double] $Left, [double] $Top, [double] $Width, [double] $Height) {
        [pscustomobject]@{
            Left = $Left; Top = $Top; Width = $Width; Height = $Height
            Right = $Left + $Width; Bottom = $Top + $Height; IsEmpty = $false
        }
    }
    function New-BoundedElement([double] $Left, [double] $Top, [double] $Width, [double] $Height) {
        [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = New-TestRectangle $Left $Top $Width $Height
        } }
    }
    $window = New-BoundedElement 0 0 600 800
    $viewport = New-BoundedElement 20 100 560 900
    $cell = New-BoundedElement 20 768 36 32
    Assert-Regression (Test-UiRegressionElementWithin $cell $viewport $window) 'A cell at the visible bottom edge must not fail an invented 16-pixel inset.'
    foreach ($bounds in @(
        (New-TestRectangle 20 769 36 32),
        (New-TestRectangle 19 768 36 32),
        (New-TestRectangle 545 768 36 32),
        (New-TestRectangle 20 99 36 32)
    )) {
        $cell.Current.BoundingRectangle = $bounds
        Assert-Regression (-not (Test-UiRegressionElementWithin $cell $viewport $window)) 'Even one pixel outside the window or nested viewport must remain a failure.'
    }
    $cell.Current.BoundingRectangle = New-TestRectangle 20 768 36 32
    $cell.Current.IsOffscreen = $true
    Assert-Regression (-not (Test-UiRegressionElementWithin $cell $viewport $window)) 'Offscreen peers cannot prove rendered visibility.'
    $full = New-BoundedElement 20 100 112 52
    $tolerated = New-BoundedElement 140 100 111 51
    $clippedBottom = New-BoundedElement 20 117 112 35
    $clippedRight = New-BoundedElement 100 100 70 52
    $largest = @(Select-UiRegressionLargestRenderedPeers @($full, $tolerated, $clippedBottom, $clippedRight) -Tolerance 1.5)
    Assert-Regression ($largest.Count -eq 2 -and $full -in $largest -and $tolerated -in $largest) 'Largest-rendered peer selection must exclude UIA rectangles clipped on any edge while retaining tolerance-sized peers.'
    Assert-Regression (@(Select-UiRegressionLargestRenderedPeers @() -Tolerance 1.5).Count -eq 0) 'Largest-rendered peer selection must preserve an empty candidate set.'

    $fixedWindow = New-BoundedElement 0 0 500 300
    $bodyViewport = New-BoundedElement 0 100 500 200
    $fixedHeader = New-BoundedElement 10 40 120 30
    $bodyViewport | Add-Member ScriptMethod GetCurrentPattern {
        throw 'Fixed header positioning must not request the body ScrollPattern.'
    }
    $fixedResult = Show-UiRegressionScrollTargets -Description 'fixed page header' `
        -GetViewport { $bodyViewport } -GetWindow { $fixedWindow } -GetTargets { $fixedHeader }
    Assert-Regression ($fixedResult -eq $fixedHeader) 'A visible peer outside the body scroller must not be repositioned with that scroller.'

    $edgeWindow = New-BoundedElement 0 0 500 300
    $edgeViewport = New-BoundedElement 0 0 500 300
    $underHeader = New-BoundedElement 10 40 100 30
    $edgeMoves = [Collections.Generic.List[double]]::new()
    $edgeScroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 50.0; VerticalViewSize = 20.0
    } }
    $edgeScroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $edgeMoves.Add($Percent)
        $delta = ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        $bounds = $underHeader.Current.BoundingRectangle
        $underHeader.Current.BoundingRectangle = New-TestRectangle $bounds.Left ($bounds.Top - $delta) $bounds.Width $bounds.Height
    }
    $edgeViewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $edgeScroll }
    $null = Show-UiRegressionScrollTargets -Description 'body target under a fixed header' -GetTopEdge { 120 } `
        -GetViewport { $edgeViewport } -GetWindow { $edgeWindow } -GetTargets { $underHeader }
    Assert-Regression ($edgeMoves.Count -ge 1 -and $underHeader.Current.BoundingRectangle.Top -ge 120) 'A scroller rectangle that extends under a fixed header must not prove a body target visible.'

    $viewport = New-BoundedElement 0 0 500 300
    $window = New-BoundedElement 0 0 500 300
    $first = New-BoundedElement 10 900 100 20
    $last = New-BoundedElement 10 1100 100 30
    $positions = [Collections.Generic.List[double]]::new()
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    }; MoveBounds = $true }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $delta = ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        if ($this.MoveBounds) {
            foreach ($target in @($first, $last)) {
                $bounds = $target.Current.BoundingRectangle
                $target.Current.BoundingRectangle = New-TestRectangle $bounds.Left ($bounds.Top - $delta) $bounds.Width $bounds.Height
            }
        }
    }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $arguments = @{
        GetViewport = { $viewport }; GetWindow = { $window }; GetTargets = { $first; $last }
        Description = 'grouped summary'; TopMargin = 35; BottomMargin = 10
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $first -and $positions.Count -eq 1 -and $positions[0] -eq 70) 'Grouped controls must be positioned directly from geometry, not a percent-by-percent sweep.'
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'The last target, not only the first, must fit above the bottom margin.'
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1) 'Already-visible groups must not scroll again.'
    $last.Current.BoundingRectangle = New-TestRectangle 10 80 100 30
    $null = Show-UiRegressionScrollTargets -Description 'Settings footer' -AlignBottom -BottomMargin 10 `
        -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $last }
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'Settings positioning must retain footer alignment without sweeping through the whole page.'
    $positions.Clear()
    $first.Current.BoundingRectangle = New-TestRectangle 10 -20 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 180 100 30
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1 -and $first.Current.BoundingRectangle.Top -ge 35) 'Positioning must also move upwards while preserving every target.'
    $scroll.Current.VerticalScrollPercent = 0.0
    $positions.Clear()
    $first.Current.BoundingRectangle = New-TestRectangle 10 100 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 260.5 100 30
    $null = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($positions.Count -eq 1 -and $positions[0] -gt 0 -and $positions[0] -lt 1) 'Sub-percent scroll corrections must not round to an unchanged integer percentage.'
    Assert-Regression ($last.Current.BoundingRectangle.Bottom -eq 290) 'Fractional positioning must retain the full viewport margin without accepting clipped content.'
    $last.Current.BoundingRectangle = New-TestRectangle 10 1000 100 30
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*cannot fit together*'
    $first.Current.BoundingRectangle = New-TestRectangle 10 900 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 1100 100 30
    $scroll.Current.VerticalScrollPercent = 0.0
    $scroll.MoveBounds = $false
    $arguments.TimeoutMilliseconds = 2000
    $before = $positions.Count
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*did not move after a measured scroll adjustment*'
    Assert-Regression ($positions.Count -eq $before + 1) 'An accepted scroll percentage without rendered movement must fail, not repeat or masquerade as visibility.'
    # #670: a request WinUI never applied (unchanged percentage) is reissued, and succeeds once it takes effect.
    $scroll.MoveBounds = $true
    $scroll.Current.VerticalScrollPercent = 0.0
    $first.Current.BoundingRectangle = New-TestRectangle 10 900 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 1100 100 30
    $script:ignoredRequests = 1
    $scroll | Add-Member -Force ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        if ($script:ignoredRequests -gt 0) { $script:ignoredRequests--; return }
        $delta = ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        foreach ($target in @($first, $last)) {
            $bounds = $target.Current.BoundingRectangle
            $target.Current.BoundingRectangle = New-TestRectangle $bounds.Left ($bounds.Top - $delta) $bounds.Width $bounds.Height
        }
    }
    $before = $positions.Count
    $arguments.TimeoutMilliseconds = 5000
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $first -and $positions.Count -eq $before + 2 -and $last.Current.BoundingRectangle.Bottom -eq 290) `
        'An unapplied scroll request must be reissued once and then accepted only from the rendered geometry.'
    $script:ignoredRequests = 99
    $scroll.Current.VerticalScrollPercent = 0.0
    $first.Current.BoundingRectangle = New-TestRectangle 10 900 100 20
    $last.Current.BoundingRectangle = New-TestRectangle 10 1100 100 30
    $before = $positions.Count
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*did not move after a measured scroll adjustment*'
    Assert-Regression ($positions.Count -eq $before + 3) 'A request that is never applied is reissued at most twice before failing.'
    $arguments.TimeoutMilliseconds = 2000
    $scroll.Current.VerticallyScrollable = $false
    Assert-RegressionFailure { Show-UiRegressionScrollTargets @arguments } '*non-scrollable viewport*'

    $viewport = New-BoundedElement 0 0 500 300
    $window = New-BoundedElement 0 0 500 300
    $target = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $true; BoundingRectangle = [pscustomobject]@{
            Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
        }
    } }
    $positions = [Collections.Generic.List[double]]::new()
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    }; DocumentTop = 900.0 }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        $top = $this.DocumentTop - $Percent * 12
        if ($top + 30 -le 0 -or $top -ge 300) {
            $target.Current.IsOffscreen = $true
            $target.Current.BoundingRectangle = [pscustomobject]@{
                Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
            }
        } else {
            $target.Current.IsOffscreen = $false
            $target.Current.BoundingRectangle = New-TestRectangle 10 $top 100 30
        }
    }
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $arguments = @{
        GetViewport = { $viewport }; GetWindow = { $window }; GetTargets = { $target }
        Description = 'offscreen text target'; TopMargin = 35; BottomMargin = 10
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -eq 4) 'An empty offscreen UIA rectangle must trigger bounded discovery followed by measured positioning.'
    Assert-Regression ($target.Current.BoundingRectangle.Top -ge 35 -and $target.Current.BoundingRectangle.Bottom -le 290) 'A discovered target must satisfy the complete viewport margins.'

    $scroll.Current.VerticalScrollPercent = 100
    $positions.Clear()
    $target.Current.IsOffscreen = $true
    $target.Current.BoundingRectangle = [pscustomobject]@{
        Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
    }
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -le 4) 'Unknown bounds from the lower endpoint must discover content by moving back toward the viewport.'

    # Each peer is discoverable in a viewport-sized sweep, but their shared visible range lies between coarse steps.
    $group = @(
        [pscustomobject]@{ DocumentTop = 1000.0; Height = 80.0; Current = $null },
        [pscustomobject]@{ DocumentTop = 1220.0; Height = 40.0; Current = $null }
    )
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    }; Extent = 1200.0 }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        foreach ($peer in $group) {
            $top = $peer.DocumentTop - $Percent * $this.Extent / 100
            $visible = $top + $peer.Height -gt 0 -and $top -lt 300
            $peer.Current = [pscustomobject]@{
                IsOffscreen = -not $visible
                BoundingRectangle = if ($visible) { New-TestRectangle 10 $top 100 $peer.Height }
                    else { [Windows.Rect]::Empty }
            }
        }
    }
    foreach ($startPercent in @(0, 100)) {
        $scroll.SetScrollPercent(-1, $startPercent)
        $positions.Clear()
        $result = Show-UiRegressionScrollTargets -Description 'separately realized grouped peers' `
            -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $group }
        Assert-Regression ($result -eq $group[0] -and $positions.Count -le 6) `
            'Discovering one grouped peer must narrow the search rather than sweep past the shared rendered range.'
        foreach ($peer in $group) {
            Assert-Regression (Test-UiRegressionElementWithin $peer $viewport $window) `
                'Every grouped peer must have real bounds fully contained in the viewport.'
        }
    }
    $group[0].DocumentTop = 100
    $group[1].DocumentTop = 320
    $scroll.Extent = 120000
    $scroll.Current.VerticalViewSize = 100 * 300 / (300 + $scroll.Extent)
    $scroll.SetScrollPercent(-1, 0)
    $positions.Clear()
    $null = Show-UiRegressionScrollTargets -Description 'fractional grouped discovery' `
        -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $group }
    Assert-Regression ($positions.Count -eq 1 -and $positions[0] -gt 0 -and $positions[0] -lt 1) `
        'Fine discovery must preserve sub-percent moves rather than round them to an unchanged percentage.'
    $group[0].DocumentTop = 4000
    $group[1].DocumentTop = 4220
    $scroll.Extent = 1200
    $scroll.Current.VerticalViewSize = 20
    $scroll.SetScrollPercent(-1, 0)
    $positions.Clear()
    Assert-RegressionFailure {
        Show-UiRegressionScrollTargets -Description 'unrealized grouped peers' `
            -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $group }
    } '*no rendered bounds after reaching both scroll limits*'
    Assert-Regression ($positions.Count -le 10) 'Unrealized groups must still fail after a bounded sweep.'

    # A small view whose first measured move overshoots (its extent was still settling) hides the target
    # above the viewport; discovery must search back toward it in viewport-sized steps.
    $overshoot = @{ Top = 280.0; Moves = 0 }
    $positions.Clear()
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 5.0
    } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $pixels = if ($overshoot.Moves++ -eq 0) { 114.0 } else { 57.0 }
        $overshoot.Top -= ($Percent - $this.Current.VerticalScrollPercent) * $pixels
        $this.Current.VerticalScrollPercent = $Percent
        $top = $overshoot.Top
        if ($top + 30 -le 0 -or $top -ge 300) {
            $target.Current.IsOffscreen = $true
            $target.Current.BoundingRectangle = [pscustomobject]@{
                Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true
            }
        } else {
            $target.Current.IsOffscreen = $false
            $target.Current.BoundingRectangle = New-TestRectangle 10 $top 100 30
        }
    }
    $viewport = New-BoundedElement 0 0 500 300
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $scroll }
    $target.Current.IsOffscreen = $false
    $target.Current.BoundingRectangle = New-TestRectangle 10 280 100 30
    $result = Show-UiRegressionScrollTargets -Description 'overshot target' `
        -GetViewport { $viewport } -GetWindow { $window } -GetTargets { $target }
    Assert-Regression ($result -eq $target -and $positions.Count -eq 2 -and $positions[1] -lt $positions[0]) 'A target hidden by an overshooting move must be found by reversing that move.'
    Assert-Regression ($target.Current.BoundingRectangle.Top -ge 0 -and $target.Current.BoundingRectangle.Bottom -le 300) 'The reversed discovery must leave the target inside its viewport.'

    $actual = @{ Top = 285.0; Height = 180.0 }
    $target.Current.IsOffscreen = $false
    $target.Current.BoundingRectangle = New-TestRectangle 10 285 100 15
    $scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 20.0
    } }
    $scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $positions.Add($Percent)
        $actual.Top -= ($Percent - $this.Current.VerticalScrollPercent) * 12
        $this.Current.VerticalScrollPercent = $Percent
        $visibleTop = [Math]::Max(0.0, $actual.Top)
        $visibleBottom = [Math]::Min(300.0, $actual.Top + $actual.Height)
        $target.Current.BoundingRectangle = New-TestRectangle 10 $visibleTop 100 ($visibleBottom - $visibleTop)
    }
    $positions.Clear()
    $result = Show-UiRegressionScrollTargets @arguments
    Assert-Regression ($result -eq $target -and $positions.Count -eq 1) 'A clipped UIA bottom edge must not cause repeated tiny scroll corrections.'
    Assert-Regression ($target.Current.BoundingRectangle.Top -eq 35 -and $target.Current.BoundingRectangle.Height -eq 180) 'Positioning must reveal the full target, not accept its clipped rectangle as its true height.'
}
# #670: identity detail headers keep #657's 16-DIP Back gap, 48-DIP icon slot, 12-DIP title gap and one centered row.
& {
    function New-HeaderRectangle([double] $Left, [double] $Top, [double] $Width, [double] $Height, [double] $Scale = 1) {
        [pscustomobject]@{ Left = $Left * $Scale; Top = $Top * $Scale; Width = $Width * $Scale; Height = $Height * $Scale
            Right = ($Left + $Width) * $Scale; Bottom = ($Top + $Height) * $Scale }
    }
    foreach ($scale in @(1.0, 1.5)) {
        $header = @{
            Back = New-HeaderRectangle 12 100 110 48 $scale
            Icon = New-HeaderRectangle 138 100 48 48 $scale
            Title = New-HeaderRectangle 198 105.5 200 37 $scale
            Secondary = New-HeaderRectangle 198 148 150 19 $scale
            Badge = New-HeaderRectangle 149 152 26 24 $scale
            Scale = $scale; Description = 'Synthetic details'
        }
        Assert-UiRegressionIdentityHeader @header
        foreach ($case in @(
            @{ Key = 'Title'; Value = New-HeaderRectangle 200 105.5 200 37 $scale; Pattern = '*title=*' },
            @{ Key = 'Title'; Value = New-HeaderRectangle 198 100 200 37 $scale; Pattern = '*title=*' },
            @{ Key = 'Icon'; Value = New-HeaderRectangle 138 106 32 32 $scale; Pattern = '*icon=*' },
            @{ Key = 'Icon'; Value = New-HeaderRectangle 142 100 48 48 $scale; Pattern = '*icon=*' },
            @{ Key = 'Secondary'; Value = New-HeaderRectangle 138 148 150 19 $scale; Pattern = '*secondary=*' },
            @{ Key = 'Secondary'; Value = New-HeaderRectangle 198 130 150 19 $scale; Pattern = '*secondary=*' },
            @{ Key = 'Badge'; Value = New-HeaderRectangle 138 152 26 24 $scale; Pattern = '*badge=*' },
            @{ Key = 'Badge'; Value = New-HeaderRectangle 149 120 26 24 $scale; Pattern = '*badge=*' }
        )) {
            $mutated = $header.Clone()
            $mutated[$case.Key] = $case.Value
            Assert-RegressionFailure { Assert-UiRegressionIdentityHeader @mutated } $case.Pattern
        }
        $wide = $header.Clone()
        $wide.Badge = New-HeaderRectangle 138 152 60 24 $scale
        Assert-UiRegressionIdentityHeader @wide
        $wide.Badge = New-HeaderRectangle 126 152 60 24 $scale
        Assert-RegressionFailure { Assert-UiRegressionIdentityHeader @wide } '*badge=*'
    }
}
