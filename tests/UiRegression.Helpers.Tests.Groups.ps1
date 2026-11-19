# Shared foundation: group runner orchestration, call costs and cleanup.
function Get-RegressionSignature([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", '').Trim())
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Test-RegressionGroupOrchestration($Suite, [hashtable] $Definition, [string] $Root) {
    $moduleDirectory = Join-Path $Root 'UiRegression'
    $null = New-Item -ItemType Directory -Path $moduleDirectory
    foreach ($name in @($Definition.Preconditions) + @($Definition.Groups | ForEach-Object { $_.Modules })) {
        $initializers = if ($Definition.Preconditions.Count) { @($Definition.Preconditions[0]) }
            else { @($Definition.Groups | ForEach-Object { $_.Modules[0] }) }
        $initialization = if ($name -in $initializers) {
            @'
if ($null -ne $groupToken -or $null -ne $process) { throw 'Group state leaked across groups.' }
$groupToken = [Guid]::NewGuid()
$process = 'app'
$env:FINGVIBE_FOUNDATION_GROUP = "$groupToken"
'@
        } else { '' }
        $script = $initialization + "`n" + @"
`$state.Events.Add('$name')
if (`$null -eq `$groupToken -or `$env:FINGVIBE_FOUNDATION_GROUP -ne "`$groupToken") { throw 'Scenario state was lost within a group.' }
if (`$state.FailAt -eq '$name') { throw 'Synthetic module failure: $name' }
"@
        $script | Set-Content -LiteralPath (Join-Path $moduleDirectory "$($Suite.name).$name.Scenario.ps1")
    }
    $savedSummary = $env:GITHUB_STEP_SUMMARY
    $savedGroup = $env:FINGVIBE_FOUNDATION_GROUP
    try {
        $env:GITHUB_STEP_SUMMARY = $null
        $env:FINGVIBE_FOUNDATION_GROUP = 'outer'
        $invoke = {
            param([string] $Group, [scriptblock[]] $Cleanup = @({ $state.Cleanups.Add("$process") }))
            Invoke-UiRegressionGroups -Suite $Suite.name -Definition $Definition -Group $Group -ModuleDirectory $moduleDirectory `
                -Directory $Root -EnvironmentNames @('FINGVIBE_FOUNDATION_GROUP') -StateVariables @('process') `
                -OnFailure { param($FailedGroup) $state.Failures.Add("${FailedGroup}:$process") } -Cleanup $Cleanup
        }
        $newState = { @{ Events = [Collections.Generic.List[string]]::new(); Cleanups = [Collections.Generic.List[string]]::new(); Failures = [Collections.Generic.List[string]]::new(); FailAt = $null } }
        $expectedEvents = { param($Groups) @($Groups | ForEach-Object { @($Definition.Preconditions) + @($_.Modules) }) -join ',' }
        $groups = @($Definition.Groups)

        $state = & $newState
        & $invoke All
        Assert-Regression (($state.Events -join ',') -eq (& $expectedEvents $groups)) 'Every group must run its preconditions and modules exactly once.'
        Assert-Regression ($state.Cleanups.Count -eq $groups.Count -and -not ($state.Cleanups -ne 'app')) 'Cleanup must run once per group with that group''s state.'
        Assert-Regression ($state.Failures.Count -eq 0 -and $env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'Passing groups must restore the environment.'

        $state = & $newState
        $state.FailAt = $groups[0].Modules[0]
        Assert-RegressionFailure { & $invoke All } "*groups failed: $($groups[0].Name) (Synthetic module failure: $($state.FailAt))"
        $failedEvents = @(@($Definition.Preconditions) + $state.FailAt) + @(& $expectedEvents ($groups | Select-Object -Skip 1))
        Assert-Regression (($state.Events -join ',') -eq (($failedEvents | Where-Object { $_ }) -join ',')) 'A failed group must stop, and later groups must still run.'
        Assert-Regression (($state.Failures -join ',') -eq "$($groups[0].Name):app") 'Failure diagnostics must run once with the failed group''s state.'
        Assert-Regression ($state.Cleanups.Count -eq $groups.Count -and $env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'Failed groups must still clean up and restore the environment.'
        $record = @(Get-Content -LiteralPath (Join-Path $Root 'phases.jsonl') | ConvertFrom-Json |
            Where-Object phase -eq "$($Suite.name)/$($groups[0].Name)/$($state.FailAt)")[-1]
        Assert-Regression ($record -and -not $record.succeeded) 'Group orchestration must retain the failed phase.'

        $state = & $newState
        & $invoke $groups[-1].Name.ToUpperInvariant()
        Assert-Regression (($state.Events -join ',') -eq (& $expectedEvents @($groups[-1]))) 'Selecting a group must run only that group.'
        Assert-RegressionFailure { & $invoke 'no-such-group' } "Unknown UI regression group 'no-such-group'*"

        $state = & $newState
        Assert-RegressionFailure { & $invoke $groups[0].Name @({ throw 'cleanup broke' }) } "*groups failed: $($groups[0].Name) (cleanup broke)" 3>$null
        Assert-Regression ($env:FINGVIBE_FOUNDATION_GROUP -eq 'outer') 'A failed cleanup step must not skip environment restoration.'
    }
    finally {
        $env:GITHUB_STEP_SUMMARY = $savedSummary
        $env:FINGVIBE_FOUNDATION_GROUP = $savedGroup
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\coverage.json') -Raw | ConvertFrom-Json
foreach ($suite in $manifest.suites) {
    $entry = Join-Path $PSScriptRoot $suite.entry
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$errors)
    Assert-Regression (-not $errors) "Entry $entry must parse."
    if ($suite.groupDefinition) {
        $groupDefinition = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\$($suite.groupDefinition)")
        $orchestration = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-UiRegressionGroups' }, $true)
        Assert-Regression ($null -ne $orchestration -and $ast.Extent.Text.Contains($suite.groupDefinition)) "$($suite.name) must run its declared groups."
        Assert-Regression ((@($groupDefinition.Preconditions) -join ',') -eq 'Setup,Ready') 'Every group must start from its own Setup and Ready preconditions.'
        $grouped = @($groupDefinition.Groups | ForEach-Object { $_.Modules })
        $behavior = @($suite.scenarioOrder | Where-Object { $_ -ne 'Setup' })
        Assert-Regression ((@($grouped | Sort-Object) -join ',') -eq (@($behavior | Sort-Object) -join ',')) "$($suite.name) groups must run every behavior module exactly once."
        Assert-Regression (@($groupDefinition.Groups.Name | Select-Object -Unique).Count -eq @($groupDefinition.Groups).Count) 'Group names must be unique.'
        foreach ($regressionGroup in $groupDefinition.Groups) {
            $indices = @($regressionGroup.Modules | ForEach-Object { [Array]::IndexOf([string[]]$suite.scenarioOrder, $_) })
            Assert-Regression (($indices -join ',') -eq (@($indices | Sort-Object) -join ',')) "Group $($regressionGroup.Name) must keep the original module order."
            Assert-Regression ($regressionGroup.Name -cmatch '^[a-z0-9-]+$') 'Group names must be valid CI suite suffixes.'
        }
        Assert-Regression (@($suite.files | Where-Object { $_.file -eq "$($suite.name).Ready.Scenario.ps1" -and $_.kind -eq 'precondition' }).Count -eq 1) 'The Ready precondition must be mapped.'
    }
    else {
        $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'regressionModule' }, $true)
        $order = @($loop.Condition.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
        Assert-Regression (($order -join ',') -eq ($suite.scenarioOrder -join ',')) "$($suite.name) scenario order changed."
        $execution = $loop.Body.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Dot' }, $true)
        Assert-Regression ($null -ne $execution) 'Modules must execute at entry script scope, preserving inter-scenario state.'
    }
    $loadedHelpers = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '\.Helpers\.ps1$'
    }, $true) | ForEach-Object { [IO.Path]::GetFileName($_.Value) })
    $requiredHelpers = @($suite.files | Where-Object kind -eq 'helpers' | ForEach-Object file)
    Assert-Regression (($loadedHelpers -join ',') -eq ($requiredHelpers -join ',')) 'Every mapped helper must be loaded exactly once in the original dependency order.'
    foreach ($module in $suite.files) {
        $path = Join-Path $PSScriptRoot "UiRegression\$($module.file)"
        $errors = $null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-Regression (-not $errors) "Module $path must parse."
        if (-not $module.refactored) {
            Assert-Regression ((Get-RegressionSignature $moduleAst.Extent.Text) -eq $module.baselineSha256) "Unchanged coverage in $path differs from the baseline."
        }
        $functions = @($moduleAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        Assert-Regression (($functions.Name -join ',') -eq ($module.functions.name -join ',')) "A mapped function was lost or duplicated in $path."
        foreach ($definition in $module.functions) {
            $actual = @($functions | Where-Object Name -eq $definition.name)[0]
            if (-not $definition.refactored) {
                Assert-Regression ((Get-RegressionSignature $actual.Extent.Text) -eq $definition.baselineSha256) "Unchanged function $($definition.name) differs from baseline."
            }
            if ($definition.name -in @('Test-DeviceRefresh', 'Save-SidebarAppearance', 'Save-DeviceCapture')) {
                $assertions = @($actual.Body.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true) |
                    ForEach-Object { Get-RegressionSignature $_.Extent.Text })
                foreach ($assertion in $definition.assertions) {
                    Assert-Regression ($assertion -in $assertions) "Behavioral failure coverage in $($definition.name) was lost."
                }
            }
        }
        $captures = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Save-DeviceCapture', 'Save-SidebarAppearance', 'Save-ScheduledScanFailure')
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($captures -join ',') -eq ($module.captures -join ',')) "Capture coverage/order changed in $path."
        $fixtureAssignments = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$results'
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($fixtureAssignments -join ',') -eq ($module.fixtureAssignments -join ',')) "Synthetic fixture data changed in $path."
    }
    $fixtureRoot = New-UiRegressionFixtureDirectory -Suite foundation-test
    if ($suite.groupDefinition) {
        try { Test-RegressionGroupOrchestration -Suite $suite -Definition $groupDefinition -Root $fixtureRoot }
        finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        continue
    }
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'UiRegression')
        foreach ($name in $suite.scenarioOrder) {
            $script = @"
`$events.Add('$name')
if ('$name' -eq 'Setup') { `$sharedSelection = `$invocation }
elseif (`$sharedSelection -ne `$invocation) { throw 'Scenario state was lost across scopes.' }
if (`$failAt -eq '$name') { throw 'Synthetic module failure: $name' }
"@
            $script | Set-Content -LiteralPath (Join-Path $fixtureRoot "UiRegression\$($suite.name).$name.Scenario.ps1")
        }
        $loopSource = $loop.Extent.Text.Replace('$PSScriptRoot', '$fixtureRoot')
        $ScreenshotDirectory = $fixtureRoot
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $null
        Invoke-Expression $loopSource
        Assert-Regression (($events -join ',') -eq ($suite.scenarioOrder -join ',')) 'Original orchestration must execute every scenario exactly once with shared state.'
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $suite.scenarioOrder[1]
        Assert-RegressionFailure { Invoke-Expression $loopSource } "Synthetic module failure: $failAt"
        Assert-Regression ($events.Count -eq 2) 'A failed scenario must stop later scenarios rather than succeed.'
        $record = Get-Content -LiteralPath (Join-Path $fixtureRoot 'phases.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        Assert-Regression (-not $record.succeeded -and $record.phase -eq "$($suite.name)/$failAt") 'Original orchestration must retain the failed phase.'
    }
    finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
& {
    $definition = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\Tools.Groups.psd1')
    $root = New-UiRegressionFixtureDirectory -Suite tools-foundation
    try {
        Test-RegressionGroupOrchestration -Suite @{ name = 'Tools' } -Definition $definition -Root $root
        $modules = @($definition.Groups | ForEach-Object { $_.Modules })
        Assert-Regression (($modules -join ',') -eq 'Identity,NetworkHealth,Import,Updates,Backups,Services,Sql') 'Tools must run focused updates exactly once while retaining all original checks and their relative order.'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
& {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-call-costs-$([Guid]::NewGuid().ToString('N'))"
    $savedSummary = $env:GITHUB_STEP_SUMMARY
    try {
        $env:GITHUB_STEP_SUMMARY = $null
        $null = New-Item -ItemType Directory -Path $directory
        $script:UiRegressionCallCosts = $null
        $script:UiRegressionCallStack = $null
        $phase = Step-UiRegressionPhase $null 'costs/first' $directory
        $outer = Start-UiRegressionCall positioning
        $inner = Start-UiRegressionCall lookup
        Start-Sleep -Milliseconds 30
        Complete-UiRegressionCall $inner
        Complete-UiRegressionCall $outer
        $phase = Step-UiRegressionPhase $phase 'costs/second' $directory
        $abandoned = Start-UiRegressionCall wait
        $closing = Start-UiRegressionCall close
        Complete-UiRegressionCall $closing
        Complete-UiRegressionCall $abandoned
        $phase = Step-UiRegressionPhase $phase $null $directory
        Assert-Regression ($null -eq $phase) 'Completing the last phase must leave no open phase.'
        Write-UiRegressionCallCosts -Directory $directory -Name 'Synthetic.Ui'
        $costs = Get-Content -LiteralPath (Join-Path $directory 'call-costs.json') -Raw | ConvertFrom-Json
        $lookup = @($costs.entries | Where-Object { $_.phase -eq 'costs/first' -and $_.category -eq 'lookup' })[0]
        $positioning = @($costs.entries | Where-Object { $_.phase -eq 'costs/first' -and $_.category -eq 'positioning' })[0]
        Assert-Regression ($costs.check -eq 'Synthetic.Ui' -and $lookup.calls -eq 1 -and $lookup.exclusiveMilliseconds -ge 25) 'Call costs must record per-phase lookups.'
        Assert-Regression ($positioning.inclusiveMilliseconds -ge $lookup.inclusiveMilliseconds -and
            $positioning.exclusiveMilliseconds -lt $lookup.exclusiveMilliseconds) 'Nested lookup time must be excluded from positioning.'
        Assert-Regression (@($costs.entries | Where-Object phase -eq 'costs/second').Count -eq 2) 'Calls must be attributed to the active phase.'
        $phases = @(Get-Content -LiteralPath (Join-Path $directory 'phases.jsonl') | ConvertFrom-Json)
        Assert-Regression ((($phases.phase) -join ',') -eq 'costs/first,costs/second' -and -not ($phases.succeeded -contains $false)) 'Phase steps must close each phase successfully.'
    }
    finally {
        $env:GITHUB_STEP_SUMMARY = $savedSummary
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}
& {
    $ran = [Collections.Generic.List[string]]::new()
    Invoke-UiRegressionCleanup -PrimaryFailed $true -Steps @({ $ran.Add('first'); throw 'cleanup broke' }, { $ran.Add('second') }) 3>$null
    Assert-Regression (($ran -join ',') -eq 'first,second') 'Cleanup must run every step after a failing step.'
    Assert-RegressionFailure { Invoke-UiRegressionCleanup -PrimaryFailed $false -Steps @({ throw 'cleanup broke' }) 3>$null } 'cleanup broke'
}
