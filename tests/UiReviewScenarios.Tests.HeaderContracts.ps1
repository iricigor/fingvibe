# Page contracts: shared page headers.
& {
    . (Join-Path $PSScriptRoot 'PageHeaders.Ui.Helpers.ps1')
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    & {
        $hidden = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $true
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 44 }
        } }
        $empty = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $true; Width = 0; Height = 0 }
        } }
        $visible = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 44 }
        } }
        $lookupRoot = [pscustomobject]@{
            Elements = @($hidden, $empty, $visible)
            Queries = [Collections.Generic.List[object]]::new()
            MissingOnce = $true
            Failure = $false
        }
        $lookupRoot | Add-Member ScriptMethod FindAll {
            param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
            if ($Scope -ne [Windows.Automation.TreeScope]::Descendants) { throw 'Wrong header lookup scope.' }
            $this.Queries.Add($Query)
            if ($this.Failure) { throw 'Header provider failed.' }
            if ($this.MissingOnce) { $this.MissingOnce = $false; return }
            $this.Elements
        }
        $found = Find-PageHeaderElement $lookupRoot DeviceOverviewTab
        if (-not [object]::ReferenceEquals($found, $visible)) {
            throw 'Header lookup must wait for a peer and skip offscreen/empty bounds.'
        }
        Assert-Equal $lookupRoot.Queries.Count 2 'Header lookup retries a missing peer through the real waiter'
        $query = $lookupRoot.Queries[0]
        Assert-Equal $query.Property ([Windows.Automation.AutomationElement]::AutomationIdProperty) 'Header ID lookup property'
        Assert-Equal $query.Value DeviceOverviewTab 'Header ID lookup value'
        $found = Find-PageHeaderElement $lookupRoot 'Back to devices' -ByName `
            -Type ([Windows.Automation.ControlType]::Button) -AllowOffscreen
        if (-not [object]::ReferenceEquals($found, $hidden)) {
            throw 'Explicit offscreen lookup must retain the actual peer for positioning.'
        }
        $conditions = $lookupRoot.Queries[2].GetConditions()
        Assert-Equal $conditions[0].Property ([Windows.Automation.AutomationElement]::NameProperty) 'Header name lookup property'
        Assert-Equal $conditions[0].Value 'Back to devices' 'Header name lookup value'
        Assert-Equal $conditions[1].Property ([Windows.Automation.AutomationElement]::ControlTypeProperty) 'Header control type property'
        Assert-Equal $conditions[1].Value ([Windows.Automation.ControlType]::Button.Id) 'Header control type value'
        $lookupRoot.Failure = $true
        Assert-Throws { Find-PageHeaderElement $lookupRoot BrokenHeader } '*Header provider failed*'
        Assert-Equal $script:UiRegressionCallStack.Count 0 'Failed header lookups complete call accounting'
    }
    $rect = {
        param($Left, $Top, $Width, $Height)
        [pscustomobject]@{ Left = $Left; Top = $Top; Width = $Width; Height = $Height
            Right = $Left + $Width; Bottom = $Top + $Height }
    }
    $back = & $rect 10 10 100 44
    $reference = & $rect 126 10 100 44
    $text = & $rect 20 22 75 20
    $window = & $rect 0 0 500 500
    & {
        $caption = "$([char]0x2190) Devices"
        $captionPeer = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = $text
        } }
        $hiddenCaption = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $true; BoundingRectangle = $text
        } }
        $emptyCaption = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ IsEmpty = $true; Width = 0; Height = 0 }
        } }
        $captionButton = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; HasKeyboardFocus = $false; BoundingRectangle = $back
        } }
        $captionButton | Add-Member ScriptMethod SetFocus { $this.Current.HasKeyboardFocus = $true }
        $captionButton | Add-Member ScriptMethod FindAll { throw 'Caption is raw-only; control-view FindAll cannot measure it.' }
        $captionState = @{ Root = $captionButton; Nodes = @($hiddenCaption, $emptyCaption, $captionPeer)
            Index = 0; Calls = 0; MissingOnce = $true; Failure = $false }
        function New-PageHeaderWalkerDouble([Windows.Automation.Condition] $HeaderQuery) {
            $conditions = $HeaderQuery.GetConditions()
            Assert-Equal $conditions.Count 2 'Raw caption must retain both Name and Text type conditions'
            Assert-Equal $conditions[0].Property ([Windows.Automation.AutomationElement]::NameProperty) 'Raw caption selector property'
            Assert-Equal $conditions[0].Value $caption 'Raw caption selector value'
            Assert-Equal $conditions[1].Property ([Windows.Automation.AutomationElement]::ControlTypeProperty) 'Raw caption type property'
            Assert-Equal $conditions[1].Value ([Windows.Automation.ControlType]::Text.Id) 'Raw caption type value'
            $walker = [pscustomobject]@{ State = $captionState }
            $walker | Add-Member ScriptMethod GetFirstChild {
                param($Owner)
                if (-not [object]::ReferenceEquals($Owner, $this.State.Root)) { throw 'Raw caption search escaped its Back button.' }
                $this.State.Calls++
                if ($this.State.Failure) { throw 'Raw caption provider failed.' }
                if ($this.State.MissingOnce) { $this.State.MissingOnce = $false; return }
                $this.State.Index = 0
                $this.State.Nodes[0]
            }
            $walker | Add-Member ScriptMethod GetNextSibling {
                param($Peer)
                if (-not [object]::ReferenceEquals($Peer, $this.State.Nodes[$this.State.Index])) {
                    throw 'Raw caption walker must advance from the actual matching peer.'
                }
                $this.State.Index++
                if ($this.State.Index -lt $this.State.Nodes.Count) { $this.State.Nodes[$this.State.Index] }
            }
            return $walker
        }
        # Substitute only the native walker constructor; execute the real lookup and waiter.
        $lookupBody = (Get-Command Find-PageHeaderElement).Definition.Replace(
            '[Windows.Automation.TreeWalker]::new($headerCondition)', 'New-PageHeaderWalkerDouble $headerCondition')
        . ([scriptblock]::Create("function Find-PageHeaderElement {`n$lookupBody`n}"))
        $found = Find-PageHeaderElement $captionButton $caption -ByName -Type ([Windows.Automation.ControlType]::Text) -Raw
        if (-not [object]::ReferenceEquals($found, $captionPeer) -or
            -not [object]::ReferenceEquals($found.Current.BoundingRectangle, $text)) {
            throw 'Measure the actual rendered caption peer, never its Button or estimated bounds.'
        }
        Assert-Equal $captionState.Calls 2 'Raw caption discovery retries missing peers through the actual waiter'
        Assert-PageBackGeometry $back $reference $reference $found.Current.BoundingRectangle $window 1 10
        $found = Find-PageHeaderElement $captionButton $caption -ByName -Type ([Windows.Automation.ControlType]::Text) -Raw -AllowOffscreen
        if (-not [object]::ReferenceEquals($found, $hiddenCaption)) { throw 'Explicit raw offscreen lookup lost the actual peer.' }
        $captionState.Failure = $true
        Assert-Throws {
            Find-PageHeaderElement $captionButton $caption -ByName -Type ([Windows.Automation.ControlType]::Text) -Raw
        } '*Raw caption provider failed*'
        Assert-Equal $script:UiRegressionCallStack.Count 0 'Failed raw-caption lookup completes call accounting'
        $captionState.Failure = $false
        $measurementRoot = [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = $window } }
        $measurementRoot | Add-Member ScriptMethod FindAll {
            param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $HeaderQuery)
            if ($Scope -ne [Windows.Automation.TreeScope]::Descendants) { throw 'Wrong measurement lookup scope.' }
            if ($HeaderQuery -is [Windows.Automation.AndCondition] -and
                $HeaderQuery.GetConditions()[0].Value -eq 'Back to devices') { return $captionButton }
            if ($HeaderQuery.Value -eq 'DeviceOverviewTab') {
                return [pscustomobject]@{ Current = [pscustomobject]@{
                    IsOffscreen = $false; BoundingRectangle = $reference
                } }
            }
            throw 'Unexpected measurement lookup.'
        }
        $captures = [Collections.Generic.List[string]]::new()
        function Save-UiReviewWindowScreenshot($Handle, $Path) { $captures.Add($Path) }
        $measurementDirectory = Join-Path ([IO.Path]::GetTempPath()) "FingVibe-PageHeader-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $measurementDirectory
        try {
            Save-PageBackHeader $measurementRoot ([IntPtr]::Zero) $measurementDirectory 'raw-caption' `
                'Back to devices' $caption $reference 1 10 -NextId DeviceOverviewTab
            Assert-Equal $captures.Count 1 'Real header measurement reaches its existing capture boundary'
            Assert-Equal $captures[0] (Join-Path $measurementDirectory 'back-raw-caption.png') 'Header capture identity'
            $measurement = Get-Content (Join-Path $measurementDirectory 'back-header-measurements.jsonl') -Raw | ConvertFrom-Json
            Assert-Equal $measurement.backWidthDip 100 'Measurement retains actual Back bounds independently of caption bounds'
        }
        finally { Remove-Item -LiteralPath $measurementDirectory -Recurse -Force }
    }
    & {
        $headerStatements = @(((Get-Command Test-PageBackHeaders).ScriptBlock.Ast.Body.EndBlock.Statements |
            Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }).Body.Statements)
        $callback = @($headerStatements | Where-Object { $_.Extent.Text -eq '& $OpenDetails' })[0]
        $entryEnd = [array]::IndexOf($headerStatements, $callback)
        if ($entryEnd -lt 0) { throw 'Expected the existing Details-entry callback.' }
        $detailsEntry = [scriptblock]::Create(($headerStatements[0..$entryEnd].Extent.Text -join "`n"))
        $usageAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'UsageCategory.Ui.Tests.ps1'), [ref]$null, [ref]$null)
        $findUsage = $usageAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-Usage'
        }, $true)
        . ([scriptblock]::Create($findUsage.Extent.Text))
        $openUsage = $usageAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Open-UsageDevice'
        }, $true)
        # Execute the caller's real navigation branch, before row search and desktop keyboard input.
        $OpenDetails = [scriptblock]::Create(($openUsage.Body.EndBlock.Statements[0..1].Extent.Text -join "`n"))
        $originalRoot = $script:root
        try {
            foreach ($offscreen in @($true, $false)) {
                $entryState = @{ Events = [Collections.Generic.List[string]]::new()
                    FocusRequested = $false; Settling = $false; FocusFailure = $false }
                $backAction = [pscustomobject]@{}
                $backAction | Add-Member ScriptMethod Invoke { $entryState.Events.Add('invoke:Back') }
                $backPeer = [pscustomobject]@{ Current = [pscustomobject]@{
                    IsOffscreen = $offscreen; BoundingRectangle = $back
                } }
                $backPeer | Add-Member ScriptMethod SetFocus {
                    $entryState.Events.Add('focus:Back')
                    if ($entryState.FocusFailure) { throw 'Header entry focus failed.' }
                    $entryState.FocusRequested = $true
                    $entryState.Settling = $true
                }
                $backPeer | Add-Member ScriptMethod GetCurrentPattern {
                    param($PatternId)
                    Assert-Equal $PatternId ([Windows.Automation.InvokePattern]::Pattern) 'Details entry retains Back invocation'
                    return $backAction
                }
                $Root = [pscustomobject]@{}
                $Root | Add-Member ScriptMethod FindFirst {
                    param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
                    Assert-Equal $Scope ([Windows.Automation.TreeScope]::Descendants) 'Caller navigation lookup scope'
                    if ($Query.Property -eq [Windows.Automation.AutomationElement]::NameProperty -and
                        $Query.Value -eq 'Back to devices') { return $backPeer }
                    if ($Query.Value -in @('DevicesNavItem', 'DeviceOverviewTab')) { return }
                    throw "Unexpected caller navigation lookup '$($Query.Value)'."
                }
                $Root | Add-Member ScriptMethod FindAll {
                    param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
                    Assert-Equal $Scope ([Windows.Automation.TreeScope]::Descendants) 'Header entry lookup scope'
                    $conditions = $Query.GetConditions()
                    Assert-Equal $conditions[0].Property ([Windows.Automation.AutomationElement]::NameProperty) 'Details entry Back name selector'
                    Assert-Equal $conditions[0].Value 'Back to devices' 'Details entry Back identity'
                    Assert-Equal $conditions[1].Value ([Windows.Automation.ControlType]::Button.Id) 'Details entry Back type'
                    if ($entryState.FocusRequested) {
                        if ($entryState.Settling) { $entryState.Settling = $false }
                        else { $backPeer.Current.IsOffscreen = $false }
                    }
                    return $backPeer
                }
                $script:root = $Root
                & $detailsEntry
                Assert-Equal $entryState.Events @('focus:Back', 'invoke:Back') 'Entry must position and await Back before the actual caller chooses navigation'
                Assert-Equal $script:UiRegressionCallStack.Count 0 'Details entry completes real lookup/wait accounting'
                $entryState.Events.Clear()
                $entryState.FocusFailure = $true
                Assert-Throws { & $detailsEntry } '*Header entry focus failed*'
                Assert-Equal $entryState.Events @('focus:Back') 'Failed positioning must not invoke the caller'
            }
        }
        finally { $script:root = $originalRoot }
    }
    & {
        $headerStatements = @(((Get-Command Test-PageBackHeaders).ScriptBlock.Ast.Body.EndBlock.Statements |
            Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }).Body.Statements)
        $toolsLoop = @($headerStatements | Where-Object {
            $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Extent.Text.Contains('DatabaseBackupsCard')
        })[0]
        $toolsIndex = [array]::IndexOf($headerStatements, $toolsLoop)
        $returnWait = @($headerStatements | Where-Object {
            $_.Extent.Text.Contains("Description 'About return restores Settings row focus'")
        })[0]
        $returnIndex = [array]::IndexOf($headerStatements, $returnWait) + 1
        $navigationSteps = @(
            [scriptblock]::Create($headerStatements[$toolsIndex - 1].Extent.Text)
            [scriptblock]::Create($headerStatements[$toolsIndex + 1].Extent.Text)
            [scriptblock]::Create(($headerStatements[$returnIndex..($headerStatements.Count - 2)].Extent.Text -join "`n"))
        )
        $usageAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'UsageCategory.Ui.Tests.ps1'), [ref]$null, [ref]$null)
        $findUsage = $usageAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-Usage'
        }, $true)
        . ([scriptblock]::Create($findUsage.Extent.Text))
        $openUsage = $usageAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Open-UsageDevice'
        }, $true)
        $OpenDetails = [scriptblock]::Create(($openUsage.Body.EndBlock.Statements[0..1].Extent.Text -join "`n"))
        $originalRoot = $script:root
        try {
            foreach ($mode in @('absent', 'offscreen', 'visible')) {
                $navigationState = @{ Mode = $mode; Expanded = $mode -eq 'visible'; Opening = $false
                    Settling = $false; Failure = $false; Events = [Collections.Generic.List[string]]::new() }
                $toggleAction = [pscustomobject]@{}
                $toggleAction | Add-Member ScriptMethod Invoke {
                    $navigationState.Events.Add('open-pane')
                    if ($navigationState.Failure) { throw 'Header navigation toggle failed.' }
                    $navigationState.Opening = $true
                    $navigationState.Settling = $true
                }
                $togglePeer = [pscustomobject]@{ Current = [pscustomobject]@{
                    IsOffscreen = $false; BoundingRectangle = $reference
                } }
                $togglePeer | Add-Member ScriptMethod GetCurrentPattern {
                    param($PatternId)
                    Assert-Equal $PatternId ([Windows.Automation.InvokePattern]::Pattern) 'Header navigation opens the real pane toggle'
                    return $toggleAction
                }
                $Root = [pscustomobject]@{}
                $Root | Add-Member ScriptMethod FindAll {
                    param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
                    Assert-Equal $Scope ([Windows.Automation.TreeScope]::Descendants) 'Header navigation lookup scope'
                    $id = if ($Query -is [Windows.Automation.AndCondition]) { $Query.GetConditions()[0].Value } else { $Query.Value }
                    if ($id -in @('Back to devices', 'DeviceOverviewTab')) { return }
                    if ($id -eq 'TogglePaneButton') { return $togglePeer }
                    if ($id -notin @('ToolsNavItem', 'OverviewNavItem', 'DevicesNavItem')) {
                        throw "Unexpected header navigation lookup '$id'."
                    }
                    if ($navigationState.Opening) {
                        if ($navigationState.Settling) { $navigationState.Settling = $false; return }
                        $navigationState.Opening = $false
                        $navigationState.Expanded = $true
                    }
                    if (-not $navigationState.Expanded -and $navigationState.Mode -eq 'absent') { return }
                    $selection = [pscustomobject]@{ Id = $id; Visible = $navigationState.Expanded }
                    $selection | Add-Member ScriptMethod Select {
                        if (-not $this.Visible -or -not $navigationState.Expanded) { throw 'Cannot select hidden navigation.' }
                        $navigationState.Events.Add("select:$($this.Id)")
                        if ($navigationState.Mode -ne 'visible') { $navigationState.Expanded = $false }
                    }
                    $peer = [pscustomobject]@{ Selection = $selection; Current = [pscustomobject]@{
                        IsOffscreen = -not $navigationState.Expanded; BoundingRectangle = $reference
                    } }
                    $peer | Add-Member ScriptMethod GetCurrentPattern {
                        param($PatternId)
                        Assert-Equal $PatternId ([Windows.Automation.SelectionItemPattern]::Pattern) 'Header navigation preserves page selection'
                        return $this.Selection
                    }
                    return $peer
                }
                $Root | Add-Member ScriptMethod FindFirst {
                    param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
                    $this.FindAll($Scope, $Query) | Select-Object -First 1
                }
                $script:root = $Root
                foreach ($step in $navigationSteps) { & $step }
                $expected = foreach ($id in @('ToolsNavItem', 'OverviewNavItem', 'DevicesNavItem')) {
                    if ($mode -ne 'visible') { 'open-pane' }
                    "select:$id"
                }
                Assert-Equal $navigationState.Events $expected 'Every header page boundary reveals hidden navigation without closing an expanded pane'
                Assert-Equal $script:UiRegressionCallStack.Count 0 'Header navigation completes lookup accounting'
                if ($mode -ne 'visible') {
                    $navigationState.Events.Clear()
                    $navigationState.Failure = $true
                    Assert-Throws { & $navigationSteps[0] } '*Header navigation toggle failed*'
                    Assert-Equal $navigationState.Events @('open-pane') 'Failed pane opening must not select a page'
                }
            }
        }
        finally { $script:root = $originalRoot }
    }
    & {
        $headerStatements = @(((Get-Command Test-PageBackHeaders).ScriptBlock.Ast.Body.EndBlock.Statements |
            Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }).Body.Statements)
        $toolsLoop = @($headerStatements | Where-Object {
            $_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Extent.Text.Contains('DatabaseBackupsCard')
        })
        $aboutCapture = @($headerStatements | Where-Object { $_.Extent.Text.StartsWith('Save-PageBackHeader ') })
        if ($toolsLoop.Count -ne 1 -or $aboutCapture.Count -ne 1) { throw 'Expected one Tools-to-About entry boundary.' }
        $entryStart = [array]::IndexOf($headerStatements, $toolsLoop[0]) + 1
        $entryEnd = [array]::IndexOf($headerStatements, $aboutCapture[0]) - 1
        if ($entryStart -gt $entryEnd) { throw 'About must be opened before its header capture.' }
        $aboutEntry = [scriptblock]::Create(($headerStatements[$entryStart..$entryEnd].Extent.Text -join "`n"))
        $entryState = @{ Page = 'ToolsLanding'; Events = [Collections.Generic.List[string]]::new() }
        $overviewAction = [pscustomobject]@{}
        $overviewAction | Add-Member ScriptMethod Select {
            $entryState.Events.Add('select:Overview')
            $entryState.Page = 'Overview'
        }
        $aboutAction = [pscustomobject]@{}
        $aboutAction | Add-Member ScriptMethod Invoke {
            $entryState.Events.Add('invoke:About')
            $entryState.Page = 'About'
        }
        $overviewPeer = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = $reference
        } }
        $overviewPeer | Add-Member ScriptMethod GetCurrentPattern {
            param($PatternId)
            Assert-Equal $PatternId ([Windows.Automation.SelectionItemPattern]::Pattern) 'Overview entry uses existing selection pattern'
            return $overviewAction
        }
        $aboutPeer = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = $back
        } }
        $aboutPeer | Add-Member ScriptMethod GetCurrentPattern {
            param($PatternId)
            Assert-Equal $PatternId ([Windows.Automation.InvokePattern]::Pattern) 'About entry uses existing invocation pattern'
            return $aboutAction
        }
        $Root = [pscustomobject]@{}
        $Root | Add-Member ScriptMethod FindAll {
            param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $HeaderQuery)
            Assert-Equal $Scope ([Windows.Automation.TreeScope]::Descendants) 'About entry lookup scope'
            if ($HeaderQuery -is [Windows.Automation.PropertyCondition]) {
                Assert-Equal $HeaderQuery.Property ([Windows.Automation.AutomationElement]::AutomationIdProperty) 'Overview navigation identity property'
                Assert-Equal $HeaderQuery.Value OverviewNavItem 'Overview navigation identity'
                return $overviewPeer
            }
            $conditions = $HeaderQuery.GetConditions()
            Assert-Equal $conditions.Count 2 'About entry retains exact Name and Button selectors'
            Assert-Equal $conditions[0].Property ([Windows.Automation.AutomationElement]::NameProperty) 'About entry name property'
            Assert-Equal $conditions[0].Value 'About FingVibe' 'About entry name'
            Assert-Equal $conditions[1].Property ([Windows.Automation.AutomationElement]::ControlTypeProperty) 'About entry control type property'
            Assert-Equal $conditions[1].Value ([Windows.Automation.ControlType]::Button.Id) 'About entry control type'
            if ($entryState.Page -ne 'Overview') { throw "About entry requires Overview, not $($entryState.Page)." }
            $entryState.Events.Add('lookup:About')
            return $aboutPeer
        }
        $Root | Add-Member ScriptMethod FindFirst {
            param([Windows.Automation.TreeScope] $Scope, [Windows.Automation.Condition] $Query)
            $this.FindAll($Scope, $Query) | Select-Object -First 1
        }
        # Narrow or enlarged-text Overview keeps the About card below the fold.
        foreach ($aboutOffscreen in @($false, $true)) {
            $entryState.Page = 'ToolsLanding'
            $entryState.Events.Clear()
            $aboutPeer.Current.IsOffscreen = $aboutOffscreen
            & $aboutEntry
            Assert-Equal $entryState.Events @('select:Overview', 'lookup:About', 'invoke:About') 'Real About entry must navigate from Tools before looking up its Button'
            Assert-Equal $entryState.Page About 'About is opened before header measurement'
            Assert-Equal $script:UiRegressionCallStack.Count 0 'About entry completes real lookup/wait accounting'
        }
    }
    Assert-PageBackGeometry $back $reference $reference $text $window 1 10
    Assert-PageBackGeometry $back $reference (& $rect 10 70 100 44) $text $window 1 10
    Assert-PageBackGeometry (& $rect 10 10 150 66) $reference (& $rect 180 10 100 44) $text $window 1 10 -Scaled
    Assert-PageBackGeometry (& $rect 10 10 150 66) (& $rect 180 10 150 66) `
        (& $rect 180 10 150 66) $text $window 1.5 10
    Assert-Throws {
        Assert-PageBackGeometry (& $rect 10 10 102 44) $reference $reference $text $window 1 10
    } '*within 1 DIP*'
    Assert-Throws {
        Assert-PageBackGeometry $back (& $rect 122 6 108 52) $reference $text $window 1 10
    } '*within 1 DIP*'
    Assert-Throws {
        Assert-PageBackGeometry $back $reference (& $rect 0 10 100 44) $text $window 1 10
    } '*precede*'
    Assert-Throws {
        Assert-PageBackGeometry $back $reference $reference (& $rect 20 22 100 20) $window 1 10
    } '*clipped by Back*'
    Assert-Throws {
        Assert-PageBackGeometry $back $reference $reference $text $window 1 0
    } '*content left edge*'
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'PageHeaders.Ui.Helpers.ps1'), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join '; ') }
}
