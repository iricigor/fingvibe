param(
    [Parameter(Mandatory)]
    [ValidateSet("Acquire", "Release")]
    [string] $Action,

    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")]
    [string] $Repository,

    [Parameter(Mandatory)]
    [guid] $Owner,

    [string] $StateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination")
)

$ErrorActionPreference = "Stop"
if ($Owner -eq [guid]::Empty) { throw "Dispatcher gate owner must be a nonempty UUID." }
if (-not [IO.Path]::IsPathFullyQualified($StateDirectory)) {
    throw "Dispatcher gate state directory must be absolute."
}
$parts = $Repository.ToLowerInvariant().Split("/")
$directory = Join-Path $StateDirectory $parts[0]
$path = Join-Path $directory "$($parts[1]).dispatch.json"

if ($Action -eq "Acquire") {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw "Cannot acquire Dispatcher gate '$path': $($_.Exception.Message) Existing or uncertain gates require human reconciliation; never expire or overwrite them."
    }
    try {
        $record = @{
            schema = "fingvibe-dispatch-gate-v1"
            repository = $Repository.ToLowerInvariant()
            owner = $Owner.ToString()
            acquiredUtc = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($record)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    Write-Output $record
    return
}

$stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 1024, $true)
    try { $record = $reader.ReadToEnd() | ConvertFrom-Json }
    finally { $reader.Dispose() }
    if ($record.schema -ne "fingvibe-dispatch-gate-v1" -or
        $record.repository -cne $Repository.ToLowerInvariant() -or
        $record.owner -cne $Owner.ToString()) {
        throw "Dispatcher gate '$path' does not belong to this run; human reconciliation is required."
    }
} finally {
    $stream.Dispose()
}
[IO.File]::Delete($path)
Write-Output "Released Dispatcher gate for $Repository, owner $Owner."
