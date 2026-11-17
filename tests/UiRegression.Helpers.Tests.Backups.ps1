# Database backups feature helpers: cleanup ownership.
function Test-DatabaseBackupCleanup {
    param([string] $TestRoot = $PSScriptRoot)
    $tokens = $null
    $parseErrors = $null
    $backupAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $TestRoot 'DatabaseBackups.Ui.Tests.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw $parseErrors[0] }
    $backupTry = @($backupAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $cleanup = [scriptblock]::Create((@($backupTry.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $savedProcess = $script:process
    foreach ($primaryFailed in @($true, $false)) {
        $root = New-UiRegressionFixtureDirectory -Suite backup-cleanup
        $fixture = Join-Path $root 'inventory'
        $ScreenshotDirectory = Join-Path $root 'captures'
        $environment = Save-UiRegressionEnvironment @('FINGVIBE_BACKUP_CLEANUP_TEST')
        try {
            $null = New-Item -ItemType Directory -Path $fixture, $ScreenshotDirectory
            $env:FINGVIBE_BACKUP_CLEANUP_TEST = 'changed'
            $failure = if ($primaryFailed) { [InvalidOperationException]::new('primary backup failure') } else { $null }
            $phase = Start-UiRegressionPhase 'Backups/synthetic'
            $script:process = [pscustomobject]@{ Disposed = $false }
            $script:process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            function Stop-UiRegressionApp { throw 'synthetic backup close failure' }
            if ($primaryFailed) { & $cleanup 3>$null }
            else { Assert-RegressionFailure { & $cleanup 3>$null } 'synthetic backup close failure' }
            Assert-Regression ($script:process.Disposed -and -not (Test-Path -LiteralPath $fixture)) 'Backup cleanup must dispose and remove its fixture even when closing fails.'
            Assert-Regression ([Environment]::GetEnvironmentVariable('FINGVIBE_BACKUP_CLEANUP_TEST') -eq $environment.FINGVIBE_BACKUP_CLEANUP_TEST) 'Backup cleanup must restore its environment after a close failure.'
            $record = Get-Content (Join-Path $ScreenshotDirectory 'phases.jsonl') -Raw | ConvertFrom-Json
            Assert-Regression ($record.succeeded -eq (-not $primaryFailed)) 'Backup phase completion must retain the primary check outcome.'
        }
        finally {
            $script:process = $savedProcess
            Restore-UiRegressionEnvironment $environment
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
Test-DatabaseBackupCleanup
