& (Join-Path $PSScriptRoot '..\BuildIdentity.Ui.Tests.ps1') -AppPath $AppPath `
    -ScreenshotDirectory (Join-Path $ScreenshotDirectory 'build-identity') `
    -Version $Version -BuildKind $BuildKind -BuildTimestamp $BuildTimestamp `
    -BuildCommit $BuildCommit -PullRequestNumber $PullRequestNumber
