[CmdletBinding()]
param(
    [string] $DisplayName,
    [string] $Developer,
    [string] $AssignmentDeveloper
)

$ErrorActionPreference = "Stop"

function Resolve-Agent5DeveloperIdentity {
    [CmdletBinding()]
    param(
        [string] $DisplayName,
        [string] $Developer,
        [string] $AssignmentDeveloper
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName) -or [string]::IsNullOrWhiteSpace($Developer)) {
        throw "loop5 setup blocker: explicit UI display name and coordination identity are both required."
    }

    $expectedName = switch -CaseSensitive ($Developer) {
        "developer-1" { "5$([char]0xfe0f)$([char]0x20e3)Developer1" }
        "developer-2" { "5$([char]0xfe0f)$([char]0x20e3)Developer2" }
        default { throw "loop5 setup blocker: unsupported coordination identity '$Developer'." }
    }
    if ($DisplayName -cne $expectedName) {
        throw "loop5 setup blocker: display name '$DisplayName' does not match '$Developer' ('$expectedName')."
    }
    if ($PSBoundParameters.ContainsKey("AssignmentDeveloper") -and $AssignmentDeveloper -cne $Developer) {
        throw "loop5 assignment identity mismatch: expected '$Developer', received '$AssignmentDeveloper'."
    }

    [pscustomobject]@{ displayName = $DisplayName; developer = $Developer }
}

if ($MyInvocation.InvocationName -ne ".") {
    Resolve-Agent5DeveloperIdentity @PSBoundParameters | ConvertTo-Json -Compress
}
