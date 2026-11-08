# Build and contribute

This is the smaller contributor section. App users can start with
[Install and update](install.md) instead.

## Build prerequisites

Use Windows 11, the .NET 8 SDK, and Visual Studio 2022 with the
**Windows application development** workload or equivalent Windows SDK tools.
The desktop UI is native WinUI 3.

From the repository root:

```powershell
dotnet restore FingVibe.sln
dotnet run --project src\FingVibe.App\FingVibe.App.csproj -p:Platform=x64
```

Official app downloads are self-contained; these prerequisites are for source
builds. The optional speed-test host uses WebView2, not a web-based app shell.

## Component boundaries

| Component | Responsibility |
| --- | --- |
| Application shell | Initialization, routing, shared header, and top-level wiring. |
| Page views | Visual trees, local layout/state, and focused UI request events. |
| Scan execution/scheduling | Serialized network activity, manual/scheduled outcomes, timing, and lifecycle. |
| Scanner and enrichment | Probe orchestration and evidence for names, vendors, ports, and classification. |
| Core/storage | Models, evidence rules, transactional inventory, and bounded history queries. |

Keep page-specific behavior with its owning module.
Coordinate shared-contract changes before editing.
The complete ownership list and review expectations remain in
[CONTRIBUTING](https://github.com/iricigor/fingvibe/blob/main/CONTRIBUTING.md).

## Validate relevant behavior

For WinUI-free Core coverage:

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --configuration Release
```

Use the smallest relevant existing checks for a focused change.
Native UI coverage requires a disposable, usable Windows desktop.
Do not move the pointer, send keyboard input, or change accessibility settings
on the user's working desktop to run regression tests.

Current checks, capture mappings, build identity, and CI gates are recorded in
the [test reference](https://github.com/iricigor/fingvibe/blob/main/docs/reference.md#test).
Pending independent validation work is not described here as delivered.

## Submit a focused change

Read existing instructions and issue scope before changing code.
Keep unrelated formatting and cleanup out of feature PRs.
Update directly related documentation and regression coverage.

Issue intake, Epic organization, readiness, and agent ownership follow the
[development backlog contract](https://github.com/iricigor/fingvibe/blob/main/docs/development-backlog.md).
Labels and Epic membership are not implementation approval.

Build identifiers distinguish local, PR, test, and official release artifacts.
Merging to main can trigger existing release automation.
This documentation workflow does not change app builds, release gates,
branch protection, or merge authority.
