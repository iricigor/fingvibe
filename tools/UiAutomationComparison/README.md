# Local UI automation comparison

This is an opt-in experiment, not a second production regression suite or a CI
gate. It contains a completed PowerShell/managed UI Automation versus
C#/FlaUI.UIA3 5.0.0 history comparison and an unfinished full-suite prototype.

**Parked on 2026-11-10 at the user's request.** The source is preserved on
`iricigor-improved-disco`; [PR #312](https://github.com/iricigor/fingvibe/pull/312)
is closed without merging, with the branch retained for later resumption.
The full-suite prototype has not completed a successful scenario or full run.
This checkpoint is not a framework migration or a completed validation.

The repository normally prohibits native automation on a working desktop.
The user explicitly authorized a one-off exception for this experiment in
[#311](https://github.com/iricigor/fingvibe/issues/311). The switch below asserts
that explicit permission exists; it does not grant permission for other runs.
Prefer a disposable desktop. Do not set CI environment variables to bypass the
existing suites' disposable-host guards.

## Completed history comparison protocol

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

## Running the history comparison

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
The work area must fit the complete test window. The history comparison does not
change display resolution or system high contrast and does not request real LAN
scans. The separate full-suite prototype can temporarily change high contrast.

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

## Parked full-suite prototype

The approved expansion preserves existing scenarios and assertions instead of
rewriting them while changing backends. Its implementation is saved, not
accepted as working end-to-end:

- `..\UiAutomationComparison.Backend` contains a typed FlaUI/UIA3 compatibility
  facade for .NET 8 and .NET Framework 4.8, plus a direct capture-transport
  adapter. It implements the suite's API subset, not all managed UI Automation
  or WebDriver behavior.
- `Prepare-Suite.ps1` generates isolated baseline/FlaUI source copies outside
  the repository. Logged AST edits change automation types, add an explicit
  local-consent alternative to host guards, and replace the FlaUI capture
  transport. It checks that explicit `throw` statements are unchanged; that is
  a guard against assertion loss, not proof of complete behavioral parity.
- `Invoke-FullComparison.ps1`, `Invoke-SuiteCase.ps1` and `Desktop.ps1` provide
  sequential execution, alternating backend order, fresh child hosts, guarded
  activation, per-case results, a watchdog and process-specific cleanup.
  Sidebar retains Windows PowerShell 5.1; other cases use PowerShell 7.
- The 14 entry points are Sidebar, Devices, Details Summary, Discovery, Usage
  Category, Details History, Activity, Build Identity, Troubleshooting, Fing
  Import, Additional Services, SQL Editor, screenshot contract and full capture.
  Independent entry points can continue after another case fails; assertions
  after a failure within one stateful case remain unreached.

The facade built for both targets and loaded in both PowerShell hosts.
Preparation processed 79 scripts per backend while preserving 931 explicit
failure statements. Three diagnostic runs attempted only Build Identity and
capture, not the complete catalog. All 12 attempts failed before establishing a
successful scenario; they are not backend reliability or speed measurements.

| Diagnostic run | Retained result |
| --- | --- |
| `full-pilot-01` | Build Identity hit a runner JSON timestamp conversion bug; FlaUI capture stopped at the activation guard; original capture lacked WinAppDriver. |
| `full-pilot-02` | After the timestamp fix, both Build Identity paths and FlaUI capture stopped at activation; original capture still lacked WinAppDriver. |
| `full-pilot-03` | Activation was blocked by the foreground window, subsequently identified as Windows `LockApp`; extracted WinAppDriver reported that Developer Mode was disabled. |

### Blockers and remaining work

Windows was locked during the expanded desktop diagnostics. The ownership check
refused to click another window; the saved runner now also checks for
`LockApp`/`LogonUI` before launching cases. Clipboard reads separately failed with
`0x800401D0`; Additional Services must not run its copy-button checks unless the
clipboard can first be preserved and subsequently restored.

The signed official WinAppDriver 1.2.1 MSI was extracted into session artifacts
without installation. Its server exited because Developer Mode was disabled.
No Windows setting was changed. Original capture therefore needs a separately
approved suitable host/prerequisite change; FlaUI capture does not need that
server. Merely extracting the driver does not resolve this blocker.

The latest activation, host-scope and locked-desktop safeguards have not passed
an end-to-end scenario. Remaining work includes small parity pilots in both
hosts, abnormal-worker/watchdog cleanup validation, capture-adapter parity,
complete first-attempt catalog execution, reached-coverage reporting and the
separate test-quality audit. Do not infer completion from the existing 30-pair
history result or from the facade compiling.

### Resumption

Resume only after explicit human authorization, the normal ownership/conflict
checks and a fresh desktop permission decision. Reuse this branch and reopen
PR #312 rather than merging or starting duplicate work. Issue #311 remains
open, blocked, human-led and unclaimed; parking does not deliver its unfinished
acceptance criteria or make it eligible for unattended pickup.

Preserve frozen revision `6fd07fd04ffc7a3e919eaa7916f2487f2b59a870`. Build
`tools\UiAutomationComparison.Backend\UiAutomationComparison.Backend.csproj`
before exercising `Invoke-FullComparison.ps1`; first use explicit `-Cases`
subsets and new evidence directories on an authorized unlocked desktop.
The runner accepts the same frozen published `-AppPath`,
`-BackendBuildDirectory`, `-OutputDirectory`, `-AllowDesktopInput`, optional
`-Backends`, and an optional portable `-WinAppDriverPath`. It must not be run
automatically as part of recovering this parked checkpoint.

Machine-specific payloads, generated source copies, downloaded dependencies and
raw diagnostic logs are not committed. They remain under
`C:\Users\irici\.copilot\session-state\9eec7dd4-501e-4802-adb0-dc6b3f3187bc\files`,
including `ui-comparison-payload`, `ui-comparison-30-final`,
`full-prepare-check-baseline`, `full-prepare-check-flaui`, `full-pilot-01`,
`full-pilot-02`, `full-pilot-03` and `winappdriver-portable`.
The portable initial measurements remain in the committed CSV above.
All diagnostic cases restored high-contrast flags to the original value `126`;
no comparison app, worker or driver remained at the parking check.

## Scope boundary

Production tests, CI gates, application code and competing feature branches are
unchanged. The full-suite expansion was explicitly approved, but is unfinished
and parked. This is not a completed FlaUI port or an audit verdict on every
existing test. Redesigning tests, enabling dormant coverage, changing desktop
policy or resuming implementation requires separately agreed authorization.
