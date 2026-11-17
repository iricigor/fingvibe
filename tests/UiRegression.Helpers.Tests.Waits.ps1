# Shared foundation: state waits and UI Automation assembly loading.
$state = @{ Attempts = 0 }
$result = Wait-UiRegressionState -Description 'current result' -PollMilliseconds 1 -Condition {
    $state.Attempts++
    if ($state.Attempts -eq 2) { return 'ready' }
}
Assert-Regression ($result -eq 'ready' -and $state.Attempts -eq 2) 'Wait must return the current successful result.'
foreach ($condition in @({ $false }, { $null }, {})) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Assert-RegressionFailure { Wait-UiRegressionState -Condition $condition -Description 'bounded failure' -TimeoutMilliseconds 20 -PollMilliseconds 5 } '*20 ms*bounded failure*'
    Assert-Regression ($clock.ElapsedMilliseconds -ge 20 -and $clock.ElapsedMilliseconds -lt 2000) 'Wait did not respect its deadline.'
}
Assert-RegressionFailure { Wait-UiRegressionState -Description 'unexpected error' -Condition { throw 'unexpected condition error' } } 'unexpected condition error'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
