$ErrorActionPreference = "Stop"
$repository = Split-Path $PSScriptRoot -Parent

function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$setup = Get-Content -LiteralPath (Join-Path $repository "docs\agentic-loop-5\README.md") -Raw
$examples = [regex]::Matches($setup, '(?m)^You are (5[^\r\n]+)\.\r?\nEnvironment: loop5\r?$')
Assert-True ($examples.Count -ge 2) "Setup must show independently named UI examples without defining a fixed worker count."
Assert-True ($setup.Contains("examples, not an exhaustive or required list") -and
    $setup.Contains("No Developer count is assumed") -and
    $setup.Contains("the configured name is the stable worker identity")) "The source must support any count of workers and use the UI name as identity."
Assert-True ($setup.Contains("absent/contradictory") -and
    $setup.Contains("assignment names a different worker")) "Missing, contradictory and foreign worker names must block work."
Assert-True ($setup -notmatch 'Coordination identity:' -and
    $setup -notmatch 'Resolve-Agent5DeveloperIdentity') "No separate identity or validator is needed."
Assert-True ($setup -notmatch 'loop4|4️⃣') "Setup must not teach an older loop's mechanics or names."

$profiles = @(Get-ChildItem -LiteralPath (Join-Path $repository ".github\agents") -Filter "automation-5*developer*.agent.md")
Assert-True ($profiles.Count -eq 1) "Every worker must share one loop5 Developer definition, without identity wrappers."
$profile = Get-Content -LiteralPath $profiles[0].FullName -Raw
Assert-True ($profile -match '(?m)^name: Developer\r?$' -and
    $profile.Contains("docs/agentic-loop-5/README.md") -and
    $profile.Contains("exact worker name comes only from your own UI-specific")) "The shared profile must load setup and use only the UI-supplied name."
Assert-True ($profile -notmatch 'Your identity is|4️⃣ Developer|5️⃣Developer[0-9]') "The shared profile must not select or enumerate default workers."
Assert-True ($profile -notmatch 'Resolve-Agent5DeveloperIdentity|worker-1|worker-2') "The shared profile must not require a validator or numbered worker IDs."
$contract = Get-Content -LiteralPath (Join-Path $repository "docs\agentic-loop-5\developer.md") -Raw
Assert-True ($contract.Contains("These files are the")) "The loop5 contract must be self-contained for its source stage."
Assert-True ($contract -notmatch 'loop4|agentic-loop-4|4️⃣') "The loop5 Developer contract must not teach or reference another loop's mechanics."
Assert-True ($profile -notmatch 'loop4|4️⃣') "The loop5 agent definition must not teach another loop's mechanics."
Assert-True ($setup.Contains("another environment's") -and
    $setup.Contains("All of that live verification remains **pending**")) "Source validation must isolate loop5 without granting live authority."

Write-Host "Agent5 shared Developer source and identity checks passed."
