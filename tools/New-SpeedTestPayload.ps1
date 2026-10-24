param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Path,

    [ValidateRange(1, 4096)]
    [int] $SizeMiB = 256
)

$ErrorActionPreference = "Stop"
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
$buffer = New-Object byte[] (1MB)
$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$stream = $null

try {
    $stream = [System.IO.File]::Open(
        $destination,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    for ($chunk = 0; $chunk -lt $SizeMiB; $chunk++) {
        $random.GetBytes($buffer)
        $stream.Write($buffer, 0, $buffer.Length)
    }
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
    $random.Dispose()
}

Get-Item -LiteralPath $destination
