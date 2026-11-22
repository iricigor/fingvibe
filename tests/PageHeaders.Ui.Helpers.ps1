function Assert-PageBackGeometry {
    param($Back, $Next, $Text, $Window, [double] $Scale, [double] $ContentLeft, [switch] $Scaled)
    if ($Scale -le 0) {
        throw "Back geometry requires a positive display scale."
    }
    if ($Back.Width -le 0 -or $Back.Height -le 0 -or $Text.Width -le 0 -or $Text.Height -le 0) {
        throw "Back and its single-line destination must be rendered."
    }
    foreach ($bounds in @($Back, $Text)) {
        if ($bounds.Left -lt $Window.Left -or $bounds.Top -lt $Window.Top -or
            $bounds.Right -gt $Window.Right -or $bounds.Bottom -gt $Window.Bottom) {
            throw "Back or its destination is clipped by the window."
        }
    }
    if ($Text.Left -lt $Back.Left -or $Text.Right -gt $Back.Right -or
        $Text.Top -lt $Back.Top -or $Text.Bottom -gt $Back.Bottom) {
        throw "The destination is clipped by Back."
    }
    if ([Math]::Abs($Back.Left - $ContentLeft) / $Scale -gt 1) {
        throw "Back must stay at the shared page-content left edge."
    }
    $sameRow = $Back.Top -lt $Next.Bottom -and $Back.Bottom -gt $Next.Top
    if (($sameRow -and $Back.Right -gt $Next.Left) -or
        (-not $sameRow -and ($Back.Top -gt $Next.Top -or $Back.Left -gt $Next.Left + $Scale))) {
        throw "Back must precede the tabs or tool heading at the left content edge."
    }
    # #658: the shared Back is the 48-DIP header-control height (App.xaml PageHeaderControlHeight) and fits its destination.
    $heightDelta = $Back.Height / $Scale - 48
    if ((-not $Scaled -and [Math]::Abs($heightDelta) -gt 1) -or ($Scaled -and $heightDelta -lt -1)) {
        throw "Back must be the shared 48-DIP header-control height within 1 DIP, or grow for enlarged text (delta $heightDelta DIP)."
    }
    if (($Back.Right - $Text.Right) / $Scale -gt 16) {
        throw "Back must fit its destination text, not a fixed or reference width."
    }
}

function Find-PageHeaderElement {
    param($Root, [string] $Value, [switch] $ByName, $Type, [switch] $AllowOffscreen, [switch] $Raw)
    $property = if ($ByName) { [Windows.Automation.AutomationElement]::NameProperty }
        else { [Windows.Automation.AutomationElement]::AutomationIdProperty }
    $headerCondition = [Windows.Automation.PropertyCondition]::new($property, $Value)
    if ($Type) {
        $headerCondition = [Windows.Automation.AndCondition]::new($headerCondition,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
    }
    $headerWalker = if ($Raw) { [Windows.Automation.TreeWalker]::new($headerCondition) }
    Wait-UiRegressionState -Description "page-header element '$Value'" -Condition {
        $call = Start-UiRegressionCall lookup
        try {
            if ($Raw) {
                $element = $headerWalker.GetFirstChild($Root)
                while ($element) {
                    if ($AllowOffscreen -or (Test-UiRegressionElementVisible $element)) { return $element }
                    $element = $headerWalker.GetNextSibling($element)
                }
            }
            else {
                foreach ($element in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $headerCondition)) {
                    if ($AllowOffscreen -or (Test-UiRegressionElementVisible $element)) { return $element }
                }
            }
        }
        finally { Complete-UiRegressionCall $call }
    }
}

function Show-PageHeaderNavigationItem {
    param($Root, [string] $Id)
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $call = Start-UiRegressionCall lookup
    try { $item = $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition) }
    finally { Complete-UiRegressionCall $call }
    if (-not (Test-UiRegressionElementVisible $item)) {
        (Find-PageHeaderElement $Root TogglePaneButton -Type ([Windows.Automation.ControlType]::Button)).
            GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    return Find-PageHeaderElement $Root $Id
}

function Test-PageBackHeaders {
    param($Root, [IntPtr] $WindowHandle, [string] $Directory, [string] $Variant,
        [scriptblock] $OpenDetails, [switch] $Scaled)
    $phase = Start-UiRegressionPhase -Name "headers/$Variant"
    $succeeded = $false
    try {
        # An offscreen Back makes the caller fall back to the unavailable narrow sidebar.
        $back = Find-PageHeaderElement $Root 'Back to devices' -ByName `
            -Type ([Windows.Automation.ControlType]::Button) -AllowOffscreen
        $back.SetFocus()
        $null = Find-PageHeaderElement $Root 'Back to devices' -ByName -Type ([Windows.Automation.ControlType]::Button)
        & $OpenDetails
        $back = Find-PageHeaderElement $Root 'Back to devices' -ByName `
            -Type ([Windows.Automation.ControlType]::Button) -AllowOffscreen
        $back.SetFocus()
        $scale = [UiReviewNativeWindow]::GetDpiForWindow($WindowHandle) / 96.0
        $viewport = (Find-PageHeaderElement $Root DeviceDetailsScroll).Current.BoundingRectangle
        $contentLeft = $viewport.Left
        foreach ($tab in @('Overview', 'History')) {
            $item = Find-PageHeaderElement $Root "Device${tab}Tab"
            $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Save-PageBackHeader $Root $WindowHandle $Directory "$Variant-details-$tab" `
                'Back to devices' 'Devices' $scale $contentLeft `
                -NextId "Device${tab}Tab" -Scaled:$Scaled
        }
        # #670: the identity header keeps #657's icon and title positions; the tabs stay below it until #659.
        $status = Find-PageHeaderElement $Root DeviceStatusText -AllowOffscreen
        Assert-UiRegressionIdentityHeader -Back (Find-PageHeaderElement $Root DeviceBackButton).Current.BoundingRectangle `
            -Icon (Find-PageHeaderElement $Root DeviceTypeIcon).Current.BoundingRectangle `
            -Title (Find-PageHeaderElement $Root DeviceNameText).Current.BoundingRectangle `
            -Secondary $(if (Test-UiRegressionElementVisible $status) { $status.Current.BoundingRectangle }) `
            -Scale $scale -Description "Device details ($Variant)"
        $back = Find-PageHeaderElement $Root 'Back to devices' -ByName -Type ([Windows.Automation.ControlType]::Button)
        $back.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        $null = Find-PageHeaderElement $Root ResultsList
        (Show-PageHeaderNavigationItem $Root ToolsNavItem).GetCurrentPattern(
            [Windows.Automation.SelectionItemPattern]::Pattern).Select()
        foreach ($page in @(
            @{ Card = 'SqlEditorCard'; Title = 'SQL editor' },
            @{ Card = 'FingImportCard'; Title = 'Import from Fing' },
            @{ Card = 'SpeedTestCard'; Title = 'Speed test' },
            @{ Card = 'NetworkHealthCard'; Title = 'Network health' },
            @{ Card = 'DatabaseBackupsCard'; Title = 'Database backups' }
        )) {
            $card = Find-PageHeaderElement $Root $page.Card -AllowOffscreen
            if (-not $card.Current.IsEnabled) {
                throw "Expected reachable tool '$($page.Title)' is disabled; reconcile current scope instead of bypassing it."
            }
            $card.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            Save-PageBackHeader $Root $WindowHandle $Directory "$Variant-$($page.Card)" `
                'Back to Tools' 'Tools' $scale $contentLeft -NextName $page.Title -Scaled:$Scaled
            $back = Find-PageHeaderElement $Root 'Back to Tools' -ByName -Type ([Windows.Automation.ControlType]::Button)
            $back.SetFocus()
            [System.Windows.Forms.SendKeys]::SendWait(' ')
            $null = Find-PageHeaderElement $Root ToolsLanding
        }
        (Show-PageHeaderNavigationItem $Root OverviewNavItem).GetCurrentPattern(
            [Windows.Automation.SelectionItemPattern]::Pattern).Select()
        (Find-PageHeaderElement $Root 'About FingVibe' -ByName -Type ([Windows.Automation.ControlType]::Button) -AllowOffscreen).
            GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        Save-PageBackHeader $Root $WindowHandle $Directory "$Variant-About" `
            'Back to Settings' 'Settings' $scale $contentLeft -NextId PageHeading -Scaled:$Scaled
        $back = Find-PageHeaderElement $Root 'Back to Settings' -ByName -Type ([Windows.Automation.ControlType]::Button)
        $back.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        $null = Wait-UiRegressionState -Description 'About return restores Settings row focus' -Condition {
            $focused = [Windows.Automation.AutomationElement]::FocusedElement
            $focused.Current.Name -eq 'About FingVibe & updates' -and $focused.Current.HasKeyboardFocus
        }
        $null = Show-PageHeaderNavigationItem $Root DevicesNavItem
        & $OpenDetails
        $succeeded = $true
    }
    finally { Complete-UiRegressionPhase -Phase $phase -Directory $Directory -Succeeded $succeeded }
}

function Save-PageBackHeader {
    param($Root, [IntPtr] $WindowHandle, [string] $Directory, [string] $Name,
        [string] $BackName, [string] $Caption, [double] $Scale, [double] $ContentLeft,
        [string] $NextId, [string] $NextName, [switch] $Scaled)
    $back = Find-PageHeaderElement $Root $BackName -ByName -Type ([Windows.Automation.ControlType]::Button) -AllowOffscreen
    $back.SetFocus()
    $back = Find-PageHeaderElement $Root $BackName -ByName -Type ([Windows.Automation.ControlType]::Button)
    if (-not $back.Current.HasKeyboardFocus) { throw "$BackName must accept keyboard focus." }
    # The shared Back's destination text is raw-only; keep its actual text bounds, not the Button's.
    $text = Find-PageHeaderElement $back $Caption -ByName -Type ([Windows.Automation.ControlType]::Text) -Raw
    $next = if ($NextId) { Find-PageHeaderElement $Root $NextId }
        else { Find-PageHeaderElement $Root $NextName -ByName -Type ([Windows.Automation.ControlType]::Text) }
    $bounds = $back.Current.BoundingRectangle
    Assert-PageBackGeometry $bounds $next.Current.BoundingRectangle `
        $text.Current.BoundingRectangle $Root.Current.BoundingRectangle $Scale $ContentLeft -Scaled:$Scaled
    [pscustomobject]@{
        name = $Name; dpi = $Scale * 96; backWidthDip = $bounds.Width / $Scale; backHeightDip = $bounds.Height / $Scale
        enlargedText = [bool]$Scaled
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $Directory 'back-header-measurements.jsonl') -Encoding UTF8
    Save-UiReviewWindowScreenshot $WindowHandle (Join-Path $Directory "back-$Name.png")
}
