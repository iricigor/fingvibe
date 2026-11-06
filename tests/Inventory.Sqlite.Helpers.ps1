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
