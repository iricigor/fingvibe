# Publishing and manifest: capture plan roundtrip and screenshot publication.
    $planPath = Join-Path $repository "plan.json"
    $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network"))
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Equal @(Read-UiReviewCapturePlan $planPath).Scenario @("Devices", "Network") "Manifest roundtrip"
    $plan[1].FileName = "..\unexpected.png"
    ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*Invalid capture definition*"
    '[]' | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*must include the Devices baseline*"
    $plan = @(Get-UiReviewCapturePlan $repository)
    ConvertTo-Json -InputObject @($plan[0], $plan[0]) -Depth 5 | Set-Content $planPath
    Assert-Throws { Read-UiReviewCapturePlan $planPath } "*duplicate capture scenario*"

    $savedToken = $env:GH_TOKEN
    $savedOutput = $env:GITHUB_OUTPUT
    $savedTemp = $env:RUNNER_TEMP
    try {
        $env:GH_TOKEN = "test-placeholder"
        $env:GITHUB_OUTPUT = Join-Path $repository "output.txt"
        $env:RUNNER_TEMP = $repository
        function gh { $global:LASTEXITCODE = 0 }
        function git {
            $global:LASTEXITCODE = if ($args[0] -eq "ls-remote") { 2 } else { 0 }
            if ($args -contains "diff") { $global:LASTEXITCODE = 1 }
        }
        $plan = @(Get-UiReviewCapturePlan $repository -AdditionalScenarios @("Network", "DevicesEmpty"))
        ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content $planPath
        foreach ($capture in $plan) {
            Set-Content -LiteralPath (Join-Path $repository $capture.FileName) -Value "capture fixture"
        }
        $publishScript = Join-Path $PSScriptRoot "..\.github\scripts\Publish-UiReviewScreenshot.ps1"
        & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 456
        $comment = Get-Content (Join-Path $repository "pr-comment.md") -Raw
        foreach ($capture in $plan) {
            $publishedPath = Join-Path $repository "fingvibe-ui-review-pages\ui-review\pr-123\run-456\$($capture.FileName)"
            if (-not (Test-Path -LiteralPath $publishedPath)) { throw "Missing published capture $($capture.Scenario)." }
            $url = "https://test.github.io/repo/ui-review/pr-123/run-456/$($capture.FileName)"
            $heading = "### $($capture.Label)"
            $image = "[![$($capture.Label)]($url)]($url)"
            if ([regex]::Matches($comment, [regex]::Escape($image)).Count -ne 1 -or
                [regex]::Matches($comment, [regex]::Escape($heading)).Count -ne 1) {
                throw "PR comment must include every capture's heading and inline image exactly once."
            }
            foreach ($reason in $capture.Reasons) {
                if ($comment.Contains($reason)) {
                    throw "Detailed selection reasons belong in the capture plan and logs, not the screenshot comment."
                }
            }
        }
        $savedPlan = @(Read-UiReviewCapturePlan $planPath)
        Assert-Equal $savedPlan[0].Reasons $plan[0].Reasons "Keep detailed reasons in the capture manifest"
        if (-not $comment.Contains("<!-- fingvibe-ui-review -->")) { throw "Missing stable comment marker." }
        Remove-Item -LiteralPath (Join-Path $repository $plan[1].FileName)
        Assert-Throws {
            & $publishScript -ManifestPath $planPath -PullRequestNumber 123 -Repository "test/repo" -RunId 457
        } "*Required screenshot*was not found*"
    }
    finally {
        Remove-Item Function:\git, Function:\gh
        $env:GH_TOKEN = $savedToken
        $env:GITHUB_OUTPUT = $savedOutput
        $env:RUNNER_TEMP = $savedTemp
    }
