# Shared foundation: asynchronous surface status parsing and waits.
& {
    $idle = ConvertFrom-UiRegressionSurfaceStatus 'Idle'
    Assert-Regression ($idle.State -eq 'Idle' -and $idle.Request -eq 0) 'Idle must parse without a request.'
    $ready = ConvertFrom-UiRegressionSurfaceStatus 'Ready (request 12): Last 30 days, 1-hour cells'
    Assert-Regression ($ready.State -eq 'Ready' -and $ready.Request -eq 12 -and $ready.Selection -eq 'Last 30 days, 1-hour cells') 'Status must parse state, request and selection.'
    foreach ($status in @($null, '', 'ready (request 1): x', 'Ready (request 0): x', 'Ready: x', 'Done (request 1): x')) {
        Assert-RegressionFailure { ConvertFrom-UiRegressionSurfaceStatus $status } '*Unrecognized async surface status*'
    }

    $states = [Collections.Generic.Queue[string]]::new()
    function New-StateElement([string] $Status) { [pscustomobject]@{ Current = [pscustomobject]@{ ItemStatus = $Status } } }
    $script:surfaceStatus = $null
    $getElement = { $next = if ($states.Count -gt 0) { $states.Dequeue() } else { $script:surfaceStatus }; $script:surfaceStatus = $next; New-StateElement $next }
    foreach ($status in @('Ready (request 3): old', 'Loading (request 4): new', 'Ready (request 4): other', 'Ready (request 5): new')) { $states.Enqueue($status) }
    $result = Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -Selection 'new' -After 3 -PollMilliseconds 1
    Assert-Regression ($result.Request -eq 5 -and $result.Selection -eq 'new') 'Wait must skip old requests, loading and other selections.'

    $states.Enqueue('Error (request 6): new')
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -After 5 -PollMilliseconds 1 } '*surface reported Error (request 6)*'
    $states.Enqueue('Error (request 7): new')
    $failed = Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -State Error -After 6 -PollMilliseconds 1
    Assert-Regression ($failed.Request -eq 7) 'Error must be awaitable when expected.'

    $script:surfaceStatus = 'Ready (request 7): new'
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement $getElement -Description 'surface' -After 7 -TimeoutMilliseconds 20 -PollMilliseconds 1 } '*Last state: Ready (request 7): new'
    Assert-RegressionFailure { Wait-UiRegressionSurfaceState -GetElement { $null } -Description 'surface' -TimeoutMilliseconds 20 -PollMilliseconds 1 } 'Timed out*has no UI Automation peer.'
    $script:surfacePolls = 0
    $appearing = { $script:surfacePolls++; if ($script:surfacePolls -gt 2) { [pscustomobject]@{ Current = [pscustomobject]@{ ItemStatus = 'Ready (request 9): later' } } } }
    Assert-Regression ((Wait-UiRegressionSurfaceState -GetElement $appearing -Description 'surface' -After 8 -PollMilliseconds 1).Request -eq 9) 'A surface hidden during navigation is awaited, not failed'
}
