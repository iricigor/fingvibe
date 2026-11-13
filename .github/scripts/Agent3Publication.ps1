function Assert-Agent3DeliveryRequest([string] $Json, [string] $MessagePath, $State, $Sender, $Recipient,
    [string] $Directory, [string] $RecipientField) {
    $request = ConvertFrom-Agent3Json $Json
    $wire = [IO.File]::ReadAllText($MessagePath)
    $message = ConvertFrom-Agent3Json $wire
    Assert-Agent3MessageBinding $message $State $Sender $Recipient $Directory
    $canonical = Get-Agent3ProtocolPath $Directory "messages" $message.messageId
    if ($MessagePath -cne $canonical -or
        -not [string]::Equals($wire, [IO.File]::ReadAllText($canonical), [StringComparison]::Ordinal) -or
        -not $request.Contains("message") -or $request.message -isnot [string] -or
        -not [string]::Equals($wire, $request.message, [StringComparison]::Ordinal) -or
        -not $request.Contains($RecipientField) -or $request[$RecipientField] -cne $Recipient.sessionId) {
        throw "Final host request must preserve the exact published JSON and observed recipient."
    }
    $record = Read-Agent3Json $message.record.path
    if ((Get-Agent3Hash $record) -cne $message.record.hash -or
        ($message.type -cne "notification" -and (Get-Agent3Hash $message.payload) -cne $message.record.hash)) {
        throw "Outgoing payload publication mismatch."
    }
    if ($message.type -ceq "assignment") {
        $handoff = Find-Agent3Handoff $State $message.context.claimId $message.context.handoffId
        if ($handoff.stage -cnotin @("correlated", "delivered") -or
            [IO.File]::Exists((Get-Agent3ProtocolPath $Directory "events" "ack-$($handoff.id)")) -or
            [IO.File]::Exists((Get-Agent3ProtocolPath $Directory "events" "result-$($handoff.id)"))) {
            throw "Assignment already consumed; never replay."
        }
    }
    return $message
}

function New-Agent3DeliveryRequest {
    param([string] $MessagePath, $State, $Sender, $Recipient, [string] $Directory,
        $Arguments, [string] $RecipientField)
    Assert-Agent3Text $RecipientField "observed host recipient field"
    if ($Arguments -isnot [System.Collections.IDictionary] -or $Arguments.Contains("message")) {
        throw "Supply observed host arguments without hand-composing a message."
    }
    $request = @{} + $Arguments
    $request.message = [IO.File]::ReadAllText($MessagePath)
    $json = $request | ConvertTo-Json -Depth 100 -Compress
    $null = Assert-Agent3DeliveryRequest $json $MessagePath $State $Sender $Recipient $Directory $RecipientField
    return $json
}

function Send-Agent3Message {
    param([string] $RequestJson, [string] $MessagePath, $State, $Sender, $Recipient,
        [string] $Directory, [string] $RecipientField, [Parameter(Mandatory)] [scriptblock] $Transport)
    $message = Assert-Agent3DeliveryRequest $RequestJson $MessagePath $State $Sender $Recipient $Directory $RecipientField
    $path = Get-Agent3ProtocolPath $Directory "outgoing" $message.messageId
    if ([IO.File]::Exists($path)) { throw "Delivery already reserved; inspect the host, never resend uncertain delivery." }
    Write-Agent3Atomic @{ messageId = $message.messageId; requestJson = $RequestJson; utc = [DateTime]::UtcNow.ToString("o") } `
        $path -Immutable
    # The adapter must consume this exact string, not reconstruct tool arguments in prose.
    & $Transport $RequestJson
}

function Invoke-Agent3GitHubRead([string] $Endpoint, [bool] $Paginate) {
    $text = if ($Paginate) { gh api -X GET $Endpoint --paginate --slurp } else { gh api -X GET $Endpoint }
    if ($LASTEXITCODE -ne 0) { throw "GitHub read failed: $Endpoint. Remote publication is not verified." }
    $text -join "`n"
}

function Invoke-Agent3GitHubWrite([string] $Endpoint, [string] $InputPath, [string] $Method) {
    $start = [Diagnostics.ProcessStartInfo]::new("gh")
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @("api", "--method", $Method, $Endpoint, "--input", $InputPath)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        try {
            if (-not $process.Start()) { throw [InvalidOperationException]::new("gh did not start.") }
        } catch {
            $_.Exception.Data["agent3PublicationPhase"] = "pre-request"
            throw
        }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $output.GetAwaiter().GetResult()
        $stderr = $errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "GitHub publication outcome uncertain after gh started (exit $($process.ExitCode)): $stderr"
        }
        return $stdout
    } finally { $process.Dispose() }
}

function Publish-Agent3GitHubComment {
    param([string] $Repository, [int] $Issue, [string] $Id, [string] $Body, [string] $ActorLogin,
        [string] $Directory, [scriptblock] $ApiReader = ${function:Invoke-Agent3GitHubRead},
        [scriptblock] $ApiWriter = ${function:Invoke-Agent3GitHubWrite},
        [long] $CommentId = 0, [string] $ExpectedBody)
    if ($Repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$' -or $Issue -lt 1) {
        throw "Invalid publication repository/issue."
    }
    Assert-Agent3Text $ActorLogin "independently established publishing account"
    $marker = "<!-- agent3-publication:$Id -->"
    Assert-Agent3Text $Body "publication body"
    if (-not $Body.Contains($marker)) { throw "Publication body must contain its stable identity marker." }
    $root = [IO.Path]::GetDirectoryName((Get-Agent3ProtocolPath $Directory "publications" $Id))
    $root = Join-Path $root $Id
    $requestPath = Join-Path $root "request.json"
    $endpoint = "repos/$Repository/issues/$Issue/comments"
    $method = if ($CommentId -eq 0) { "POST" } else { "PATCH" }
    if ($CommentId -lt 0 -or ($CommentId -gt 0 -and [string]::IsNullOrWhiteSpace($ExpectedBody))) {
        throw "Updating a claim mirror requires its actual comment ID and freshly verified expected body."
    }
    $writeEndpoint = if ($CommentId -eq 0) { $endpoint } else { "repos/$Repository/issues/comments/$CommentId" }
    $identity = @{ endpoint = $writeEndpoint; method = $method; actorLogin = $ActorLogin
        bodyHash = Get-Agent3Hash @{ body = $Body }; expectedBodyHash = Get-Agent3Hash @{ body = $ExpectedBody } }
    $identityPath = Join-Path $root "identity.json"
    Write-Agent3ProtocolRecord $identity $identityPath
    Write-Agent3ProtocolRecord @{ body = $Body } $requestPath
    $pages = & $ApiReader $endpoint $true | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 -NoEnumerate
    if ($pages -isnot [array]) { throw "Complete paginated GitHub comment inventory is required." }
    $matches = @(foreach ($page in $pages) {
        if ($page -isnot [array]) { throw "Invalid paginated GitHub comment page." }
        foreach ($comment in $page) {
            Assert-Agent3Fields $comment @("body")
            if ($comment.body -isnot [string]) { throw "Invalid GitHub comment body." }
            if ($comment.body.Contains($marker)) { $comment }
        }
    })
    if ($matches.Count -gt 1) { throw "Duplicate GitHub publication identity; human reconciliation required." }
    $attempts = @(Get-ChildItem -LiteralPath $root -Filter "attempt-*.json" -File)
    if ($matches.Count -eq 0) {
        if ([IO.File]::Exists((Join-Path $root "verified.json"))) {
            throw "Previously verified publication missing; human reconciliation required, not recreation."
        }
        foreach ($attempt in $attempts) {
            $reserved = Read-Agent3Json $attempt.FullName
            if ((Get-Agent3Hash $reserved.identity) -cne (Get-Agent3Hash $identity)) {
                throw "Conflicting publication attempt identity."
            }
            $failurePath = Join-Path $root "pre-request-$($reserved.number).json"
            if (-not [IO.File]::Exists($failurePath) -or
                (Get-Agent3Hash (Read-Agent3Json $failurePath)) -cne (Get-Agent3Hash $reserved)) {
                throw "Prior publication outcome uncertain; absence on readback does not authorize retry."
            }
        }
        if ($CommentId -gt 0) {
            $current = ConvertFrom-Agent3Json (& $ApiReader $writeEndpoint $false)
            Assert-Agent3Fields $current @("id", "body", "user", "issue_url")
            Assert-Agent3Fields $current.user @("login")
            if ($current.id -ne $CommentId -or $current.user.login -ine $ActorLogin -or
                $current.issue_url -cne "https://api.github.com/repos/$Repository/issues/$Issue" -or
                -not [string]::Equals($current.body, $ExpectedBody, [StringComparison]::Ordinal)) {
                throw "Claim mirror identity/expected body changed before update; do not publish."
            }
        }
        $number = $attempts.Count + 1
        $reservation = @{ number = $number; identity = $identity; utc = [DateTime]::UtcNow.ToString("o") }
        Write-Agent3Atomic $reservation (Join-Path $root "attempt-$number.json") -Immutable
        try { $response = & $ApiWriter $writeEndpoint $requestPath $method }
        catch {
            if ($_.Exception.Data["agent3PublicationPhase"] -ceq "pre-request") {
                Write-Agent3Atomic $reservation (Join-Path $root "pre-request-$number.json") -Immutable
            }
            throw
        }
        $published = ConvertFrom-Agent3Json $response
    } else { $published = $matches[0] }
    Assert-Agent3Fields $published @("id")
    if (($published.id -isnot [long] -and $published.id -isnot [int]) -or $published.id -lt 1 -or
        ($CommentId -gt 0 -and $published.id -ne $CommentId)) {
        throw "Publication response has no verified comment ID; outcome uncertain."
    }
    $readback = ConvertFrom-Agent3Json (& $ApiReader "repos/$Repository/issues/comments/$($published.id)" $false)
    Assert-Agent3Fields $readback @("id", "body", "user", "issue_url", "html_url")
    Assert-Agent3Fields $readback.user @("login")
    if ($readback.id -ne $published.id -or $readback.body -isnot [string] -or
        -not [string]::Equals($readback.body, $Body, [StringComparison]::Ordinal) -or
        $readback.user.login -ine $ActorLogin -or
        $readback.issue_url -cne "https://api.github.com/repos/$Repository/issues/$Issue" -or
        $readback.html_url -cne "https://github.com/$Repository/issues/$Issue#issuecomment-$($published.id)") {
        throw "GitHub publication identity/content readback mismatch; do not retry."
    }
    Write-Agent3ProtocolRecord @{ identity = $identity; commentId = $readback.id; url = $readback.html_url } `
        (Join-Path $root "verified.json")
    return $readback.html_url
}
