$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScenarios.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewNavigation.ps1")

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$($Expected -join ', ')', got '$($Actual -join ', ')'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

& {
    [xml] $page = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml") -Raw
    $namespaces = [System.Xml.XmlNamespaceManager]::new($page.NameTable)
    $namespaces.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")
    $history = $page.SelectSingleNode("//*[@x:Name='DeviceScanHistoryExpander']", $namespaces)
    Assert-Equal $history.IsExpanded "True" "Completed observations starts expanded"
    Assert-Equal $history.Header "Completed Scan Observations" "Completed observations header"
    Assert-Equal $history.GetAttribute("Visibility") "" "Completed observations uses visible layout"
    if (-not $history.SelectSingleNode(".//*[local-name()='ScrollViewer' and @x:Name='DeviceScanHistoryList']/*[local-name()='ItemsControl' and @x:Name='DeviceScanHistoryRows']", $namespaces)) {
        throw "The bounded observation page must keep stable, non-recycled rows."
    }
    Assert-Equal $history.SelectSingleNode(".//*[@x:Name='DeviceScanHistoryList']", $namespaces).IsTabStop "True" "The observation viewport must be reachable by keyboard focus"
    $activity = $page.SelectSingleNode("//*[@x:Name='DeviceActivityCard']", $namespaces)
    Assert-Equal $activity.GetAttribute("Visibility") "" "Restored Activity uses normal visible layout"
    foreach ($id in @("DeviceScanHistoryTable", "DeviceScanHistoryEmpty",
        "DeviceHistoryNewer", "DeviceHistoryOlder", "DeviceHistoryPageStatus")) {
        if (-not $history.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be inside completed observations." }
    }
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistoryState", "DeviceHistorySince",
        "DeviceHistoryScope", "DeviceHistoryLatest")) {
        if (-not $page.SelectSingleNode("//*[@x:Name='$id']", $namespaces)) { throw "Retained summary lacks $id." }
        if ($history.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must remain outside collapsed observations." }
    }
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1") -Raw
    $tabs = $page.SelectSingleNode("//*[@x:Name='DetailsTabs']", $namespaces)
    Assert-Equal $tabs.LocalName "SelectorBar" "Device Details uses local section tabs"
    Assert-Equal (@($tabs.ChildNodes | ForEach-Object { $_.Text }) -join "|") "Overview|History" "Device Details tab order"
    Assert-Equal $tabs.FirstChild.IsSelected "True" "Overview is the initial tab"
    $overviewPanel = $page.SelectSingleNode("//*[@x:Name='OverviewPanel']", $namespaces)
    $historyPanel = $page.SelectSingleNode("//*[@x:Name='HistoryPanel']", $namespaces)
    Assert-Equal $historyPanel.Visibility "Collapsed" "History starts hidden"
    foreach ($id in @("DetailsColumns", "IdentificationCard", "PortsServicesCard", "DeviceHistorySummaryCard",
        "DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistoryState", "DeviceHistorySince", "DeviceViewHistory")) {
        if (-not $overviewPanel.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be on the Overview tab." }
    }
    foreach ($id in @("DeviceActivityCard", "DeviceHistoryScope", "DeviceHistoryLatest", "DeviceScanHistoryExpander", "VirtualDeviceHistoryCard")) {
        if (-not $historyPanel.SelectSingleNode(".//*[@x:Name='$id']", $namespaces)) { throw "$id must be on the History tab." }
    }
    $header = $page.SelectSingleNode("//*[@x:Name='HeaderGrid']", $namespaces)
    if (-not $header.SelectSingleNode(".//*[@x:Name='DetailsTabs']", $namespaces) -or
        -not $header.SelectSingleNode(".//*[@x:Name='DeviceNameValue']", $namespaces) -or
        -not $header.SelectSingleNode(".//*[@x:Name='DeviceBackButton']", $namespaces)) {
        throw "Back, segmented tabs and identity must share the responsive details header."
    }
    $columns = $page.SelectSingleNode("//*[@x:Name='DetailsColumns']", $namespaces)
    foreach ($id in @("NetworkOverviewCard", "AssignmentsCard", "DeviceHistorySummaryCard", "UsageCategoryCard")) {
        if (-not $columns.SelectSingleNode("./*[@x:Name='$id']", $namespaces)) {
            throw "$id must share the two-row aligned summary grid."
        }
    }
    $detailsCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml.cs") -Raw
    if ($detailsCode -notmatch '(?s)internal void ShowDevice\(.*?DetailsTabs\.SelectedItem = OverviewTab;') {
        throw "Opening a device must reset Device Details to Overview."
    }
    if ($historyUi -notmatch 'Test-HistoryTabs' -or $historyUi -notmatch 'DeviceOverviewTab') {
        throw "Native history checks must cover tab switching, retained drafts and the initial Overview tab."
    }
    if ($historyUi -notmatch '\$env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"') {
        throw "History fixtures must select their own network independently of preceding suites."
    }
    $summaryAssertion = [regex]::Match($historyUi, '(?s)function Assert-HistorySummary.*?(?=function Invoke-HistoryScan)').Value
    if ($summaryAssertion -notmatch 'Show-HistorySection \$id' -or
        $summaryAssertion -match 'DeviceHistorySummaryCard') {
        throw "Summary checks must position disclosed text peers individually, not a Border without an automation peer."
    }
    $code = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.xaml.cs") -Raw
    foreach ($pattern in @(
        'internal static bool CompletedObservationsEnabled => true;',
        '(?m)^        InitializeActivity\(\);',
        '(?s)if \(CompletedObservationsEnabled\)\s*\{\s*ApplyHistoryPage\(DeviceHistoryQuery.ReadPage',
        '(?s)HistoryPage_Click.*?\{\s*if \(!CompletedObservationsEnabled\) return;'
    )) {
        if ($code -notmatch $pattern) { throw "Missing reversible history lifecycle guard: $pattern" }
    }
    $itemCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceScanHistoryItem.cs") -Raw
    if ($itemCode -notmatch 'AutomationControlType.DataItem' -or $itemCode -notmatch 'IScrollItemProvider' -or
        $itemCode -notmatch 'owner.StartBringIntoView') {
        throw "Passive observation rows must retain accessible data-item and bring-into-view support."
    }
    $activityCode = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\Views\DeviceDetailsPageView.Activity.cs") -Raw
    if ($activityCode -match 'HistoryDetailsEnabled|CompletedObservationsEnabled' -or
        $code -match 'DeviceActivityCard.Visibility') {
        throw "Activity must remain independent of completed observations."
    }
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1"), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "; ") }
    $imported = $page.SelectSingleNode("//*[@x:Name='DeviceImportedMetadata']", $namespaces)
    Assert-Equal $imported.IsExpanded "False" "Imported metadata starts collapsed"
    Assert-Equal $imported.PreviousSibling.Header "How this device was identified" "Imported data immediately follows identification evidence"
    if ($imported.ParentNode.ParentNode.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") -ne "IdentificationCard") {
        throw "Imported metadata must belong to Device identification."
    }
}

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

& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1") -Raw
    $position = [regex]::Match($historyUi, '(?s)function Show-HistorySection.*?(?=function Assert-HistoryRows)').Value
    # Substitute only the desktop pattern token; execute the production positioning body.
    . ([scriptblock]::Create($position.Replace('[System.Windows.Automation.ScrollPattern]::Pattern', '0')))
    $script:positions = [System.Collections.Generic.List[int]]::new()
    $script:secondBottom = 320
    $script:controls = @{}
    $script:scroll = [pscustomobject]@{ Current = [pscustomobject]@{
        VerticallyScrollable = $true; VerticalScrollPercent = 0.0; VerticalViewSize = 50.0
    } }
    $script:scroll | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Percent)
        $script:positions.Add($Percent)
        $this.Current.VerticalScrollPercent = $Percent
        $offset = $Percent * 3
        $script:controls.First.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = 100 - $offset; Bottom = 120 - $offset; Width = 100; Height = 20; IsEmpty = $false
        }
        $script:controls.Since.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = $script:secondBottom - 30 - $offset
            Bottom = $script:secondBottom - $offset; Width = 100; Height = 30; IsEmpty = $false
        }
    }
    $viewport = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 300; Top = 0; Bottom = 300; Width = 300; Height = 300; IsEmpty = $false
        }
    } }
    $script:root = $viewport
    $viewport | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $script:scroll }
    foreach ($id in @("First", "Since")) {
        $script:controls[$id] = [pscustomobject]@{ Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = $null
        } }
    }
    function Find-HistoryControl($Id) {
        if ($Id -eq "DeviceDetailsScroll") { return $viewport }
        return $script:controls[$Id]
    }
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    $null = Show-HistorySection First -AdditionalIds Since
    Assert-Equal $script:positions @(10) "Positioning must directly reveal Since even when the first field already fits"
    $script:secondBottom = 900
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    Assert-Throws { Show-HistorySection First -AdditionalIds Since } "*cannot fit together inside its viewport*"
    Assert-Equal $script:positions.Count 0 "An oversized grouped summary fails without an exhaustive viewport sweep"

    $script:focusCalls = [Collections.Generic.List[string]]::new()
    $script:controls.Focusable = [pscustomobject]@{ Current = [pscustomobject]@{
        IsKeyboardFocusable = $true; IsOffscreen = $true; BoundingRectangle = $null
    } }
    $script:controls.Focusable | Add-Member ScriptMethod SetFocus {
        $script:focusCalls.Add("focus")
    }
    $script:bring = [pscustomobject]@{}
    $script:bring | Add-Member ScriptMethod ScrollIntoView {
        $script:focusCalls.Add("bring")
        $script:controls.Focusable.Current.IsOffscreen = $false
        $script:controls.Focusable.Current.BoundingRectangle = [pscustomobject]@{
            Left = 0; Right = 100; Top = 100; Bottom = 120; Width = 100; Height = 20; IsEmpty = $false
        }
    }
    $script:controls.Focusable | Add-Member ScriptMethod TryGetCurrentPattern {
        param($Pattern, $Result)
        $Result.Value = $script:bring
        return $true
    }
    $script:positions.Clear()
    $null = Show-HistorySection Focusable
    $null = Show-HistorySection Focusable
    Assert-Equal $script:focusCalls @("focus", "bring", "focus", "bring") "Focus precedes bring-into-view even for a previously focused section"
    Assert-Equal $script:positions.Count 0 "Supported section positioning must not fight focus with percentage scrolling"

    $script:secondBottom = 320
    $script:scroll.SetScrollPercent(-1, 0)
    $script:positions.Clear()
    $script:controls.Since.Current | Add-Member NoteProperty IsKeyboardFocusable $true
    $script:controls.Since | Add-Member ScriptMethod SetFocus { $script:focusCalls.Add("nested focus") }
    $script:controls.Since | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Result) return $false }
    $nested = Show-HistorySection Since
    Assert-Equal $script:focusCalls[-1] "nested focus" "Nested scroll viewers must still receive focus first"
    Assert-Equal $script:positions.Count 1 "Focus that leaves a nested scroll viewer clipped must position the outer viewport once"
    Assert-Equal $nested.Current.BoundingRectangle.Top 35 "A clipped nested viewer must be revealed from its top edge"
    Assert-Equal (Test-UiRegressionElementWithin $nested $viewport $script:root) $true "The complete nested viewer must be visible"
}

& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1") -Raw
    . ([scriptblock]::Create([regex]::Match($historyUi, '(?s)function Assert-HistoryPage.*?(?=function Show-HistorySection)').Value))
    $script:pageIndex = 0
    $script:fakeItems = @()
    $script:reached = [Collections.Generic.List[string]]::new()
    $script:fakeList = [pscustomobject]@{}
    $script:fakeList | Add-Member ScriptMethod FindAll { param($Scope, $Condition) return $script:fakeItems }
    function Show-HistorySection($Id) { return $script:fakeList }
    function Find-HistoryControl($Id) {
        $name = switch ($Id) {
            DeviceHistoryPageStatus { "Showing $(100 * $script:pageIndex + 1)-$([Math]::Min(100 * ($script:pageIndex + 1), 205)) of 205." }
            DeviceScanHistoryCount { "205 completed scan observations" }
        }
        [pscustomobject]@{ Current = [pscustomobject]@{ Name = $name } }
    }
    function Test-UiRegressionElementWithin($Element, $Viewport, $Window) { $Element.Visible }
    foreach ($script:pageIndex in 0..2) {
        $count = [Math]::Min(100, 205 - 100 * $script:pageIndex)
        $script:fakeItems = @(0..($count - 1) | ForEach-Object {
            $second = 204 - 100 * $script:pageIndex - $_
            $time = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($second)).ToLocalTime()
            $state = if ($second % 4 -lt 2) { "present" } else { "absent" }
            $item = [pscustomobject]@{
                Current = [pscustomobject]@{
                    Name = "$($time.ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $state"
                    BoundingRectangle = [pscustomobject]@{ Height = 36 }
                }
                Visible = $false
            }
            $item | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $this }
            $item | Add-Member ScriptMethod ScrollIntoView {
                $this.Visible = $true
                $script:reached.Add($this.Current.Name)
            }
            $item
        })
        Assert-Equal @(Assert-HistoryPage $script:pageIndex -Traverse).Count $count "Validate every exact bounded row"
        $script:fakeItems[0].Current.Name = "wrong timestamp; Observed absent"
        Assert-Throws { Assert-HistoryPage $script:pageIndex } "*Wrong row/order/state*"
    }
    Assert-Equal $script:reached.Count 205 "Every observation needs a physical reachability assertion"
    Assert-Equal @($script:reached | Select-Object -Unique).Count 205 "No cross-page duplicate may satisfy traversal"
    $script:fakeItems[0].Current.Name = $script:reached[200]
    $script:fakeItems[0].Current.BoundingRectangle.Height = 12
    function Wait-UiRegressionState($Condition, $Description) {
        $result = & $Condition
        if (-not $result) { throw "Row is not fully physically visible: $Description" }
        return $result
    }
    Assert-Throws { Assert-HistoryPage 2 -Traverse } "*not fully physically visible*"
    $script:fakeItems = @()
    Assert-Throws { Assert-HistoryPage 2 } "*Expected 5 bounded rows*"
}

& {
    . (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
    $historyUi = Get-Content (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.ps1") -Raw
    $findRow = [regex]::Match($historyUi, '(?s)function Find-HistoryDeviceRow.*?(?=function Get-HistoryLastSeenCell)').Value
    . ([scriptblock]::Create($findRow))
    $waits = [Collections.Generic.List[int]]::new()
    $searchPattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = 'previous' }; Changes = 0 }
    $searchPattern | Add-Member ScriptMethod SetValue { param($Value) $this.Current.Value = $Value; $this.Changes++ }
    $searchControl = [pscustomobject]@{}
    $searchControl | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $searchPattern }
    $nameCell = [pscustomobject]@{ Current = [pscustomobject]@{ Name = 'History normal' } }
    $row = [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $false; BoundingRectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
    } }
    $row | Add-Member ScriptMethod FindFirst { param($Scope, $Condition) return $nameCell }
    $list = [pscustomobject]@{ Current = $row.Current }
    $list | Add-Member ScriptMethod FindAll { param($Scope, $Condition) return @($row) }
    function Select-HistoryDevices {}
    function Start-Sleep { param($Milliseconds) $waits.Add($Milliseconds) }
    function Find-HistoryControl($Value, [switch] $ByName, [switch] $Optional) {
        if ($Value -eq 'Search devices') { return $searchControl }
        if ($Value -eq 'ResultsList') { return $list }
        throw "Unexpected history lookup '$Value'."
    }
    function Wait-UiRegressionState([scriptblock] $Condition, [string] $Description) {
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            $result = & $Condition
            if ($result) { return $result }
        }
        throw "Timed out waiting for $Description."
    }
    $null = Find-HistoryDeviceRow 'History normal'
    $null = Find-HistoryDeviceRow 'History normal'
    Assert-Equal $searchPattern.Changes 1 'Repeated assertions must not reapply the same search'
    Assert-Equal $waits @(300) 'A changed filter retains its original debounce settling; unchanged filters need none'
    $nameCell.Current.Name = 'History virtual'
    Assert-Throws { Find-HistoryDeviceRow 'History normal' } "*Timed out*exactly one visible history device matching 'History normal'*"
    $nameCell.Current.Name = 'History normal'
    $row.Current.IsOffscreen = $true
    Assert-Throws { Find-HistoryDeviceRow 'History normal' } "*Timed out*exactly one visible history device matching 'History normal'*"
}

& {
    . (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
    $choices = [System.Collections.Generic.List[string]]::new()
    function Set-UiReviewAppearanceChoice {
        param($Root, [string] $Picker, [string] $Choice)
        $choices.Add("$Picker=$Choice")
    }
    $expectedChoices = @(
        @("ModePicker=Light", "ThemePicker=Standard"),
        @("ModePicker=Light", "ThemePicker=Warm"),
        @("ModePicker=Light", "ThemePicker=Colorful"),
        @("ModePicker=Dark", "ThemePicker=Standard"),
        @("ModePicker=Dark", "ThemePicker=True Black (OLED)"),
        @("ModePicker=Dark", "ThemePicker=Colorful")
    )
    Assert-Equal $UiReviewAppearanceThemes.Count 6 "Every appearance variant has UI coverage"
    for ($index = 0; $index -lt $UiReviewAppearanceThemes.Count; $index++) {
        $choices.Clear()
        Set-UiReviewTheme -Root ([pscustomobject]@{}) -Theme $UiReviewAppearanceThemes[$index]
        Assert-Equal $choices $expectedChoices[$index] "Select mode before its theme"
    }
    Assert-Throws { Set-UiReviewTheme -Root ([pscustomobject]@{}) -Theme "Unknown" } "*Cannot validate argument*"
}

$repository = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-scenarios-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $repository
try {
    $null = Invoke-UiReviewGit $repository @("init", "--quiet")
    $null = Invoke-UiReviewGit $repository @("config", "user.name", "Scenario tests")
    $null = Invoke-UiReviewGit $repository @("config", "user.email", "scenario-tests@example.invalid")
    $null = Invoke-UiReviewGit $repository @("config", "commit.gpgsign", "false")
    $xamlPath = Join-Path $repository "src\FingVibe.App\MainWindow.xaml"
    $null = New-Item -ItemType Directory -Path (Split-Path $xamlPath) -Force
    $xaml = '<Window xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Grid x:Name="RootGrid">'
    foreach ($page in ($UiReviewScenarios.Values.Page | Select-Object -Unique)) {
        $xaml += "<Grid x:Name=`"$page`"><TextBlock Text=`"$page`" /></Grid>"
    }
    $xaml += '</Grid></Window>'
    Set-Content -LiteralPath $xamlPath -Value $xaml
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Baseline")
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")

    function Test-Change([hashtable] $Files, [string[]] $Expected, [string] $Message) {
        $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
        foreach ($path in $Files.Keys) {
            $target = Join-Path $repository $path
            $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
            Set-Content -LiteralPath $target -Value $Files[$path]
        }
        $null = Invoke-UiReviewGit $repository @("add", ".")
        $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", $Message)
        $plan = @(Get-UiReviewCapturePlan -RepositoryPath $repository -BaseRevision $base)
        Assert-Equal $plan.Scenario $Expected $Message
        foreach ($capture in $plan) {
            if ($capture.Reasons.Count -eq 0) { throw "Every capture must explain why it was selected." }
        }
    }

    Assert-Equal @(Get-UiReviewCapturePlan $repository).Scenario @("Devices") "Manual default"
    Assert-Equal @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network", "Network")).Scenario `
        @("Devices", "Network") "Explicit scenarios must be deduplicated"
    Assert-Throws { Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Typo") } "*Unknown UI capture scenario*"
    Assert-Throws { Get-UiReviewCapturePlan $repository -BaseRevision "missing-ref" } "*failed with exit code*"

    Test-Change @{ "README.md" = "Documentation" } @("Devices") "Documentation-only"
    foreach ($scenario in @("Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails", "Tools", "SpeedTest", "Settings", "Devices")) {
        $page = $UiReviewScenarios[$scenario].Page
        $changed = $xaml.Replace("Text=`"$page`"", "Text=`"Changed $page`"")
        $expected = @("Devices")
        foreach ($pageScenario in $UiReviewScenarios.Keys) {
            if ($UiReviewScenarios[$pageScenario].Page -eq $page -and $pageScenario -ne "Devices") {
                $expected += $pageScenario
            }
        }
        Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $changed } $expected "Page-local $scenario"
    }
    $changed = $xaml.Replace('Text="OverviewPage"', 'Text="New overview"').Replace('Text="NetworkPage"', 'Text="New network"')
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $changed } @("Devices", "Overview", "Network") "Multiple pages"
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $xaml.Replace('</Window>', '<Grid x:Name="NewPage" /></Window>') } `
            @() "Unsupported new page"
    } "*NewPage*has no capture scenario*"
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $xaml.Replace('<Window ', '<Window Title="Shared" ') } `
        @($UiReviewScenarios.Keys) "Shared layout"
    $navigation = '<NavigationView><NavigationView.MenuItems><NavigationViewItem Content="Tools" /></NavigationView.MenuItems></NavigationView>'
    $navigationXaml = $xaml.Replace('<Grid x:Name="RootGrid">', "<Grid x:Name=`"RootGrid`">$navigation")
    # The existing navigation container is part of the shell; only its menu entries are excluded.
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $navigationXaml } `
        @($UiReviewScenarios.Keys) "New shared navigation container"
    $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
    $navigationBase = $xaml.Replace('<Grid x:Name="RootGrid">', '<Grid x:Name="RootGrid"><NavigationView />')
    Set-Content -LiteralPath $xamlPath -Value $navigationBase
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Existing navigation")
    $originalBase = $base
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $navigationXaml } @("Devices") "Menu-only change"
    $base = $originalBase
    Test-Change @{ "src\FingVibe.App\MainWindow.DeviceDetails.cs" = "changed" } `
        @("Devices", "DeviceDetails", "DeviceHistory") "Device details code"
    foreach ($path in @("src\FingVibe.App\PageHeaderSizing.cs", "tests\PageHeaders.Ui.Helpers.ps1")) {
        Test-Change @{ $path = "changed" } `
            @("Devices", "DeviceDetails", "DeviceHistory", "SpeedTest", "Troubleshooting", "About",
                "FingImport", "SqlEditor", "DatabaseBackups", "Settings") "Back header owners"
    }
    foreach ($path in @("src\FingVibe.App\DeviceDetailsPresentation.cs", "src\FingVibe.App\Views\DeviceDetailValue.cs",
        "src\FingVibe.App\Views\DeviceScanHistoryItem.cs")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "DeviceHistory") "Device details presentation"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.UsageCategories.cs", "src\FingVibe.App\UsageCategoryPresentation.cs",
        "src\FingVibe.App\Views\DeviceDetailsPageView.Usage.cs", "src\FingVibe.Core\Models\DeviceUsageCategory.cs",
        "tests\UsageCategory.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "Settings") "Usage categories"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.DeviceActivity.cs",
        "src\FingVibe.App\Views\DeviceDetailsPageView.Activity.cs",
        "tests\DeviceActivity.Ui.Tests.ps1", "tests\DeviceActivity.Fixture.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceHistory") "Device activity"
    }
    foreach ($path in @("src\FingVibe.App\DeviceActivityPresentation.cs", "src\FingVibe.App\DeviceActivityReviewHold.cs",
        "src\FingVibe.App\Views\ActivityGridRenderer.cs", "src\FingVibe.Core\Models\DeviceActivity.cs",
        "tests\ActivityGrid.Ui.Helpers.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network", "DeviceHistory", "PersonDetails") "Shared activity grid"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.NetworkActivity.cs",
        "src\FingVibe.App\Views\NetworkPageView.Activity.cs", "tests\NetworkActivity.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network") "Network activity"
    }
    foreach ($path in @("src\FingVibe.App\NetworkActivityPresentation.cs", "src\FingVibe.Core\Models\NetworkActivity.cs",
        "tests\NetworkActivity.Fixture.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "Network", "PersonDetails") "Shared count grids"
    }
    foreach ($path in @("src\FingVibe.App\MainWindow.EquipmentActivity.cs", "src\FingVibe.App\EquipmentActivityPresentation.cs",
        "src\FingVibe.App\Views\PersonDetailsPageView.Activity.cs", "src\FingVibe.Core\Models\EquipmentActivity.cs",
        "tests\EquipmentActivity.Ui.Tests.ps1")) {
        Test-Change @{ $path = "changed" } @("Devices", "PersonDetails") "Equipment activity"
    }
    foreach ($path in @("src\FingVibe.Core\Models\DeviceInventory.cs", "src\FingVibe.Core\Models\PrivateVirtualDevice.cs",
        "src\FingVibe.Core\Models\DeviceHistorySummary.cs",
        "src\FingVibe.Core\Models\DeviceDiscovery.cs", "src\FingVibe.App\MainWindow.DiscoveryNotifications.cs",
        "src\FingVibe.App\DiscoveryPopup.xaml", "src\FingVibe.App\DiscoveryPopup.xaml.cs",
        "src\FingVibe.App\DiscoveryNotificationPresentation.cs", "src\FingVibe.App\DiscoveryNotificationStore.cs",
        "src\FingVibe.App\WindowsDiscoveryNotifications.cs", "src\FingVibe.App\Assets\DiscoveryCaution.png",
        "src\FingVibe.App\MainWindow.Scan.cs", "tests\DeviceDiscovery.Ui.Tests.ps1",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.cs", "src\FingVibe.App\MainWindow.Snapshots.cs",
        "tests\DeviceScanHistory.Ui.Tests.ps1", "tests\Inventory.Sqlite.Helpers.ps1",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.Json.cs", "src\FingVibe.Core\Models\AppendedScanHistory.cs",
        "src\FingVibe.Core\Storage\DeviceInventoryStore.History.cs", "src\FingVibe.Core\Storage\SqliteScanHistory.cs",
        "src\FingVibe.Core\Models\DeviceHistoryQuery.cs")) {
        Test-Change @{ $path = "changed" } @("Devices", "DeviceDetails", "DeviceHistory") "Device scan history"
    }
    foreach ($iconPath in @("src\FingVibe.App\PeopleRoomsIcons.cs", "src\FingVibe.App\Views\PeopleRoomsIconPicker.cs",
        "src\FingVibe.App\PeopleRoomsPresentation.cs", "src\FingVibe.App\Views\PeopleRoomsDialogs.cs")) {
        Test-Change @{ $iconPath = "changed" } `
            @("Devices", "DeviceDetails", "People", "PersonDetails", "Rooms", "RoomDetails") "People/Rooms icon surfaces"
    }
    Test-Change @{ "src\FingVibe.App\MainWindow.NetworkIdentity.cs" = "changed" } `
        @("Devices", "Overview", "Network", "DeviceDetails", "PersonDetails", "Troubleshooting") "Network identity code"
    Test-Change @{ "src\FingVibe.App\MainWindow.Results.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Results and empty state"
    Test-Change @{ "src\FingVibe.App\DeviceResultFilter.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Multi-select matching and empty state"
    Test-Change @{ "src\FingVibe.App\DeviceResultSort.cs" = "changed" } `
        @("Devices", "Settings", "DevicesEmpty") "Devices sort keys and direction"
    Test-Change @{ "src\FingVibe.App\App.xaml" = "changed" } @($UiReviewScenarios.Keys) "Shared theme"
    $applicationXaml = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\MainWindow.xaml") -Raw
    $applicationDocument = [System.Xml.XmlDocument]::new()
    $applicationDocument.LoadXml($applicationXaml)
    foreach ($attribute in $applicationDocument.SelectNodes("//@*")) {
        if ($attribute.Value.StartsWith("{ThemeResource ") -and -not $attribute.Value.EndsWith("}")) {
            throw "Unclosed ThemeResource expression on $($attribute.OwnerElement.Name).$($attribute.Name)."
        }
    }
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml" = $applicationXaml } `
        @($UiReviewScenarios.Keys) "Actual application pages all have capture scenarios"
    Test-Change @{ "src\FingVibe.Core\NewModel.cs" = "changed" } @("Devices") "Core dependency baseline"
    Test-Change @{ ".github\scripts\UiReviewNavigation.ps1" = "changed" } @("Devices") "Pipeline baseline"
    Test-Change @{ "src\FingVibe.App\MainWindow.xaml.cs" = "changed" } @("Devices") "Shell code baseline"
    Test-Change @{ "src\FingVibe.App\Tools\SpeedTestPage.xaml" = "changed" } @("Devices", "Tools", "SpeedTest", "Troubleshooting", "About", "FingImport", "SqlEditor", "DatabaseBackups") "Tools views"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml" = "changed" } @("Devices", "Tools", "Troubleshooting") "Troubleshooting view"
    Test-Change @{ "src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml.cs" = "changed" } @("Devices", "Tools", "Troubleshooting") "Troubleshooting behavior"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml" = "changed" } @("Devices", "About", "Settings") "About view"
    Test-Change @{ "src\FingVibe.App\Tools\AboutPage.xaml.cs" = "changed" } @("Devices", "About", "Settings") "About behavior"
    foreach ($updateOwner in @("src\FingVibe.App\Tools\AboutPage.Updates.cs", "src\FingVibe.App\MainWindow.Updates.cs",
        "src\FingVibe.App\Updates\ReleaseUpdateActions.cs", "src\FingVibe.Core\Updates\ReleaseUpdateSession.cs",
        "tests\ReleaseUpdates.Ui.Tests.ps1")) {
        Test-Change @{ $updateOwner = "changed" } @("Devices", "About", "Settings") "Update owner selects Settings and About: $updateOwner"
    }
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml" = "changed" } @("Devices", "Tools", "FingImport") "Fing import view"
    Test-Change @{ "src\FingVibe.App\Tools\FingImportPage.xaml.cs" = "changed" } @("Devices", "Tools", "FingImport") "Fing import behavior"
    Test-Change @{ "src\FingVibe.App\Tools\SqlEditorPage.xaml" = "changed" } @("Devices", "Tools", "SqlEditor") "SQL editor view"
    Test-Change @{ "src\FingVibe.App\Tools\DatabaseBackupsPage.xaml" = "changed" } @("Devices", "Tools", "DatabaseBackups") "Database backups view"
    Test-Change @{ "src\FingVibe.Core\Storage\InventoryBackupStore.cs" = "changed" } @("Devices", "Tools", "DatabaseBackups") "Backup storage behavior"
    Test-Change @{ "src\FingVibe.Core\Storage\InventoryQueryService.cs" = "changed" } @("Devices", "Tools", "SqlEditor") "SQL query behavior"
    Test-Change @{ "src\FingVibe.App\MainWindow.Inventory.cs" = "changed" } `
        @("Devices", "Overview", "Network", "DeviceDetails", "People", "PersonDetails", "Rooms", "FingImport", "SqlEditor", "RoomDetails") "Inventory surfaces"
    $viewScenarios = @{
        OverviewPageView = @("Devices", "Overview")
        NetworkPageView = @("Devices", "Network")
        DevicesPageView = @("Devices", "Settings", "DevicesEmpty")
        DeviceDetailsPageView = @("Devices", "DeviceDetails", "DeviceHistory")
        PeoplePageView = @("Devices", "DeviceDetails", "People", "PersonDetails")
        RoomsPageView = @("Devices", "DeviceDetails", "Rooms", "RoomDetails")
        PersonDetailsPageView = @("Devices", "DeviceDetails", "People", "PersonDetails")
        RoomDetailsPageView = @("Devices", "DeviceDetails", "Rooms", "RoomDetails")
        SettingsPageView = @($UiReviewScenarios.Keys)
    }
    $pageViews = @{
        OverviewPage = "OverviewPageView"
        NetworkPage = "NetworkPageView"
        DevicesPage = "DevicesPageView"
        DevicePage = "DeviceDetailsPageView"
        PeoplePage = "PeoplePageView"
        RoomsPage = "RoomsPageView"
        PersonDetailPage = "PersonDetailsPageView"
        RoomDetailPage = "RoomDetailsPageView"
        SettingsPage = "SettingsPageView"
    }
    $appDirectory = Join-Path $PSScriptRoot "..\src\FingVibe.App"
    $shellDocument = [xml](Get-Content (Join-Path $appDirectory "MainWindow.xaml") -Raw)
    $rootGrid = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='RootGrid']")
    $ribbonArea = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='BuildRibbonArea']")
    $navigation = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='MainNavigation']")
    if ($ribbonArea.ParentNode -ne $rootGrid -or $navigation.ParentNode -ne $rootGrid -or
        $rootGrid.LastChild -ne $ribbonArea) {
        throw "The build ribbon must overlay navigation as a root sibling, outside the shared header layout."
    }
    $ribbon = $ribbonArea.SelectSingleNode(".//*[@*[local-name()='Name']='BuildRibbon']")
    if ($ribbon.GetAttribute("UseSystemFocusVisuals") -cne "False" -or
        $ribbon.GetAttribute("GotFocus") -cne "BuildRibbon_FocusChanged" -or
        $ribbon.GetAttribute("LostFocus") -cne "BuildRibbon_FocusChanged") {
        throw "The ribbon must use an in-button focus border rather than an unclipped native focus adorner."
    }
    $scanHeader = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanHeader']")
    $scanSource = Get-Content (Join-Path $appDirectory "MainWindow.Scan.cs") -Raw
    if ($scanSource -notmatch 'await SaveCompletedScanAsync\([^;]+\);\s*_scanMessage = null;' -or
        $scanSource -match 'Complete in ' -or
        $scanSource -notmatch 'new\[\] \{ _scanMessage, _snapshotError, _inventoryError, _backupError, _discoveryMessage, _windowsNotificationMessage, targetWarning \}' -or
        $scanSource -notmatch 'ScanMessages\.Visibility = _isScanning \|\| !string\.IsNullOrWhiteSpace\(status\)\s*\? Visibility\.Visible : Visibility\.Collapsed;') {
        throw "Scan success must clear only its own message, retain independent errors/warnings, and collapse unused messages."
    }
    $messages = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='ScanMessages']")
    $messageRows = $messages.ParentNode.SelectNodes("./*[local-name()='Grid.RowDefinitions']/*")
    if ($messages.GetAttribute("Visibility") -cne "Collapsed" -or
        @($messageRows | Where-Object { $_.GetAttribute("Height") -cne "Auto" }).Count -ne 0) {
        throw "The shared header must not reserve an empty row for collapsed scan messages."
    }
    foreach ($id in @("DetectedNetworkLabel", "NetworkPicker", "ScanFreshnessText")) {
        $element = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='$id']")
        if (-not $element -or $element.GetAttribute("VerticalAlignment") -cne "Center") {
            throw "Shared network element '$id' must be centered in the shell header."
        }
    }
    $progress = $shellDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanProgressBar']")
    if ($progress.GetAttribute("Height") -cne "10" -or $progress.GetAttribute("MinHeight") -cne "8" -or
        $progress.GetAttribute("IsIndeterminate") -eq "True") {
        throw "Scan progress needs an 8-DIP native indicator and 10-DIP outer height to retain the high-contrast border."
    }
    $scan = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='ScanButton']")
    $cancel = $scanHeader.SelectSingleNode(".//*[@*[local-name()='Name']='CancelButton']")
    if (-not $scan -or -not $cancel -or $scan.ParentNode -ne $cancel.ParentNode -or
        $scan.ParentNode.LocalName -cne "Grid" -or $cancel.GetAttribute("AutomationProperties.Name") -cne "Cancel scan") {
        throw "Scan LAN and Cancel scan must occupy the same shared-header slot with their existing automation IDs."
    }
    $scanIcon = $scan.SelectSingleNode(".//*[local-name()='FontIcon']")
    $scanLabel = $scan.SelectSingleNode(".//*[local-name()='TextBlock']")
    if ($scan.GetAttribute("AutomationProperties.Name") -cne "Scan LAN" -or
        $scanIcon.GetAttribute("Glyph") -cne [string][char]0xE895 -or
        $scanIcon.GetAttribute("AutomationProperties.AccessibilityView") -cne "Raw" -or
        $scanIcon.GetAttribute("IsHitTestVisible") -cne "False" -or
        $scanIcon.HasAttribute("Foreground") -or $scanIcon.GetAttribute("IsTextScaleFactorEnabled") -eq "False" -or
        $scanIcon.NextSibling -ne $scanLabel -or $scanLabel.GetAttribute("Grid.Column") -cne "1" -or
        $scanLabel.GetAttribute("Text") -cne "Scan LAN" -or $scanLabel.GetAttribute("TextWrapping") -cne "Wrap") {
        throw "Scan LAN must retain its accessible label with a preceding decorative, theme-inherited, scalable refresh icon and wrapping text."
    }
    $devicesDocument = [xml](Get-Content (Join-Path $appDirectory "Views\DevicesPageView.xaml") -Raw)
    if ($devicesDocument.SelectSingleNode("//*[@*[local-name()='Name']='ScanButton']")) {
        throw "Devices must not duplicate the shared primary scan action."
    }
    $statusStyle = $devicesDocument.SelectSingleNode("//*[@*[local-name()='Key']='StatusFilterStyle']")
    if ($statusStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='BorderThickness']").GetAttribute("Value") -cne "1" -or
        $statusStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='BorderBrush']").GetAttribute("Value") -cne "{ThemeResource ControlStrongStrokeColorDefaultBrush}") {
        throw "Status needs a subtle neutral stroke, distinct from an applied value and native accent focus."
    }
    $toolsDocument = [System.Xml.XmlDocument]::new()
    $toolsDocument.Load((Join-Path $appDirectory "Tools\ToolsPage.xaml"))
    $toolIcons = @(
        @{ Page = "SpeedTestPage"; Title = "Speed test"; Card = "SpeedTestCard"; Click = "SpeedTestCard_Click"; Glyph = 0xEC4A },
        @{ Page = "NetworkTroubleshootingPage"; Title = "Network troubleshooting"; Card = "TroubleshootingCard"; Click = "TroubleshootingCard_Click"; Glyph = 0xE90F },
        @{ Page = "AboutPage"; Title = "About FingVibe"; Card = "AboutCard"; Click = "AboutCard_Click"; Glyph = 0xE946 },
        @{ Page = "FingImportPage"; Title = "Import from Fing"; Card = "FingImportCard"; Click = "FingImportCard_Click"; Glyph = 0xE8B5 },
        @{ Page = "SqlEditorPage"; Title = "SQL editor"; Card = "SqlEditorCard"; Click = "SqlEditorCard_Click"; Glyph = 0xE943 },
        @{ Page = "DatabaseBackupsPage"; Title = "Database backups"; Card = "DatabaseBackupsCard"; Click = "DatabaseBackupsCard_Click"; Glyph = 0xE74E }
    )
    foreach ($tool in $toolIcons) {
        $pageDocument = [System.Xml.XmlDocument]::new()
        $pageDocument.Load((Join-Path $appDirectory "Tools\$($tool.Page).xaml"))
        if ($tool.Page -eq "NetworkTroubleshootingPage") {
            $run = $pageDocument.SelectSingleNode("//*[@*[local-name()='Name']='RunButton']")
            if ($run.GetAttribute("Style") -cne "{ThemeResource AccentButtonStyle}") {
                throw "Run checks must use the existing primary-action accent style."
            }
        }
        $card = $toolsDocument.SelectSingleNode("//*[@*[local-name()='Name']='$($tool.Card)']")
        if ($tool.Page -ne "AboutPage" -and ($card.LocalName -cne "Button" -or $card.GetAttribute("Click") -cne $tool.Click -or
            $card.GetAttribute("AutomationProperties.Name") -cne $tool.Title -or
            $card.SelectNodes(".//*[local-name()='Button' or local-name()='HyperlinkButton']").Count -ne 0)) {
            throw "$($tool.Title) must remain one landing button with its existing handler and accessible name."
        }
        $pageTitle = $pageDocument.SelectSingleNode("//*[local-name()='TextBlock' and @Text='$($tool.Title)' and @Style='{StaticResource ScannerPageTitleStyle}']")
        $titles = @($pageTitle)
        if ($tool.Page -ne "AboutPage") {
            $titles += $card.SelectSingleNode(".//*[local-name()='TextBlock' and @Text='$($tool.Title)']")
        } elseif ($card) { throw "About must no longer appear in Tools." }
        foreach ($title in $titles) {
            $isPageTitle = $title -eq $pageTitle
            $titleColumn = if ($isPageTitle) { "2" } else { "1" }
            if (-not $title -or $title.GetAttribute("TextWrapping") -cne "Wrap" -or
                $title.GetAttribute("Grid.Column") -cne $titleColumn -or $title.GetAttribute("VerticalAlignment") -cne "Center") {
                throw "$($tool.Title) must wrap and center beside its icon."
            }
            $header = $title.ParentNode
            $columns = $header.SelectNodes("./*[local-name()='Grid.ColumnDefinitions']/*[local-name()='ColumnDefinition']")
            $expectedColumns = if ($isPageTitle) { 3 } else { 2 }
            if ($header.LocalName -cne "Grid" -or $header.GetAttribute("ColumnSpacing") -cne "12" -or
                $columns.Count -ne $expectedColumns -or $columns[0].GetAttribute("Width") -cne "Auto" -or
                $columns[$expectedColumns - 1].GetAttribute("Width") -cne "*") {
                throw "$($tool.Title) must reserve icon space and constrain the title for wrapping."
            }
            if ($isPageTitle) {
                $destination = if ($tool.Page -eq "AboutPage") { "Settings" } else { "Tools" }
                $back = $header.SelectSingleNode("./*[local-name()='Button' and @AutomationProperties.Name='Back to $destination']")
                if (-not $back -or $columns[1].GetAttribute("Width") -cne "Auto" -or
                    $back.GetAttribute("Grid.Column") -notin @("", "0") -or
                    $header.SelectSingleNode("./*[local-name()='Button' or local-name()='FontIcon' or local-name()='TextBlock']") -ne $back -or
                    $back.GetAttribute("Content") -cne "$([char]0x2190) $destination" -or
                    $pageDocument.SelectNodes("//*[local-name()='Button' and @AutomationProperties.Name='Back to $destination']").Count -ne 1 -or
                    $back.GetAttribute("Style") -cne "{StaticResource PageBackButtonStyle}" -or
                    $back.HasAttribute("Width") -or $back.HasAttribute("Height")) {
                    throw "$($tool.Title) must have one content-safe neutral Back action first in its title row."
                }
            }
            $icons = $header.SelectNodes("./*[local-name()='FontIcon']")
            if ($icons.Count -ne 1) { throw "$($tool.Title) must have exactly one decorative header icon." }
            $icon = $icons[0]
            if ($isPageTitle -and $icon.GetAttribute("Grid.Column") -cne "1") {
                throw "$($tool.Title) must keep its decorative icon with the heading after Back."
            }
            foreach ($attribute in @{
                Glyph = [string][char]$tool.Glyph
                FontFamily = "Segoe Fluent Icons"
                FontSize = "48"
                Width = "48"
                Height = "48"
                Foreground = "{ThemeResource TextFillColorPrimaryBrush}"
                IsHitTestVisible = "False"
                "AutomationProperties.AccessibilityView" = "Raw"
            }.GetEnumerator()) {
                if ($icon.GetAttribute($attribute.Key) -cne $attribute.Value) {
                    throw "$($tool.Title) icon must use $($attribute.Key)=$($attribute.Value) on both surfaces."
                }
            }
        }
        if ($tool.Page -eq "AboutPage" -and
            ($pageTitle.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml") -cne "PageHeading" -or
             $pageTitle.GetAttribute("IsTabStop") -cne "True")) {
            throw "About must preserve its named, keyboard-focusable heading."
        }
    }
    $shellCode = (Get-ChildItem (Join-Path $appDirectory "MainWindow*.cs") |
        ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    foreach ($page in $pageViews.Keys) {
        $view = $pageViews[$page]
        $node = $applicationDocument.SelectSingleNode("//*[@*[local-name()='Name']='$page']")
        if ($node.LocalName -cne $view -or $node.ChildNodes.Count -ne 0) {
            throw "$page must be composed as $view without inline page content."
        }
        $viewDocument = [System.Xml.XmlDocument]::new()
        $viewDocument.Load((Join-Path $appDirectory "Views\$view.xaml"))
        if ($viewDocument.DocumentElement.LocalName -cne "UserControl" -or
            $viewDocument.DocumentElement.GetAttribute("Class", "http://schemas.microsoft.com/winfx/2006/xaml") -cne "FingVibe.App.Views.$view") {
            throw "$view must have its own UserControl namescope and class."
        }
        $viewCode = (Get-ChildItem (Join-Path $appDirectory "Views\$view.*.cs") |
            ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        if ($viewCode -match '(?m)^\s*(public|internal)\s+(TextBlock|TextBox|ComboBox|Button|ListView|ScrollViewer|Grid|Image|FontIcon|Expander)\??\s+\w+\s*(\{|=>)') {
            throw "$view must not expose its child controls."
        }
        foreach ($child in $viewDocument.SelectNodes("//*[@*[local-name()='Name']]")) {
            if ($child.LocalName -in @("VisualState", "VisualStateGroup")) { continue }
            $childName = $child.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
            if ($childName -ne $page -and $shellCode -match "\b$([regex]::Escape($childName))\b") {
                throw "Shell code must use $view APIs, not the child control $childName."
            }
        }
        foreach ($attribute in $viewDocument.SelectNodes("//@*")) {
            if ($attribute.Value.StartsWith("{ThemeResource ") -and -not $attribute.Value.EndsWith("}")) {
                throw "Unclosed ThemeResource in $view."
            }
            if ($attribute.LocalName -in @("Click", "ItemClick", "TextChanged", "SelectionChanged", "SizeChanged") -and
                $viewCode -notmatch "\b$([regex]::Escape($attribute.Value))\s*\(") {
                throw "$view must own handler $($attribute.Value)."
            }
        }
    }
    foreach ($view in @("DevicesPageView", "SettingsPageView")) {
        $viewCode = Get-Content (Join-Path $appDirectory "Views\$view.xaml.cs") -Raw
        if ($viewCode -notmatch 'DeviceColumnLayout Columns => DeviceColumnLayout.Current') {
            throw "$view must bind the shared table column layout."
        }
        $details = [xml](Get-Content (Join-Path $appDirectory "Views\DeviceDetailsPageView.xaml") -Raw)
        $overview = $details.SelectSingleNode("//*[@*[local-name()='Name']='NetworkOverviewCard']")
        $assignments = $details.SelectSingleNode("//*[@*[local-name()='Name']='AssignmentsCard']")
        $identification = $details.SelectSingleNode("//*[@*[local-name()='Name']='IdentificationCard']")
        $ports = $details.SelectSingleNode("//*[@*[local-name()='Name']='PortsServicesCard']")
        if ($overview.ParentNode -ne $assignments.ParentNode -or
            $assignments.GetAttribute("Grid.Column") -ne "1" -or
            $identification.ParentNode -ne $overview.ParentNode.ParentNode -or
            $identification.NextSibling -ne $ports) {
            throw "Details must put network/assignments in the top row, then full-width identification and ports."
        }
        $assignmentLayout = $assignments.FirstChild
        $assignmentNote = $details.SelectSingleNode("//*[@*[local-name()='Name']='DeviceAssignmentStatusText']")
        if ($overview.GetAttribute("VerticalAlignment") -ne "Stretch" -or
            $assignments.GetAttribute("VerticalAlignment") -ne "Stretch" -or
            $assignmentLayout.LocalName -ne "Grid" -or
            $assignmentLayout.FirstChild.LastChild.GetAttribute("Height") -ne "*" -or
            [int]$assignmentNote.GetAttribute("Grid.Row") -ne $assignmentLayout.FirstChild.ChildNodes.Count - 1 -or
            $assignmentNote.GetAttribute("VerticalAlignment") -ne "Bottom") {
            throw "Top-row cards must share their height, with the assignments note anchored at the bottom."
        }
        $networkNote = $details.SelectSingleNode("//*[@*[local-name()='Name']='DeviceAddressSourceText']")
        if ($networkNote.ParentNode.GetAttribute("VerticalAlignment") -ne "Bottom" -or
            $networkNote.ParentNode.GetAttribute("Grid.Row") -ne "2" -or
            $overview.FirstChild.FirstChild.LastChild.GetAttribute("Height") -ne "*") {
            throw "The network footnote must stay aligned with the Assignments footer when usage evidence grows."
        }
        $valueCode = Get-Content (Join-Path $appDirectory "Views\DeviceDetailValue.cs") -Raw
        if ($valueCode -notmatch 'HyperlinkButton _browser' -or
            $valueCode -notmatch '_valueRow.Children.Add\(_copy\)' -or
            $valueCode -notmatch '_copy.Opacity = _rename.Opacity = visible' -or
            $valueCode -notmatch '_rename.FocusState != FocusState.Unfocused') {
            throw "Details must keep native browser links and reserved hover/focus copy actions beside values."
        }
    }
    foreach ($view in $viewScenarios.Keys) {
        foreach ($extension in @("xaml", "xaml.cs")) {
            Test-Change @{ "src\FingVibe.App\Views\$view.$extension" = "changed" } `
                $viewScenarios[$view] "Extracted $view $extension"
        }
    }
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\Views\UnknownPageView.xaml" = "changed" } @() "Unsupported page view"
    } "*has no selection rule*"
    Assert-Throws {
        Test-Change @{ "src\FingVibe.App\Tools\UnknownPage.xaml" = "changed" } @() "Unsupported extracted page"
    } "*has no selection rule*"
    $base = Invoke-UiReviewGit $repository @("rev-parse", "$originalBase")
    $oldXaml = $navigationBase.Replace('<Grid x:Name="ToolsPage"><TextBlock Text="ToolsPage" /></Grid>', '')
    $null = Invoke-UiReviewGit $repository @("checkout", "--quiet", "--detach", $base)
    Set-Content -LiteralPath $xamlPath -Value $oldXaml
    $null = Invoke-UiReviewGit $repository @("add", ".")
    $null = Invoke-UiReviewGit $repository @("commit", "--quiet", "-m", "Before Tools")
    $base = Invoke-UiReviewGit $repository @("rev-parse", "HEAD")
    Test-Change @{
        "src\FingVibe.App\MainWindow.xaml" = $navigationXaml.Replace('<Grid x:Name="ToolsPage">', '<!-- Tools --><Grid x:Name="ToolsPage">')
        "src\FingVibe.App\MainWindow.xaml.cs" = "Tools routing"
        "src\FingVibe.App\MainWindow.Scan.cs" = "Activity coordination"
        "src\FingVibe.App\FingVibe.App.csproj" = "WebView2 dependency"
        "src\FingVibe.App\Tools\ToolsPage.xaml" = "Tools"
        "src\FingVibe.App\Tools\SpeedTestPage.xaml" = "Speed test"
        "src\FingVibe.App\Assets\SpeedTest\speedtest.js" = "engine"
        ".github\scripts\UiReviewScenarios.ps1" = "New scenarios"
        ".github\scripts\UiReviewNavigation.ps1" = "New navigation"
        "tests\UiReviewScenarios.Tests.ps1" = "New tests"
        "README.md" = "Tools documentation"
    } @("Devices", "DeviceDetails", "DeviceHistory", "Tools", "SpeedTest", "Troubleshooting", "About", "FingImport", "SqlEditor", "DatabaseBackups") "Tools structural changes include all tools and scan discovery"
    $base = $originalBase

    $planPath = Join-Path $repository "plan.json"
    $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network"))
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Equal @(Read-UiReviewCapturePlan $planPath).Scenario @("Devices", "Network") "Manifest roundtrip"
    $plan[1].FileName = "..\unexpected.png"
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*Invalid capture definition*"
    '[]' | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*must include the Devices baseline*"
    $plan = @(Get-UiReviewCapturePlan $repository)
    ConvertTo-Json -InputObject @($plan[0], $plan[0]) -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*duplicate capture scenario*"

    $savedToken = $env:GH_TOKEN
    $savedOutput = $env:GITHUB_OUTPUT
    $savedTemp = $env:RUNNER_TEMP
    try {
        $env:GH_TOKEN = "test-placeholder"
        $env:GITHUB_OUTPUT = Join-Path $repository "output.txt"
        $env:RUNNER_TEMP = $repository
        function gh { $global:LASTEXITCODE = 0 }
        function git {
            $global:LASTEXITCODE = if ($args[0] -eq "ls-remote") { 2 } else { 0 }
            if ($args -contains "diff") { $global:LASTEXITCODE = 1 }
        }
        $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network", "DevicesEmpty"))
        ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
        foreach ($capture in $plan) {
            Set-Content -LiteralPath (Join-Path $repository $capture.FileName) -Value "capture fixture"
        }
        $publishScript = Join-Path $PSScriptRoot "..\.github\scripts\Publish-UiReviewScreenshot.ps1"
        & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 456
        $comment = Get-Content (Join-Path $repository "pr-comment.md") -Raw
        foreach ($capture in $plan) {
            $publishedPath = Join-Path $repository "fingvibe-ui-review-pages\ui-review\pr-123\run-456\$($capture.FileName)"
            if (-not (Test-Path -LiteralPath $publishedPath)) { throw "Missing published capture $($capture.Scenario)." }
            $url = "https://test.github.io/repo/ui-review/pr-123/run-456/$($capture.FileName)"
            $heading = "### $($capture.Label)"
            $image = "[![$($capture.Label)]($url)]($url)"
            if ([regex]::Matches($comment, [regex]::Escape($image)).Count -ne 1 -or
                [regex]::Matches($comment, [regex]::Escape($heading)).Count -ne 1) {
                throw "PR comment must include every capture's heading and inline image exactly once."
            }
            foreach ($reason in $capture.Reasons) {
                if ($comment.Contains($reason)) {
                    throw "Detailed selection reasons belong in the capture plan and logs, not the screenshot comment."
                }
            }
        }
        $savedPlan = @(Read-UiReviewCapturePlan $planPath)
        Assert-Equal $savedPlan[0].Reasons $plan[0].Reasons "Keep detailed reasons in the capture manifest"
        if (-not $comment.Contains("<!-- fingvibe-ui-review -->")) { throw "Missing stable comment marker." }
        Remove-Item -LiteralPath (Join-Path $repository $plan[1].FileName)
        Assert-Throws {
            & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 457
        } "*Required screenshot*was not found*"
    }
    finally {
        Remove-Item Function:\git, Function:\gh
        $env:GH_TOKEN = $savedToken
        $env:GITHUB_OUTPUT = $savedOutput
        $env:RUNNER_TEMP = $savedTemp
    }

    # A stateful WebDriver double checks navigation and page sentinels without launching WinUI.
    $sessionId = "test"
    $script:currentPage = "Overview"
    $script:empty = $false
    $script:hiddenControl = ""
    $script:brokenNavigation = $false
    $script:toolsScrollPercent = 0
    $script:toolsScrollCalls = 0
    $script:offscreenToolsCard = ""
    $script:detailsScrollPercent = 0
    $script:detailsScrollCalls = 0
    $script:detailsScrollable = $true
    $script:offscreenDetailsControl = ""
    $script:personAssignmentsFocused = $false
    function Show-UiReviewPersonAssignments([switch] $Top) {
        $script:personAssignmentsFocused = -not $Top
    }
    function Get-UiReviewToolsScroll([string] $Name) {
        $scroll = [pscustomobject]@{}
        $scroll | Add-Member ScriptMethod SetScrollPercent {
            param($Horizontal, $Vertical)
            if ($Horizontal -ne -1) { throw "Tools scrolling must preserve horizontal position." }
            $script:toolsScrollPercent = $Vertical
            $script:toolsScrollCalls += 1
        }
        return $scroll
    }
    function Get-UiReviewDetailsScroll {
        $scroll = [pscustomobject]@{ Current = [pscustomobject]@{ VerticallyScrollable = $script:detailsScrollable } }
        $scroll | Add-Member ScriptMethod SetScrollPercent {
            param($Horizontal, $Vertical)
            if ($Horizontal -ne -1) { throw "Details scrolling must preserve horizontal position." }
            $script:detailsScrollPercent = $Vertical
            $script:detailsScrollCalls += 1
        }
        return $scroll
    }
    function Find-WebDriverElement([string] $Using, [string] $Value) {
        if ($Value -eq "Completed backups, newest first") { throw "The collapsed backups table has no automation peer." }
        if ($Using -eq "xpath") {
            if ($Value -match "^//ListItem\[@Name='(.+)'\]$") { return "menu-$($Matches[1])" }
            if ($Value -eq "//List[@Name='Scan results']/ListItem[.//*[@Name='Online']][1]") { return "online-row" }
            if ($Value -eq "//*[@AutomationId='DeviceHistoryTab']") { return "control-DeviceHistoryTab" }
            if ($Value -eq "//List[@Name='People']/ListItem[.//*[@Name='UI review person']]") { return "person-row" }
            if ($Value -eq "//List[@Name='Rooms']/ListItem[.//*[@Name='UI review room']]") { return "room-row" }
            if ($Value -eq "//Button[@Name='About FingVibe & updates']") { return "control-About FingVibe & updates" }
            if ($Value -eq "//Button[@Name='Speed test']") { return "control-Speed test" }
            if ($Value -eq "//Button[@Name='Network troubleshooting']") { return "control-Network troubleshooting" }
            if ($Value -eq "//Button[@Name='Import from Fing']") { return "control-Import from Fing" }
            if ($Value -eq "//Button[@Name='SQL editor']") { return "control-SQL editor" }
            if ($Value -eq "//Button[@Name='Database backups']") { return "control-Database backups" }
            throw "Unexpected XPath '$Value'."
        }
        return "control-$Value"
    }
    function Invoke-WebDriverElement([string] $ElementId) {
        if ($ElementId -like "menu-*") {
            if (-not $script:brokenNavigation) { $script:currentPage = $ElementId.Substring(5) }
        }
        elseif ($ElementId -eq "online-row") { $script:currentPage = "DeviceDetails" }
        elseif ($ElementId -eq "control-DeviceHistoryTab") { $script:currentPage = "DeviceHistory" }
        elseif ($ElementId -eq "control-Speed test") { $script:currentPage = "SpeedTest" }
        elseif ($ElementId -eq "control-About FingVibe & updates") { $script:currentPage = "About" }
        elseif ($ElementId -eq "control-Network troubleshooting") { $script:currentPage = "Troubleshooting" }
        elseif ($ElementId -eq "control-Import from Fing") { $script:currentPage = "FingImport" }
        elseif ($ElementId -eq "control-SQL editor") { $script:currentPage = "SqlEditor" }
        elseif ($ElementId -eq "control-Database backups") { $script:currentPage = "DatabaseBackups" }
        elseif ($ElementId -eq "person-row") { $script:currentPage = "PersonDetails" }
        elseif ($ElementId -eq "room-row") { $script:currentPage = "RoomDetails" }
        else { throw "Unexpected click '$ElementId'." }
    }
    function Invoke-WebDriverRequest([string] $Method, [string] $Endpoint, [hashtable] $Body) {
        if ($Endpoint -notmatch '/element/(.+)/(displayed|selected|clear|value)$') {
            throw "Unexpected request '$Endpoint'."
        }
        $id, $operation = $Matches[1], $Matches[2]
        switch ($operation) {
            "selected" { return @{ value = ($script:currentPage -eq $id.Substring(5)) } }
            "clear" { $script:empty = $false; return @{} }
            "value" { $script:empty = $true; return @{} }
            "displayed" {
                if ($id -like "menu-*") { return @{ value = $true } }
                $visible = switch ($id) {
                    "control-Scan LAN" { $true }
                    "control-Search devices" { $script:currentPage -eq "Devices" }
                    "control-Online" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "online-row" { $script:currentPage -eq "Devices" -and -not $script:empty }
                    "person-row" { $script:currentPage -eq "People" }
                    "room-row" { $script:currentPage -eq "Rooms" }
                    "control-No devices match the current filter." { $script:currentPage -eq "Devices" -and $script:empty }
                    "control-Back to devices" { $script:currentPage -eq "DeviceDetails" }
                    "control-DeviceHistoryTab" { $script:currentPage -eq "DeviceDetails" }
                    "control-Activity" { $script:currentPage -eq "DeviceHistory" }
                    "control-Rename device" { $script:currentPage -eq "DeviceDetails" }
                    "control-Network overview" { $script:currentPage -eq "DeviceDetails" }
                    "control-Scan additional ports" { $script:currentPage -eq "DeviceDetails" }
                    "control-Room assignment saved." { $script:currentPage -eq "DeviceDetails" }
                    "control-Online devices" { $script:currentPage -eq "Overview" }
                    "control-Public IP address" { $script:currentPage -eq "Network" }
                    "control-Speed test" { $script:currentPage -eq "Tools" }
                    "control-Start Cloudflare speed test" { $script:currentPage -eq "SpeedTest" }
                    "control-About FingVibe & updates" { $script:currentPage -eq "Settings" }
                    "control-Network troubleshooting" { $script:currentPage -eq "Tools" }
                    "control-Import from Fing" { $script:currentPage -eq "Tools" }
                    "control-SQL editor" { $script:currentPage -eq "Tools" }
                    "control-SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Run SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Cancel SQL query" { $script:currentPage -eq "SqlEditor" }
                    "control-Database backups" { $script:currentPage -eq "Tools" }
                    "control-Back up now" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Open backup folder" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Completed backups" { $script:currentPage -eq "DatabaseBackups" }
                    "control-Browse Fing export" { $script:currentPage -eq "FingImport" }
                    "control-Analyze again" { $script:currentPage -eq "FingImport" }
                    "control-Run network troubleshooting" { $script:currentPage -eq "Troubleshooting" }
                    "control-Router WAN IPv4 address" { $script:currentPage -eq "Troubleshooting" }
                    "control-Back to Tools" { $script:currentPage -in @("Troubleshooting", "FingImport", "SqlEditor", "DatabaseBackups") }
                    "control-Back to Settings" { $script:currentPage -eq "About" }
                    "control-FingVibe LAN Scanner" { $script:currentPage -eq "About" }
                    "control-Search people" { $script:currentPage -eq "People" }
                    "control-Search rooms" { $script:currentPage -eq "Rooms" }
                    "control-Back to people" { $script:currentPage -eq "PersonDetails" }
                    "control-Back to rooms" { $script:currentPage -eq "RoomDetails" }
                    "control-Assigned devices" { $script:currentPage -eq "RoomDetails" -or
                        ($script:currentPage -eq "PersonDetails" -and $script:personAssignmentsFocused) }
                    "control-Assign devices" { $script:currentPage -eq "RoomDetails" -or
                        ($script:currentPage -eq "PersonDetails" -and $script:personAssignmentsFocused) }
                    "control-Appearance preferences" { $script:currentPage -eq "Settings" }
                    default { throw "Unexpected control '$id'." }
                }
                $offscreen = ($id -eq $script:offscreenToolsCard -and $script:toolsScrollPercent -lt 70) -or
                    ($id -eq $script:offscreenDetailsControl -and $script:detailsScrollPercent -lt 40)
                return @{ value = ($visible -and $id -ne $script:hiddenControl -and -not $offscreen) }
            }
        }
    }
    foreach ($scenario in $UiReviewScenarios.Keys) {
        Show-UiReviewCaptureScenario $scenario
        $expectedPage = if ($scenario -eq "DevicesEmpty") { "Devices" } else { $scenario }
        Assert-Equal $script:currentPage $expectedPage "Navigation: $scenario"
    }
    Show-UiReviewCaptureScenario "Devices"
    Assert-Equal $script:empty $false "Returning from empty results restores the baseline"
    $script:hiddenControl = "control-Completed backups"
    Assert-Throws { Show-UiReviewCaptureScenario "DatabaseBackups" } "*Completed backups*not visible*"
    $script:hiddenControl = ""
    Test-UiReviewNavigation
    $script:hiddenControl = "control-Scan LAN"
    Assert-Throws { Test-UiReviewNavigation } "*Scan LAN*not visible*"
    $script:hiddenControl = ""
    Assert-Equal $script:toolsScrollCalls 0 "Visible Tools cards must not scroll"
    $script:offscreenToolsCard = "control-About FingVibe & updates"
    Show-UiReviewCaptureScenario "About"
    Assert-Equal $script:currentPage "About" "Offscreen About card navigation"
    Assert-Equal $script:toolsScrollPercent 70 "Scroll until the Tools card is visible"
    Assert-Equal $script:toolsScrollCalls 8 "Stop scrolling immediately after visibility"
    $script:offscreenToolsCard = ""
    $script:hiddenControl = "control-About FingVibe & updates"
    $callsBeforeFailure = $script:toolsScrollCalls
    Assert-Throws { Show-UiReviewCaptureScenario "About" } "*not visible*"
    Assert-Equal ($script:toolsScrollCalls - $callsBeforeFailure) 11 "Invisible Tools cards retain a bounded failure"
    $script:hiddenControl = "control-Public IP address"
    Assert-Throws { Test-UiReviewNavigation } "*not visible*"
    Assert-Throws { Show-UiReviewCaptureScenario "Network" } "*not visible*"
    $script:hiddenControl = ""
    $script:hiddenControl = "control-Scan additional ports"
    Show-UiReviewCaptureScenario "DeviceDetails"
    $script:hiddenControl = "control-Network overview"
    Assert-Throws { Show-UiReviewCaptureScenario "DeviceDetails" } "*not visible*"
    $script:hiddenControl = "control-Run network troubleshooting"
    Show-UiReviewCaptureScenario "Troubleshooting"
    $script:hiddenControl = "control-Router WAN IPv4 address"
    Assert-Throws { Show-UiReviewCaptureScenario "Troubleshooting" } "*not visible*"
    $script:hiddenControl = ""
    foreach ($scenario in @("PersonDetails", "RoomDetails")) {
        $script:hiddenControl = "control-Assign devices"
        Assert-Throws { Show-UiReviewCaptureScenario $scenario } "*not visible*"
    }
    $script:hiddenControl = ""
    # The assignment feedback lives at the bottom of the tall Assignments card, below the first viewport.
    Show-UiReviewCaptureScenario "DeviceDetails"
    $null = Show-UiReviewDetailsControl -Value "Room assignment saved."
    Assert-Equal $script:detailsScrollCalls 0 "Visible details controls must not scroll"
    $script:offscreenDetailsControl = "control-Room assignment saved."
    $null = Show-UiReviewDetailsControl -Value "Room assignment saved."
    Assert-Equal $script:detailsScrollPercent 40 "Scroll until the assignment feedback is visible"
    Assert-Equal $script:detailsScrollCalls 5 "Stop scrolling immediately after visibility"
    Show-UiReviewDetailsTop
    Assert-Equal $script:detailsScrollPercent 0 "Return to the first viewport before using the pickers"
    $script:hiddenControl = "control-Room assignment saved."
    $callsBeforeFailure = $script:detailsScrollCalls
    Assert-Throws { Show-UiReviewDetailsControl -Value "Room assignment saved." } "*not visible*"
    Assert-Equal ($script:detailsScrollCalls - $callsBeforeFailure) 11 "Unreachable details controls retain a bounded failure"
    $script:detailsScrollable = $false
    $callsBeforeStatic = $script:detailsScrollCalls
    Assert-Throws { Show-UiReviewDetailsControl -Value "Room assignment saved." } "*not visible*"
    Show-UiReviewDetailsTop
    Assert-Equal $script:detailsScrollCalls $callsBeforeStatic "A page that cannot scroll must not be scrolled"
    $script:detailsScrollable = $true
    $script:offscreenDetailsControl = ""
    $script:hiddenControl = ""
    $script:brokenNavigation = $true
    Assert-Throws { Show-UiReviewCaptureScenario "Overview" } "*Navigation did not select*"
    Write-Host "UI review scenario selection, manifest, publishing, and navigation regression tests passed."
}
finally {
    Remove-Item -LiteralPath $repository -Recurse -Force
}
