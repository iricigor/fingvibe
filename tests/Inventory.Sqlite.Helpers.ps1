function Initialize-InventorySqlite([string] $AppPath) {
    $directory = Split-Path -Parent $AppPath
    $null = [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $directory "e_sqlite3.dll"))
    foreach ($name in @("SQLitePCLRaw.core.dll", "SQLitePCLRaw.provider.e_sqlite3.dll",
        "SQLitePCLRaw.batteries_v2.dll", "Microsoft.Data.Sqlite.dll")) {
        $null = [System.Reflection.Assembly]::LoadFrom((Join-Path $directory $name))
    }
    [SQLitePCL.Batteries_V2]::Init()
}

function Get-InventorySqliteValue([string] $Path, [string] $Sql) {
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadOnly;Pooling=False")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = $Sql
            return $command.ExecuteScalar()
        }
        finally { $command.Dispose() }
    }
    finally { $connection.Dispose() }
}

function Get-InventoryFingerprint([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-InventoryMalformedTimestamp {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateSet("scan_history", "scan_evidence")][string] $Table,
        [Parameter(Mandatory)][scriptblock] $WhileMalformed
    )
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadWrite;Pooling=False")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = "SELECT rowid FROM $Table ORDER BY completed_ticks DESC LIMIT 1"
            $id = $command.ExecuteScalar()
            if ($null -eq $id) { throw "The malformed-evidence fixture needs a saved timestamp in $Table." }
            $null = $command.Parameters.AddWithValue('$id', $id)
            $command.CommandText = "SELECT completed_at FROM $Table WHERE rowid=`$id"
            $null = $command.Parameters.AddWithValue('$original', $command.ExecuteScalar())
            # Keep the indexed ticks/selection unchanged while making its timestamp inconsistent.
            $command.CommandText = "UPDATE $Table SET completed_at='2000-01-01T00:00:00+00:00' WHERE rowid=`$id"
            if ($command.ExecuteNonQuery() -ne 1) { throw "The malformed-evidence fixture did not change exactly one timestamp." }
            $failure = $null
            try { & $WhileMalformed }
            catch { $failure = $_; throw }
            finally {
                try {
                    $command.CommandText = "UPDATE $Table SET completed_at=`$original WHERE rowid=`$id"
                    if ($command.ExecuteNonQuery() -ne 1) { throw "The malformed-evidence fixture could not restore its timestamp." }
                }
                catch {
                    if ($failure) { Write-Warning "Timestamp restoration also failed: $_" }
                    else { throw }
                }
            }
        }
        finally { $command.Dispose() }
    }
    finally { $connection.Dispose() }
}
