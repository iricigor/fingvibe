# Archived appearance implementation

[Archive introduction](README.md) | [Complete gallery](gallery/README.md)

## Status and exact provenance

This is a repository-stored snapshot of an **unmerged experiment**, delivered
for [archive task #160](https://github.com/iricigor/fingvibe/issues/160).
It does not merge or close the original
[appearance PR #143](https://github.com/iricigor/fingvibe/pull/143), change
[task #142](https://github.com/iricigor/fingvibe/issues/142), delete the source
branch, approve unfinished design work, or publish a release.

| Property | Recorded value |
| --- | --- |
| Source branch | `iricigor-solid-chainsaw` |
| Source commit | `deae2a19c2cc8218183f08b777347215b7fa31e6` |
| Source tree | `9e9c62aac115cb657775e7fe93dc1aabd93deb4b` |
| Archive date (UTC) | 2026-11-04 |
| Source ZIP | [fingvibe-source-deae2a19c2cc8218183f08b777347215b7fa31e6.zip](fingvibe-source-deae2a19c2cc8218183f08b777347215b7fa31e6.zip) |
| ZIP SHA-256 | `fcd5df9c7fe7b6b2fd3fca7e53dface25fea9338368e55d6f29b18488d2848b2` |
| ZIP size | 1,071,390 bytes (1.022 MiB) |
| Tracked files | 237; paths and Git blob IDs in [source manifest](evidence/source-manifest.json) |

The branch tip was explicitly checked against this agreed commit before
archiving. Neither a later branch tip nor `main` was substituted. Creation:

```powershell
git -c core.autocrlf=false archive --format=zip `
  --output=fingvibe-source-deae2a19c2cc8218183f08b777347215b7fa31e6.zip `
  deae2a19c2cc8218183f08b777347215b7fa31e6
```

Disabling Windows line-ending conversion is intentional: verification compares
every decompressed file to its exact tracked Git blob, not a working-tree copy.
The ZIP comment also identifies the full commit. There is no `.git` directory,
untracked/local settings, `bin`, `obj`, downloaded NuGet cache, or `node_modules`.
Existing tracked documentation images and the attributed speed-test JavaScript
remain part of the original source tree; no new dependencies are vendored.

## Contents

- The revision-named source ZIP, independent of source-branch survival.
- Exactly 25 local PNGs under `screenshots`: the 24 approved appearance/page
  combinations plus one Settings image with all four dropdowns visible.
- This technical document, the [short introduction](README.md), and the
  [three-column gallery](gallery/README.md). Preview/gallery links reuse the
  same PNGs; there are no duplicate image assets.
- `evidence`: exact-source manifest, per-image capture provenance/checksums,
  archived capture script, standard-library verifier, and CI validation records.

**A source ZIP is not Git history or an offline build/dependency cache.**
It includes the tracked tree at one revision, not commits, branches, PR
discussions, downloaded SDKs, NuGet packages, or published binaries.

## Verify and extract

From this archive directory:

```powershell
$zip = ".\fingvibe-source-deae2a19c2cc8218183f08b777347215b7fa31e6.zip"
$expected = "fcd5df9c7fe7b6b2fd3fca7e53dface25fea9338368e55d6f29b18488d2848b2"
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw "Source ZIP checksum mismatch."
}
Expand-Archive -LiteralPath $zip -DestinationPath .\extracted-source
```

No clone or surviving experimental branch is needed for extraction or a build.
With Python 3 installed, `python .\evidence\verify.py` additionally checks the
ZIP comment, every tracked blob, the screenshot matrix/checksums/dimensions,
the fixture hash, local document links, and preview/gallery image reuse.
`--source-only` omits screenshot/document checks.

## Build and run the extracted source

Prerequisites:

- Windows 11 x64 for normal use; native WinUI is not a cross-platform UI.
- .NET 8 SDK. The archived `global.json` requests 8.0.100 with `latestFeature`
  roll-forward within .NET 8.
- Visual Studio 2022 with Windows application development / WinUI build tools,
  or equivalent MSBuild, Windows SDK, and XAML compiler prerequisites.
  Run the commands in a Visual Studio Developer PowerShell.
- Internet access for the first NuGet restore. The app directly references
  `Microsoft.WindowsAppSDK` 1.8.260921001 and
  `Microsoft.Windows.SDK.BuildTools` 10.0.26100.9169, targeting
  `net8.0-windows10.0.19041.0`; core/tests have their own archived project
  dependencies. No Logo.dev key is required.

```powershell
Set-Location .\extracted-source
$publish = Join-Path $PWD "artifacts\appearance-app\"
msbuild .\src\FingVibe.App\FingVibe.App.csproj /restore /target:Publish `
  /property:Configuration=Release /property:Platform=x64 `
  /property:RuntimeIdentifier=win-x64 /property:SelfContained=true `
  /property:BuildKind=Development `
  /property:BuildCommit=deae2a19c2cc8218183f08b777347215b7fa31e6 `
  "/property:PublishDir=$publish"
if ($LASTEXITCODE -ne 0) { throw "Archived app build failed." }
& (Join-Path $publish "FingVibe.App.exe")
```

Normal launches use the current user's local FingVibe preferences/inventory and
may access the network. For synthetic review mode, set `FINGVIBE_UI_REVIEW=1`
and `FINGVIBE_UI_REVIEW_SNAPSHOT` to the extracted
`docs\screenshots\devices-fixture.json` **before** launching. Review mode
supplies a loopback interface and example public identity, avoids real
inventory/appearance persistence, and suppresses ISP logo requests.
The capture script performs desktop automation and deliberately refuses to run
outside disposable GitHub-hosted CI; do not run it on a working desktop.

## Four settings and their interactions

| Setting | Choices and behavior |
| --- | --- |
| Mode | Light / Dark. Chooses the brightness family independently of surface style and backdrop. |
| Theme | Standard; Warm in Light / True Black (OLED) in Dark; Colored; Vivid. Switching modes retains the family, mapping Warm to/from OLED. Colored retains the pre-existing `ColorfulLight` / `ColorfulDark` persisted values; Vivid is a separate, more saturated palette. |
| Visual style | Standard / Glass / Clay / Neumorphic. Shapes shared surfaces without redesigning page layout. Standard restores the original native treatment. |
| Window backdrop | Solid / Mica / Mica Alt / Acrylic. Independent and persisted. **Entering Glass selects Mica Alt once**; the picker remains enabled, subsequent overrides persist, and loading saved settings or switching mode/theme does not reset them. Re-entering Glass selects Mica Alt again. |

There are 128 selectable combinations: 2 modes x 4 theme families x 4 styles x
4 backdrops. This archive captures only the approved **Standard / Colored**
families, not Vivid or Warm/OLED. Each family has Light and Dark captures of
Overview (the start page) and Devices.

Choices preview immediately and normally persist atomically to
`%LOCALAPPDATA%\FingVibe\appearance.json`; UI-review mode does not save them.
Existing appearance values remain compatible; a missing style defaults to
Standard. Settings uses four, two, or one selector columns as space decreases.
High contrast uses system colors instead of decorative surfaces. Disabled
Windows transparency or unsupported materials yield explicit opaque fallbacks
while retaining the selected preferences.

## Implemented surfaces and ownership

The archived `MainWindow.Appearance.cs` applies palettes, native backdrop
selection, material/fallback status, and Glass's color underlay. The page-owned
`Views\SettingsPageView.xaml(.cs)` owns the four selectors and responsive layout.
Core owns the appearance record/enums and persistence; it does not depend on
WinUI. `AppearancePalette.cs` supplies color/surface values, and
`SurfaceTreatment.cs` applies attached card/control treatments while restoring
original values for Standard and honoring high contrast.

- **Glass:** palette-aware card/control fills with alpha 160 (about 63% opacity),
  1-DIP white-alpha specular borders (alpha 77), 20-DIP card and 10-DIP control
  radii, and soft card `ThemeShadow` elevation. The selected native backdrop and
  a noninteractive violet/cyan/peach radial underlay provide variation beneath
  translucent surfaces. Header/sidebar alpha and a pane edge are coordinated;
  underlay decoration is hidden when effects/backdrops are unavailable.
- **Clay:** 32-DIP major-card and 24-DIP control radii, three-stop diagonal fills,
  a 3-DIP top-left highlight bevel, and native `ThemeShadow` elevation (40 for
  cards, 12 for controls). Dark surfaces blend toward a richer blue tone before
  highlights/shading. These are native shading treatments, not CSS.
- **Neumorphic, as actually implemented:** page-palette-relative diagonal
  gradients and opposing light/dark 3-DIP strokes, 18-DIP raised cards with
  elevation 12, and 10-DIP inset-looking controls with no elevation.
  These gradients/strokes are **not** the later requested uniform-base,
  stronger paired-shadow, truly debossed-input design.

Controls with explicit local fills/strokes can preserve them rather than
receiving all shared surface overrides. Native focus, selection, semantic
status colors, and page composition remain owned by their existing controls.

## Screenshot and validation evidence

The [gallery](gallery/README.md) is the complete image collection; it is not
duplicated here. Every image records exact mode/theme/style/backdrop, page,
SHA-256, viewport, UTC time, and the application's material status in the
[capture manifest](evidence/capture-manifest.json).

Capture uses the **unmodified extracted source**, rebuilt without `.git`, rather
than a current-main binary or a presumed artifact revision. Only assembly build
identity properties are supplied. The archived eight-device fixture is reused
byte-for-byte: documentation-only `192.0.2.0/24` addresses, sample vendors and
device names, with no live LAN scan. It is a historical saved scan; the review
interface remains loopback, so saved-scan/selected-target context is expected.
All images use one 1600x960 physical-pixel window on a disposable 1920x1080 CI
desktop. Glass requests Mica Alt; Clay and Neumorphic use Solid. The manifest
records actual OS/DPI/transparency/high-contrast state and distinguishes an
application-reported material from an unavailable/disabled fallback. It does
not claim pixel-level proof of an OS-managed native material.

The capture driver is [Capture.ps1](evidence/Capture.ps1). A temporary dispatch
hook in the existing CI workflow runs it; that hook is removed from the final
archive PR so production workflows and application code are unchanged.
Existing capture helpers are loaded from the ZIP, not replaced with main's
versions. Per-image provenance is required; older CI images were not substituted.

Final extracted-source results, capture run, material observations, and sizes
are recorded in the accompanying validation record before review.

The original source revision also passed
[CI run 41706787803](https://github.com/iricigor/fingvibe/actions/runs/41706787803)
on 2026-11-03: core/script checks, Windows publish, installer lifecycle, and
native UI capture. This includes the experimental branch's existing 128-setting
combination coverage. That earlier evidence is distinct from this archive's
new full 25-image matrix.

## Known limitations and unfinished work

This snapshot is an experiment, not a declaration that all styles meet a final
visual/accessibility rubric. The archive does not add styling fixes. Native
Mica/Acrylic/ThemeShadow rendering depends on OS support, transparency,
composition, focus, and high contrast; a requested backdrop alone is not proof
that its intended optical effect appeared.

The latest requested **Neumorphic uniform-base / stronger paired-shadow /
debossed-input refinement was not implemented**. The unresolved design question
was whether Neumorphic OLED may use a uniformly lifted dark base so a darker
shadow remains visible. This archive neither answers that question nor claims
the refinement was delivered. The existing gradient/stroke implementation is
preserved faithfully.

NuGet restore still needs external packages and currently available feeds.
There is no lock/cache guarantee or promise of bit-for-bit rebuilt binaries:
SDK versions, restore resolution, OS rendering, and build timestamps can differ.
Git commit/blob identifiers establish the recorded tree; the separately
recorded SHA-256 verifies ZIP/image bytes, not an external signature.

Archive files become part of `main` only after the archive PR is reviewed and
merged normally. Until then they are durable on the published archive branch,
not delivered to `main`. Neither the archive nor a successful capture authorizes
merging the experimental PR.

## Resume development

Verify and extract the ZIP, read the included `CONTRIBUTING.md` and original
`docs\reference.md`, and build it with the prerequisites above. If you need a
fresh history-independent starting point, initialize a new Git repository in
the extracted directory and commit that verified tree. To recover the actual
history, use the preserved original branch/commit instead; the ZIP cannot
reconstruct it.

Before resuming appearance work, reconcile current-main interfaces, concurrent
changes, and the original task/PR discussion. Resolve the outstanding Neumorphic
OLED-base question with the user before implementing that refinement. New work
requires its own authorization; this archive is preservation, not an implicit
request to restart or ship the experiment.
