$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\Agent4Coordination.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-Agent4DispatcherPacket.ps1") -Directory ([IO.Path]::GetTempPath())
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-loop4-test-" + [guid]::NewGuid())
$gateDirectory = Join-Path $root "gate"
$directory = Join-Path $root "loop4"
$gateScript = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-DispatcherGate.ps1"
$owner = [guid]::NewGuid()

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern."
}
function New-Fixture {
    New-Agent4State @{
        repository = "TestOwner/TestRepo"; epic = 92; targetBranch = "main"; maxRepairAttempts = 1
        authorization = @{ reference = "fixture://original-owner-approval"; implementation = $true; merge = $true }
        workers = @(@{ id = "developer-1"; name = "Developer 1"; automationId = "auto-1" },
            @{ id = "developer-2"; name = "Developer 2"; automationId = "auto-2" })
    }
}
function New-Packet($State, [int[]] $Numbers = @(101, 102, 103, 104)) {
    @{ schema = "fingvibe-loop4-packet-v1"; repository = "TestOwner/TestRepo"; epic = 92
        targetBranch = "main"; revision = $State.revision; evidencePath = "fixture://evidence"
        candidates = @($Numbers | ForEach-Object { @{ issue = $_; url = "fixture://issue/$_" } }) }
}
$hosts = @(@{ workerId = "developer-1"; automationId = "auto-1"; status = "idle"; evidence = @("fixture://host") },
    @{ workerId = "developer-2"; automationId = "auto-2"; status = "stopped"; evidence = @("fixture://host") })
function New-Response($State, $Offer, [int] $Preferred = 0) {
    if (-not $Preferred) { $Preferred = $Offer.candidates[0].issue }
    @{ schema = "fingvibe-loop4-worker-v1"; id = [guid]::NewGuid().ToString(); kind = "response"
        workerId = $Offer.workerId; automationId = ($State.configuration.workers | Where-Object id -CEQ $Offer.workerId).automationId
        runId = $Offer.runId; sessionId = $Offer.sessionId; utc = [DateTimeOffset]::UtcNow.ToString("o")
        evidence = @("fixture://semantic-assessment"); offerId = $Offer.id; assessedRevision = $State.revision
        decision = "propose"; issue = $Preferred
        evaluations = @($Offer.candidates | ForEach-Object { @{ issue = $_.issue; eligible = $true
            overlap = $(if ($_.issue -eq $Preferred) { 0 } else { 2 })
            reasonCode = "suitable"; reason = "Scope and contracts are independent."; evidence = @("fixture://diffs") } }) }
}
function Get-Actor($Record) {
    @{ workerId = $Record.workerId; automationId = $Record.automationId; runId = $Record.runId; sessionId = $Record.sessionId }
}
function New-Progress($State, $Claim, [string] $Kind, [string] $Outcome = "implementation-ready") {
    $handoff = $Claim.handoffs[-1]
    @{ schema = "fingvibe-loop4-worker-v1"; id = [guid]::NewGuid().ToString(); kind = $Kind
        workerId = $Claim.workerId; automationId = ($State.configuration.workers | Where-Object id -CEQ $Claim.workerId).automationId
        runId = $handoff.runId; sessionId = $handoff.sessionId; handoffId = $handoff.id; claimId = $Claim.id
        utc = [DateTimeOffset]::UtcNow.ToString("o"); evidence = @("fixture://progress")
        outcome = $Outcome; context = @{ branch = "task-101"; worktree = Join-Path $root "task-101"; pr = "fixture://pr"; head = "a" * 40 } }
}
try {
    $null = & $gateScript Acquire TestOwner/TestRepo $owner $gateDirectory
    $state = New-Fixture
    Save-Agent4State $state $directory -1 $owner $gateDirectory
    Assert-Fails { Save-Agent4State $state $directory -1 $owner $gateDirectory } "*not authoritatively absent*"
    Assert-Fails { Save-Agent4State $state $directory 0 ([guid]::NewGuid()) $gateDirectory } "*gate mismatch*"
    $state = New-Agent4Offers $state (New-Packet $state) $hosts
    Assert-True (($state.offers[0].candidates.issue -join ",") -eq "101,103") "Dev1 needs positions 1/3."
    Assert-True (($state.offers[1].candidates.issue -join ",") -eq "102,104") "Dev2 needs positions 2/4."
    Save-Agent4State $state $directory 0 $owner $gateDirectory
    Assert-Fails { New-Agent4Offers $state (New-Packet (New-Fixture)) $hosts } "*Stale*"
    $short = New-Agent4Offers (New-Fixture) (New-Packet (New-Fixture) @(101)) $hosts
    Assert-True ($short.offers.Count -eq 1) "Fewer than four tasks must not fabricate candidates."
    $oneAvailable = Copy-Agent4Record @{ hosts = $hosts }
    $oneAvailable.hosts[0].status = "running"
    $firstPass = New-Agent4Offers (New-Fixture) (New-Packet (New-Fixture) @(101)) $oneAvailable.hosts
    Assert-True ($firstPass.offers.Count -eq 0) "Initial distribution must remain alternating."
    $laterPass = New-Agent4Offers $firstPass (New-Packet $firstPass @(101)) $oneAvailable.hosts
    Assert-True ($laterPass.offers.Count -eq 1 -and $laterPass.offers[0].workerId -eq "developer-2") "A sole idle worker must receive stranded candidates on a later pass."
    Assert-Fails { New-Agent4Offers (New-Fixture) (New-Packet (New-Fixture)) @() } "*host availability*"
    $state = Set-Agent4OfferHost $state $state.offers[0].id run-1 session-1 @("fixture://launch")
    $state = Set-Agent4OfferHost $state $state.offers[1].id run-2 session-2 @("fixture://launch")
    $response1 = New-Response $state $state.offers[0] 103
    $response2 = New-Response $state $state.offers[1]
    $path = Publish-Agent4WorkerRecord $state $response1 (Get-Actor $response1) $directory
    Assert-Fails { Publish-Agent4WorkerRecord $state $response1 (Get-Actor $response1) $directory } "*already exists*"
    $wrong = Get-Actor $response1; $wrong.sessionId = "different"
    Assert-Fails { Confirm-Agent4Response $state $response1 $wrong @("fixture://fresh") } "*identity mismatch*"
    $state = Confirm-Agent4Response $state (Read-Agent4Json $path) (Get-Actor $response1) @("fixture://fresh")
    Assert-True ($state.claims[0].issue -eq 103) "Choose lower overlap, not always first candidate."
    Assert-Fails { Confirm-Agent4Response $state $response2 (Get-Actor $response2) @("fixture://fresh") } "*Stale assessment*"
    $response2.assessedRevision = $state.revision
    $state = Confirm-Agent4Response $state $response2 (Get-Actor $response2) @("fixture://fresh")
    Assert-True ($state.claims.Count -eq 2) "Two independent assessed assignments should be possible."
    Write-Agent4Json (Join-Path $directory "state.json") $state -Replace
    $reset = Copy-Agent4Record $state
    $reset.claims = @(); $reset.revision++
    Assert-Fails { Save-Agent4State $reset $directory $state.revision $owner $gateDirectory } "*remove/reset a claim*"
    $status = New-Progress $state $state.claims[0] status
    $null = Publish-Agent4WorkerRecord $state $status (Get-Actor $status) $directory
    Assert-Fails { Set-Agent4Progress $state $status (Get-Actor $status) } "*Wrong progress context*"
    $noOffers = New-Agent4Offers $state (New-Packet $state @(105, 106, 107, 108)) $hosts
    Assert-True ($noOffers.offers.Count -eq 2) "Occupied workers must not receive offers."
    $claim = $state.claims[0]
    $result = New-Progress $state $claim result
    Assert-Fails { Publish-Agent4WorkerRecord $state $result (Get-Actor $result) $directory } "*Could not find*"
    Assert-Fails { Set-Agent4Progress $state $result (Get-Actor $result) } "*Unacknowledged*"
    $ack = New-Progress $state $claim ack
    $null = Publish-Agent4WorkerRecord $state $ack (Get-Actor $ack) $directory
    $state = Set-Agent4Progress $state $ack (Get-Actor $ack)
    Assert-Fails { Publish-Agent4WorkerRecord $state $ack (Get-Actor $ack) $directory } "*already exists*"
    Assert-Fails { Set-Agent4Progress $state $ack (Get-Actor $ack) } "*Duplicate*"
    $null = Publish-Agent4WorkerRecord $state $result (Get-Actor $result) $directory
    $state = Set-Agent4Progress $state $result (Get-Actor $result)
    $waiting = New-Agent4Offers $state (New-Packet $state @(105,106)) $hosts
    Assert-True ($waiting.offers.Count -eq 2) "Validation waits retain worker slots."
    Assert-Fails { Release-Agent4Claim $state $claim.id @("stop") @("merged") @("cleanup") } "*Only delivered*"
    Assert-Fails { New-Agent4Followup $state $claim.id repair run-1 session-1 @() @("feedback") ("a"*40) } "*evidence*"
    $state = New-Agent4Followup $state $claim.id repair run-1 session-1 @("stop") @("failure") ("a"*40)
    $claim = $state.claims[0]
    Assert-True ($claim.repairCount -eq 1 -and $claim.handoffs.Count -eq 2) "Repairs must preserve history/count."
    $ack = New-Progress $state $claim ack
    $state = Set-Agent4Progress $state $ack (Get-Actor $ack)
    $result = New-Progress $state $claim result
    $state = Set-Agent4Progress $state $result (Get-Actor $result)
    Assert-Fails { New-Agent4Followup $state $claim.id repair run-1 session-1 @("stop") @("failure") ("a"*40) } "*exhausted*"
    $state = New-Agent4Followup $state $claim.id finalize run-1 session-1 @("stop") @("current-head-green") ("a"*40)
    $claim = $state.claims[0]
    $ack = New-Progress $state $claim ack
    $state = Set-Agent4Progress $state $ack (Get-Actor $ack)
    $result = New-Progress $state $claim result delivered
    $state = Set-Agent4Progress $state $result (Get-Actor $result)
    Assert-Fails { Release-Agent4Claim $state $claim.id @("stop") @("merged") @() } "*evidence*"
    $state = Release-Agent4Claim $state $claim.id @("stop") @("merged") @("cleanup")
    $refilled = New-Agent4Offers $state (New-Packet $state @(105,106,107,108)) $hosts
    Assert-True ($refilled.offers.Count -eq 3) "Only verified released worker can refill."
    $other = $state.claims[1]
    $otherAck = New-Progress $state $other ack
    $null = Publish-Agent4WorkerRecord $state $otherAck (Get-Actor $otherAck) $directory
    $state = Set-Agent4Progress $state $otherAck (Get-Actor $otherAck)
    $earlyBlocker = New-Progress $state $other result blocked
    $earlyBlocker.context = $null
    $null = Publish-Agent4WorkerRecord $state $earlyBlocker (Get-Actor $earlyBlocker) $directory
    $state = Set-Agent4Progress $state $earlyBlocker (Get-Actor $earlyBlocker)
    Assert-True ($state.claims[1].stage -eq "blocked" -and -not $state.claims[1].context) "Pre-PR failure must retain a real blocked result."
    Assert-Fails { New-Agent4Followup $state $other.id repair run-2 session-2 @("stop") @("feedback") ("a"*40) } "*blocked work needs human recovery*"
    $inputPath = Join-Path $root "configuration.json"
    Write-Agent4Json $inputPath (New-Fixture).configuration
    $cliDirectory = Join-Path $root "cli"
    $cli = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-Agent4Coordination.ps1"
    $null = & $cli Initialize $cliDirectory $inputPath $owner $gateDirectory
    $initialized = Read-Agent4Json (Join-Path $cliDirectory "state.json")
    Assert-True ($initialized.revision -eq 0) "CLI initialization must persist verified state."
    $roundTrip = Copy-Agent4Record $result
    Assert-True ($roundTrip.context.worktree -ceq $result.context.worktree) "Windows paths must round-trip."
    Write-Host "Agent4 coordination checks passed."
} finally {
    $null = & $gateScript Release TestOwner/TestRepo $owner $gateDirectory
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
