$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\Agent3Coordination.psm1") -Force
$entry = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-Agent3Message.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-boundary-test-" + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$evidence = @("fixture://independent-host-correlation")
$sender = @{ agentId = "dispatcher"; automationId = $null; runId = $null; sessionId = "actual-dispatcher" }
$recipient = @{ agentId = "developer-1"; automationId = "automation-1"; runId = "run-1"; sessionId = "session-1" }

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching '$Pattern'."
}
function Copy-Record($Record) { $Record | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String }

try {
    $state = New-Agent3State testowner/testrepo 92 main `
        @{ reference = 'fixture://approval/"quoted"/{"path":"D:\\Igor\\nested"}'; implementation = $true; merge = $false } `
        @(@{ id = "developer-1"; name = "Worker 1"; automationId = "automation-1" },
            @{ id = "developer-2"; name = "Worker 2"; automationId = "automation-2" })
    $task = Add-Agent3Claim $state 100 $evidence
    $handoff = Add-Agent3Handoff $state $task.claimId developer-1 implement
    Set-Agent3Stage $state $task.claimId $handoff.id launch-requested -Evidence $evidence
    Set-Agent3Stage $state $task.claimId $handoff.id correlated -Evidence $evidence -RunId run-1 -SessionId session-1
    $context = @{ repository = $state.repository; epic = 92; issue = 100; claimId = $task.claimId; handoffId = $handoff.id }
    $statePath = Join-Path $root "state.json"
    $observationPath = Join-Path $root "observation.json"
    $specPath = Join-Path $root "spec.json"
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 100))
    [IO.File]::WriteAllText($observationPath, (@{ sender = $sender; recipient = $recipient; evidence = $evidence } | ConvertTo-Json -Depth 100))
    [IO.File]::WriteAllText($specPath, (@{ type = "assignment"; context = $context
        payload = Get-Agent3Assignment $state $task.claimId $handoff.id; inReplyTo = $null; record = $null } | ConvertTo-Json -Depth 100))
    $wire = & $entry -Action Prepare -InputPath $specPath -StatePath $statePath -Directory $root -ObservationPath $observationPath
    $message = $wire | ConvertFrom-Json -AsHashtable
    $messagePath = Join-Path $root "messages\$($message.messageId).json"
    if ($wire -cne [IO.File]::ReadAllText($messagePath)) { throw "Prepare must return the exact immutable serialization." }
    $request = New-Agent3DeliveryRequest $messagePath $state $sender $recipient $root `
        @{ session_id = $recipient.sessionId; delivery = "enqueue" } session_id
    $hostScript = Join-Path $root "host.ps1"
    [IO.File]::WriteAllText($hostScript, @'
param($RequestPath, $WirePath, $Entry, $StatePath, $Root, $ObservationPath)
$ErrorActionPreference = "Stop"
$request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
[IO.File]::WriteAllText($WirePath, $request.message)
& $Entry -Action Receive -InputPath $WirePath -StatePath $StatePath -Directory $Root -ObservationPath $ObservationPath
'@)
    $requestPath = Join-Path $root "host-request.json"
    $wirePath = Join-Path $root "received.json"
    $calls = @{ host = 0 }
    $transport = {
        param($json)
        $calls.host++
        [IO.File]::WriteAllText($requestPath, $json)
        $output = & pwsh -NoProfile -File $hostScript $requestPath $wirePath $entry $statePath $root $observationPath
        if ($LASTEXITCODE -ne 0) { throw "Fixture host failed." }
        $output -join "`n"
    }
    $altered = $request | ConvertFrom-Json -AsHashtable
    $altered.message = $altered.message.Replace('\\', '\')
    Assert-Throws {
        Send-Agent3Message ($altered | ConvertTo-Json -Depth 100 -Compress) $messagePath $state $sender $recipient $root session_id $transport
    } "*exact published JSON*"
    Assert-Throws {
        Send-Agent3Message '{"message":' $messagePath $state $sender $recipient $root session_id $transport
    } "*"
    $wrongRecipient = $request | ConvertFrom-Json -AsHashtable
    $wrongRecipient.session_id = "wrong-session"
    Assert-Throws {
        Send-Agent3Message ($wrongRecipient | ConvertTo-Json -Depth 100) $messagePath $state $sender $recipient $root session_id $transport
    } "*observed recipient*"
    if ($calls.host -ne 0) { throw "Invalid final payload must not reach the host." }
    $decision = Send-Agent3Message $request $messagePath $state $sender $recipient $root session_id $transport | ConvertFrom-Json
    if ($decision.operation -cne "acknowledge-implement" -or [IO.File]::ReadAllText($wirePath) -cne $wire) {
        throw "Escaped Windows paths/nested quotes must survive final request and actual Receive unchanged."
    }
    Assert-Throws {
        Send-Agent3Message $request $messagePath $state $sender $recipient $root session_id $transport
    } "*already reserved*"
    if ($calls.host -ne 1) { throw "Duplicate assignment must not call the host twice." }

    $uncertainRoot = Join-Path $root "uncertain"
    $uncertainMessage = New-Agent3Message assignment $sender $recipient $context $message.payload $uncertainRoot
    $uncertainPath = Publish-Agent3Message $uncertainMessage $state $sender $recipient $uncertainRoot
    $uncertainRequest = New-Agent3DeliveryRequest $uncertainPath $state $sender $recipient $uncertainRoot @{session_id="session-1"} session_id
    $failedHost = { param($json) $calls.host++; throw "Host receipt uncertain." }
    Assert-Throws { Send-Agent3Message $uncertainRequest $uncertainPath $state $sender $recipient $uncertainRoot session_id $failedHost } "*uncertain*"
    Assert-Throws { Send-Agent3Message $uncertainRequest $uncertainPath $state $sender $recipient $uncertainRoot session_id $failedHost } "*already reserved*"
    if ($calls.host -ne 2) { throw "Uncertain delivery must not repeat the adapter." }

    $rejectedRoot = Join-Path $root "rejected"
    $raw = '{"record":{"path":"D:\Igor\unescaped"},"payload":{"action":"implement"}}'
    $rejected = Receive-Agent3Message $raw $state $sender $recipient $rejectedRoot $evidence
    if ($rejected.responseAllowed -or $rejected.operation -cne "none" -or $null -ne $rejected.messageId) {
        throw "Malformed content must not grant acknowledgment, response or execution."
    }
    $event = @{ schema = "fingvibe-real-event-v1"; eventId = "result-$($handoff.id)"; kind = "result"
        claimId = $task.claimId; handoffId = $handoff.id; action = "implement"; workerId = "developer-1"
        runId = "run-1"; sessionId = "session-1"; utc = [DateTime]::UtcNow.ToString("o"); actor = "actual-worker"
        originalReporter = "actual-worker"; trigger = "unknown"; elapsedSeconds = $null; evidence = $evidence
        result = @{ outcome = "blocked-before-start"; head = $null; checkpoint = $null; evidence = $evidence } }
    $events = Join-Path $rejectedRoot "events"
    $badDecision = Copy-Record $rejected; $badDecision.responseAllowed = $true
    Assert-Throws { Publish-Agent3PreStartRejection $state $event developer-1 run-1 session-1 $events -Decision $badDecision -Sender $sender -Recipient $recipient } "*Record absent*"
    $spoofed = Copy-Record $sender; $spoofed.sessionId = "guessed"
    Assert-Throws { Publish-Agent3PreStartRejection $state $event developer-1 run-1 session-1 $events -Decision $rejected -Sender $spoofed -Recipient $recipient } "*observed endpoints*"
    $savedDiagnostic = [IO.File]::ReadAllText($rejected.diagnosticPath)
    $corruptDiagnostic = Read-Agent3Json $rejected.diagnosticPath
    $corruptDiagnostic.raw = "changed original content"
    [IO.File]::WriteAllText($rejected.diagnosticPath, ($corruptDiagnostic | ConvertTo-Json -Depth 100))
    Assert-Throws { Publish-Agent3PreStartRejection $state $event developer-1 run-1 session-1 $events -Decision $rejected -Sender $sender -Recipient $recipient } "*original content differs*"
    [IO.File]::WriteAllText($rejected.diagnosticPath, $savedDiagnostic)
    Assert-Throws { Publish-Agent3Event $event $events } "*actual Receive decision*"
    $eventMessage = New-Agent3Message result $recipient $sender $context $event $rejectedRoot
    Assert-Throws { Publish-Agent3Message $eventMessage $state $recipient $sender $rejectedRoot } "*actual Receive decision*"
    if ([IO.File]::Exists((Join-Path $events $event.eventId) + ".json")) { throw "Invalid evidence reserved immutable result." }
    $resultPath = Publish-Agent3PreStartRejection $state $event developer-1 run-1 session-1 $events -Decision $rejected -Sender $sender -Recipient $recipient
    $result = Read-Agent3Json $resultPath
    $diagnostic = Read-Agent3Json $rejected.diagnosticPath
    if ($rejected.diagnosticPath -cnotin $result.evidence -or $rejected.diagnosticPath -cnotin $result.result.evidence -or
        $diagnostic.raw -cne $raw -or $null -ne $diagnostic.inReplyTo -or [IO.File]::Exists((Join-Path $events "ack-$($handoff.id).json"))) {
        throw "Rejection must retain exact diagnostic/raw content and no acknowledgment."
    }
    $originalResult = [IO.File]::ReadAllText($resultPath)
    Assert-Throws { Publish-Agent3PreStartRejection $state $event developer-1 run-1 session-1 $events -Decision $rejected -Sender $sender -Recipient $recipient } "*Canonical acknowledgment/result exists*"
    if ([IO.File]::ReadAllText($resultPath) -cne $originalResult) { throw "Duplicate must not rewrite rejection history." }

    $remotePath = Join-Path $root "remote.json"
    $apiScript = Join-Path $root "api.ps1"
    [IO.File]::WriteAllText($apiScript, @'
param($InputPath, $RemotePath, $Number)
$ErrorActionPreference = "Stop"
$request = Get-Content -Raw -LiteralPath $InputPath | ConvertFrom-Json
$comment = @{ id = [int]$Number; body = $request.body; user = @{login="testowner"}
    issue_url = "https://api.github.com/repos/testowner/testrepo/issues/100"
    html_url = "https://github.com/testowner/testrepo/issues/100#issuecomment-$Number" }
$json = $comment | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText($RemotePath, $json)
$json
'@)
    $api = @{ writes = 0; mode = "success"; remote = @(); next = 500; methods = @() }
    $reader = {
        param($endpoint, $paginate)
        if ($paginate) {
            if ($api.remote.Count -eq 0) { return '[[]]' }
            return ConvertTo-Json -InputObject (,$api.remote) -Depth 100 -Compress
        }
        Read-Agent3Json $remotePath | ConvertTo-Json -Depth 100 -Compress
    }
    $writer = {
        param($endpoint, $inputFile, $method)
        $api.writes++
        $api.methods += $method
        if ($api.mode -ceq "pre-request") {
            $error = [InvalidOperationException]::new("Definitive fixture process-start failure.")
            $error.Data["agent3PublicationPhase"] = "pre-request"
            throw $error
        }
        if ($api.mode -ceq "uncertain-absent") { throw "Remote outcome uncertain." }
        $output = & pwsh -NoProfile -File $apiScript $inputFile $remotePath $api.next
        if ($LASTEXITCODE -ne 0) { throw "Fixture publication outcome uncertain." }
        $api.remote = @((Read-Agent3Json $remotePath))
        if ($api.mode -ceq "uncertain-success") { throw "Response lost after remote success." }
        $output -join "`n"
    }
    $body = "<!-- agent3-publication:large -->`n" + ('D:\Igor\"quoted" {"nested":"C:\\Users\\worker"}' * 8000)
    if ([Text.Encoding]::UTF8.GetByteCount($body) -le 32767) { throw "Fixture must exceed Windows command-line limit." }
    $url = Publish-Agent3GitHubComment testowner/testrepo 100 large $body testowner $root $reader $writer
    $null = Publish-Agent3GitHubComment testowner/testrepo 100 large $body testowner $root $reader $writer
    if ($api.writes -ne 1 -or (Read-Agent3Json $remotePath).body -cne $body -or $url -cnotlike "*issuecomment-500") {
        throw "Large file-backed body/readback and duplicate identity must remain exact."
    }
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 large ($body+"changed") testowner $root $reader $writer } "*Conflicting immutable*"
    $largeComment = $api.remote[0]
    $api.remote = @()
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 large $body testowner $root $reader $writer } "*Previously verified publication missing*"
    $api.remote = @($largeComment)
    $updatedBody = $body.Replace("agent3-publication:large", "agent3-publication:revision-2") + "`nnew revision"
    Assert-Throws {
        Publish-Agent3GitHubComment testowner/testrepo 100 revision-2 $updatedBody testowner $root $reader $writer `
            -CommentId 500 -ExpectedBody "stale"
    } "*expected body changed*"
    $null = Publish-Agent3GitHubComment testowner/testrepo 100 revision-2-retry `
        ($updatedBody.Replace("agent3-publication:revision-2", "agent3-publication:revision-2-retry")) `
        testowner $root $reader $writer -CommentId 500 -ExpectedBody $body
    if ($api.writes -ne 2 -or $api.methods[-1] -cne "PATCH" -or $api.remote.Count -ne 1 -or $api.remote[0].id -ne 500) {
        throw "Large claim update must retain the original comment/identity and file-backed PATCH."
    }
    $api.remote = @()
    $api.mode = "uncertain-absent"
    $unknownBody = "<!-- agent3-publication:unknown -->`noriginal"
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 unknown $unknownBody testowner $root $reader $writer } "*uncertain*"
    $afterUncertain = $api.writes
    $api.mode = "success"
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 unknown $unknownBody testowner $root $reader $writer } "*outcome uncertain*"
    if ($api.writes -ne $afterUncertain) { throw "Absent readback does not authorize uncertain retry." }
    $api.mode = "pre-request"
    $preBody = "<!-- agent3-publication:pre -->`noriginal"
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 pre $preBody testowner $root $reader $writer } "*Definitive fixture*"
    $api.mode = "success"; $api.next = 501
    $null = Publish-Agent3GitHubComment testowner/testrepo 100 pre $preBody testowner $root $reader $writer
    $api.remote = @(); $api.mode = "uncertain-success"; $api.next = 502
    $lostBody = "<!-- agent3-publication:lost -->`noriginal"
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 lost $lostBody testowner $root $reader $writer } "*Response lost*"
    $afterLost = $api.writes
    $null = Publish-Agent3GitHubComment testowner/testrepo 100 lost $lostBody testowner $root $reader $writer
    if ($api.writes -ne $afterLost) { throw "Uncertain success must be verified, not repeated." }
    $api.remote = @($api.remote[0], $api.remote[0])
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 lost $lostBody testowner $root $reader $writer } "*Duplicate GitHub publication identity*"
    $api.remote = @($api.remote[0])
    $api.remote[0].user.login = "wrong-account"
    [IO.File]::WriteAllText($remotePath, ($api.remote[0] | ConvertTo-Json -Depth 100))
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 lost $lostBody testowner $root $reader $writer } "*identity/content readback mismatch*"
    $api.remote[0].user.login = "testowner"
    $api.remote[0].body += "`nchanged content"
    [IO.File]::WriteAllText($remotePath, ($api.remote[0] | ConvertTo-Json -Depth 100))
    Assert-Throws { Publish-Agent3GitHubComment testowner/testrepo 100 lost $lostBody testowner $root $reader $writer } "*identity/content readback mismatch*"
    if ($api.writes -ne $afterLost) { throw "Conflicting readback must not repeat publication." }
    "Agent-3 publication boundary tests passed."
} finally {
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
