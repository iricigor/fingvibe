# Local UI automation comparison

This is an opt-in experiment, not a second production regression suite or a CI
gate. It compares PowerShell/managed UI Automation with C#/FlaUI.UIA3 5.0.0 for
one two-scan history-list reachability scenario.

The repository normally prohibits native automation on a working desktop.
The user explicitly authorized a one-off exception for this experiment in
[#311](https://github.com/iricigor/fingvibe/issues/311). The switch below asserts
that explicit permission exists; it does not grant permission for other runs.
Prefer a disposable desktop. Do not set CI environment variables to bypass the
existing suites' disposable-host guards.

## Protocol

- Both backends use the same published application, isolated synthetic data,
  1280x900 physical-pixel window, local timezone, and screenshot helper.
- Each trial starts and normally closes its own app. Thirty pairs alternate
  their order: baseline/FlaUI, then FlaUI/baseline. There are no trial retries.
- The fixture is the normal-device, two-scan case extracted from the history
  regression. It deliberately omits other devices, virtual-device aggregation,
  decoy scopes, summary assertions, paging, appearance matrices and error paths.
  It is not the full original fixture or suite.
- The baseline imports eight original history functions by parsing their
  definitions, without editing them or executing the suite's top-level code.
  Source hashes and application-source equality are checked against the frozen
  revision. Binary hashes identify the common payload.
- The FlaUI implementation follows the same navigation, fixed delays, scroll
  positions (0/50/100), bounds checks, three text columns, timestamps, accessible
  names, presence state, ordering and complete two-row reachability assertions.
  It intentionally preserves the baseline test design for this comparison.
- Positioning uses focus/ScrollItem and verifies complete viewport containment.
  The baseline's nonfocusable geometry fallback is not ported. An unexpected
  need for it fails explicitly rather than weakening the assertion.
- Shared setup activates the app with a guarded title-bar click. The click is
  sent only when its point belongs to the test app. Temporary topmost state is
  removed before testing. Original pointer/focus are restored afterward.
  A shared setup or cleanup failure stops subsequent pairs.
- Failed checks remain failures, with per-trial JSON, screenshot/tree diagnostics
  where available, and a nonzero runner exit. Partial evidence is retained.
  Test fixtures remain with the evidence; real inventory is not used.

## Running

Use an unchanged application-source snapshot matching `SourceRevision`; the
default is `6fd07fd04ffc7a3e919eaa7916f2487f2b59a870`. Build the app from that
snapshot. The script checks sources and records binary hashes, but cannot prove
the provenance of an arbitrary supplied binary.

From the repository root in PowerShell 7, after obtaining desktop permission:

```powershell
$root = Join-Path $env:TEMP ('fingvibe-uia-comparison-' + [Guid]::NewGuid())
dotnet publish src\FingVibe.App\FingVibe.App.csproj `
    -c Release -r win-x64 --self-contained true -p:Platform=x64 -o "$root\app"
dotnet build tools\UiAutomationComparison\UiAutomationComparison.csproj `
    -c Release -o "$root\worker"
.\tools\UiAutomationComparison\Invoke-Comparison.ps1 `
    -AppPath "$root\app\FingVibe.App.exe" `
    -FlaUiPath "$root\worker\UiAutomationComparison.exe" `
    -OutputDirectory "$root\evidence" -AllowDesktopInput -Pairs 30
```

The output directory must be new. Leave the desktop untouched during execution.
The work area must fit the complete test window. This experiment does not change
display resolution or system high contrast and does not request real LAN scans.

## Measured result: 2026-11-10

Frozen application/test revision:
`6fd07fd04ffc7a3e919eaa7916f2487f2b59a870`.
Windows build 26340, PowerShell 7.6.9, 96 DPI, 1920x994 monitor work area.
All 60 final captures were verified as 1280x900, alternating order was verified,
and no comparison app/worker processes remained.

| Metric | PowerShell/UIA | FlaUI/UIA3 |
| --- | ---: | ---: |
| First-attempt passed / attempted | 30 / 30 | 30 / 30 |
| Total median | 5.299 s | 5.929 s |
| Total p95 | 5.570 s | 6.070 s |
| Driver median | 3.100 s | 3.781 s |
| Navigation median | 2.077 s | 2.160 s |
| Reachability assertion + capture median | 0.998 s | 1.065 s |
| Reachability assertion + capture p95 | 1.276 s | 1.110 s |

Individual measurements in execution order are in
[results-2026-11-10.csv](results-2026-11-10.csv). Median averages the middle two
values; p95 is the nearest-rank 95th percentile.

**Interpretation:** This prototype did not demonstrate a speed or reliability
advantage for FlaUI. Both passed this small local scenario, and the reported CI
history failure was not reproduced. Thirty successful trials cannot establish
reliability for rare failures, a full suite, another display, or CI.

**Timing limitation:** PowerShell reuses the already-loaded driver in the
orchestrator, while FlaUI starts a new worker per trial. Total includes common
launch/activation, scenario, capture and shutdown; driver includes worker startup.
FlaUI's in-worker timers exclude that startup, with the common screenshot cost
added to its assertion duration. This is a comparison of these implementations,
not proof that the FlaUI engine itself is slower. A persistent xUnit runner would
have a different lifecycle and would require a separate measurement.

### Setup failures retained separately

The initial diagnostic pair passed, but its capture costs were not yet equal.
An initial 30-pair batch then had 60 foreground-acquisition failures before
either backend entered the scenario. An attempted UIA root-focus setup also
failed in both paths. Neither set is a history-assertion or backend failure-rate
measurement, and none of those timings is included in the table.

After replacing the shared activation step with the guarded real title-bar
click, a fresh diagnostic pair passed with equal capture costs, followed by the
60-trial final batch. These were protocol repairs and separate runs, not hidden
retries of individual failing checks. Per-run evidence remains in the session
artifacts (`ui-pilot-01`, `ui-comparison-30`, `ui-pilot-02`, `ui-pilot-03`,
`ui-comparison-30-final`).

Common payload SHA-256:

- App executable: `F2362DB6E64DD63AB498B954F9F10EAB6BE2FD98DA7BD2EE742E13D765C35D77`
- App assembly: `6C9BD69B118F946D2C17D39982BC4B4E7540E1F7CF21637CAA62D7B06DA48D4B`
- Core assembly: `9C43FB7C502853D17BC8A3A35121EBEDB2F6DFECB6EF1E1A12F538FEF4F58FD6`
- FlaUI worker: `4182995404CE9B1B72CCA432F4EE4C2F8B841F551B8BD83B6F03BB8C4B4A24C2`

## Scope boundary

Production tests, CI gates, application code and competing feature branches are
unchanged. This is not a full FlaUI port or an audit verdict on every existing
test. Redesigning tests, expanding coverage, enabling dormant coverage or changing
desktop policy requires separately agreed scope.
