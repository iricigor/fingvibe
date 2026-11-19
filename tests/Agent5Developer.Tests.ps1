$ErrorActionPreference = "Stop"
$repository = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repository ".github\scripts\Resolve-Agent5DeveloperIdentity.ps1"
. $script

function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}

$setup = Get-Content -LiteralPath (Join-Path $repository "docs\agentic-loop-5\README.md") -Raw
$prompts = [regex]::Matches($setup, '(?m)^You are ([^\r\n]+)\.\r?\nCoordination identity: ([^\r\n]+)\r?\nEnvironment: loop5\r?$')
Assert-True ($prompts.Count -eq 2) "Both worker UI prompts must explicitly supply their own loop5 identity."
$identities = @()
foreach ($prompt in $prompts) {
    $name = $prompt.Groups[1].Value
    $developer = $prompt.Groups[2].Value
    $identity = & $script -DisplayName $name -Developer $developer | ConvertFrom-Json
    Assert-True ($identity.displayName -ceq $name -and $identity.developer -ceq $developer) "UI identities must round-trip without rewriting."
    $identities += $identity
    $bound = Resolve-Agent5DeveloperIdentity $name $developer -AssignmentDeveloper $developer
    Assert-True ($bound.developer -ceq $developer) "A matching assignment must retain the configured worker identity."
    $other = if ($developer -ceq "developer-1") { "developer-2" } else { "developer-1" }
    Assert-Fails { Resolve-Agent5DeveloperIdentity $name $developer -AssignmentDeveloper $other } "*assignment identity mismatch*"
    Assert-Fails { Resolve-Agent5DeveloperIdentity $name $developer -AssignmentDeveloper "" } "*assignment identity mismatch*"
    Assert-Fails { Resolve-Agent5DeveloperIdentity $name $other } "*does not match*"
    Assert-Fails { Resolve-Agent5DeveloperIdentity -DisplayName $name } "*both required*"
    Assert-Fails { Resolve-Agent5DeveloperIdentity -Developer $developer } "*both required*"
}
Assert-True (($identities.developer -join ",") -ceq "developer-1,developer-2") "UI prompts must keep distinct routing identities."
Assert-Fails { & $script } "*both required*"
Assert-Fails { Resolve-Agent5DeveloperIdentity " " "developer-1" } "*both required*"
Assert-Fails { Resolve-Agent5DeveloperIdentity $identities[0].displayName "developer-3" } "*unsupported coordination identity*"
Assert-Fails { Resolve-Agent5DeveloperIdentity $identities[0].displayName "Developer-1" } "*unsupported coordination identity*"
Assert-Fails { Resolve-Agent5DeveloperIdentity "Developer 1" "developer-1" } "*does not match*"
Assert-Fails { Resolve-Agent5DeveloperIdentity ($identities[0].displayName + " ") "developer-1" } "*does not match*"

$profiles = @(Get-ChildItem -LiteralPath (Join-Path $repository ".github\agents") -Filter "automation-5*developer*.agent.md")
Assert-True ($profiles.Count -eq 1) "Both workers must share a single loop5 Developer definition, without identity wrappers."
$profile = Get-Content -LiteralPath $profiles[0].FullName -Raw
Assert-True ($profile -match '(?m)^name: Developer\r?$' -and
    $profile.Contains("docs/agentic-loop-5/README.md") -and
    $profile.Contains("Resolve-Agent5DeveloperIdentity.ps1")) "The shared profile must load loop5 setup and validate explicit UI identity."
Assert-True ($profile -notmatch 'Your identity is|4️⃣ Developer|5️⃣Developer[12]') "The shared profile must not select a default worker."
$contract = Get-Content -LiteralPath (Join-Path $repository "docs\agentic-loop-5\developer.md") -Raw
Assert-True ($contract.Contains("../agentic-loop-4/developer.md") -and
    $contract.Contains("../agentic-loop-4/protocol.md")) "Both workers must reuse the existing behavior rather than duplicate it."
Assert-True ($contract.Contains("Do not accept loop4 offers/starts") -and
    $setup.Contains("All of that live verification remains **pending**")) "Source validation must not imply live adoption or cross-loop authority."

Write-Host "Agent5 shared Developer source and identity checks passed."
