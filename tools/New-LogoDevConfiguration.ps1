param(
    [Parameter(Mandatory)]
    [string] $OutputPath
)

$ErrorActionPreference = "Stop"
$key = [string] $env:LOGO_DEV_PUBLISHABLE_KEY
if ($key -and $key -cnotmatch '^pk_[A-Za-z0-9_-]+$') {
    throw "LOGO_DEV_PUBLISHABLE_KEY must be a Logo.dev publishable key."
}

$path = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
[IO.File]::WriteAllText($path, $key, [Text.UTF8Encoding]::new($false))
