# Feature source contracts: history row lookup and backup copy expansion in native suites.
& {
    foreach ($source in @(
        @{ File = 'DeviceScanHistory.Ui.Tests.Shared.ps1'; Function = 'Find-HistoryDeviceRow' },
        @{ File = 'DatabaseBackups.Ui.Tests.ps1'; Function = 'Expand-BackupCopies' })) {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $source.File), [ref]$null, [ref]$errors)
        Assert-Regression (-not $errors) "$($source.File) must parse."
        $helper = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $source.Function
        }, $true)
        Assert-Regression ($null -ne $helper) "$($source.Function) must exist."
        Invoke-Expression $helper.Extent.Text
    }
    $linkingSource = Join-Path $PSScriptRoot 'DeviceLinking.Ui.Tests.ps1'
    $linkingErrors = $null
    $linkingAst = [Management.Automation.Language.Parser]::ParseFile(
        $linkingSource, [ref]$null, [ref]$linkingErrors)
    Assert-Regression (-not $linkingErrors) 'DeviceLinking.Ui.Tests.ps1 must parse.'
    $linkingFunctions = @{}
    foreach ($name in @('Show-Link', 'Invoke-Link', 'Select-LinkChoice')) {
        $function = $linkingAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Assert-Regression ($null -ne $function) "$name must exist."
        $linkingFunctions[$name] = $function.Extent.Text
    }
    Assert-Regression (
        $linkingFunctions['Show-Link'].Contains('Find-Link DeviceBackButton') -and
        $linkingFunctions['Show-Link'].Contains('Show-UiRegressionScrollTargets')) `
        'Device Details linking must use both its fixed Back control and measured positioning.'
    Assert-Regression (
        $linkingFunctions['Show-Link'].IndexOf('Find-Link DeviceBackButton') -lt
        $linkingFunctions['Show-Link'].IndexOf('Show-UiRegressionScrollTargets')) `
        'Device Details linking must move focus to its fixed Back control before measured scrolling.'
    foreach ($name in @('Invoke-Link', 'Select-LinkChoice')) {
        Assert-Regression (
            $linkingFunctions[$name].Contains('Show-Link $Id') -and
            $linkingFunctions[$name].Contains('.SetFocus()')) `
            "$name must position and then focus its peer."
        Assert-Regression (
            $linkingFunctions[$name].IndexOf('Show-Link $Id') -lt
            $linkingFunctions[$name].IndexOf('.SetFocus()')) `
            "$name must position the peer before focusing it so WinUI cannot revert the measured scroll."
    }
    function Wait-UiRegressionState([scriptblock] $Condition, [string] $Description) {
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            $result = & $Condition
            if ($result) { return $result }
        }
        throw "Timed out waiting for $Description."
    }
    & {
        $state = @{ Polls = 0; Available = $true }
        $fakeName = [pscustomobject]@{ Current = [pscustomobject]@{ Name = 'previous filter' } }
        $fakeRow = [pscustomobject]@{ NameCell = $fakeName; Current = [pscustomobject]@{
            IsOffscreen = $false; BoundingRectangle = [Windows.Rect]::new(0, 0, 300, 40) } }
        $fakeRow | Add-Member ScriptMethod FindFirst { param($Scope, $Condition)
            if ($Condition.Value -ne 'DeviceNameText') { throw 'History lookup escaped its name cell.' }
            return $this.NameCell
        }
        $fakeList = [pscustomobject]@{ Current = $fakeRow.Current; State = $state; Row = $fakeRow }
        $fakeList | Add-Member ScriptMethod FindAll { param($Scope, $Condition)
            $this.State.Polls++
            if ($Scope -ne [System.Windows.Automation.TreeScope]::Children) { throw 'History lookup escaped the list.' }
            if (-not $this.State.Available -or $this.State.Polls -eq 1) { return @() }
            if ($this.State.Polls -ge 3) { $this.Row.NameCell.Current.Name = 'History normal' }
            return @($this.Row)
        }
        $pattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = 'History normal' } }
        $fakeSearch = [pscustomobject]@{ Pattern = $pattern }
        $fakeSearch | Add-Member ScriptMethod GetCurrentPattern { param($PatternId) return $this.Pattern }
        function Select-HistoryDevices {}
        function Find-HistoryControl([string] $Value, [switch] $ByName, [switch] $Optional) {
            switch ($Value) {
                'ResultsList' { return $fakeList }
                'Search devices' { return $fakeSearch }
                default { throw "Unexpected history lookup: $Value." }
            }
        }
        Assert-Regression ((Find-HistoryDeviceRow 'History normal') -eq $fakeRow -and $state.Polls -eq 3) `
            'History lookup must await reconstruction and the exact current filtered name.'
        $state.Available = $false
        Assert-RegressionFailure { Find-HistoryDeviceRow 'History normal' } '*Timed out*History normal*'
    }
    & {
        $state = @{ Polls = 0; Available = $true; Positions = 0 }
        $fakeRows = [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = [Windows.Rect]::Empty } }
        $fakeSummary = [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = [Windows.Rect]::new(0, 0, 300, 50) } }
        $fakeExpander = [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = [Windows.Rect]::new(0, 0, 400, 220) } }
        $pattern = [pscustomobject]@{}
        $pattern | Add-Member ScriptMethod Expand {}
        $fakeExpander | Add-Member NoteProperty Pattern $pattern
        $fakeExpander | Add-Member ScriptMethod GetCurrentPattern { param($PatternId) return $this.Pattern }
        function Find-BackupControl([string] $Id) {
            switch ($Id) {
                'CompletedBackupsExpander' { return $fakeExpander }
                'BackupCount' { return $fakeSummary }
                'BackupRows' {
                    $state.Polls++
                    $fakeRows.Current.BoundingRectangle = if (-not $state.Available -or $state.Polls -eq 1) { [Windows.Rect]::Empty }
                        elseif ($state.Polls -eq 2) { [Windows.Rect]::new(0, 20, 300, 100) }
                        else { [Windows.Rect]::new(0, 80, 300, 100) }
                    return $fakeRows
                }
                default { throw "Unexpected backup lookup: $Id." }
            }
        }
        function Show-BackupAction([string] $Id) {
            if ($Id -eq 'BackupRows') {
                if ($state.Polls -lt 4) { throw 'Positioning happened before expanded layout settled.' }
                $state.Positions++
            }
        }
        Expand-BackupCopies
        Assert-Regression ($state.Polls -eq 4 -and $state.Positions -eq 1) `
            'Expansion must await nonempty, unclipped and stable content bounds before positioning.'
        $state.Available = $false
        $state.Positions = 0
        Assert-RegressionFailure { Expand-BackupCopies } '*Timed out*completed backup contents*'
        Assert-Regression ($state.Positions -eq 0) 'Missing expanded content must fail without positioning.'
    }
}
