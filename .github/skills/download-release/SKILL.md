---
name: download-release
description: >-
  Download this repository's Windows release executable and,
  when explicitly requested, unblock and launch it locally.
---

# Download a FingVibe release

Use this skill when the user asks to download, run, or install this repository's
published Windows release. Use GitHub CLI, not a browser or arbitrary download URL.

## Execution and consent

- Execute only on the user's **local Windows machine**. Windows alone is not
  proof of locality: cloud agents, Codespaces, CI runners, remote/SSH sessions,
  and other remote execution hosts must provide the local PowerShell command
  instead. Do not download or launch on those hosts, even if they run Windows.
  If locality is unclear, ask before executing. The script rejects known
  CI/cloud/remote-session indicators; that guard cannot identify every host.
- Require `gh` and existing GitHub access to `iricigor/fingvibe`. Report missing
  tools, authentication/access failures, release/asset problems, and download
  failures. Do not install tools or initiate authentication as part of this skill.
- Download-only is the default. **`-Run` explicitly authorizes unblocking and
  launching the downloaded EXE.** Use it only when the user explicitly asks to
  run/install the release. A download request, prior consent on another download,
  or missing consent does not authorize either action; ask before either action.

## Release and asset selection

The Git remote confirms `iricigor/fingvibe`. The release workflow at
`..\..\workflows\release.yml` publishes a Windows **x64**, unsigned per-user
Inno Setup installer named `FingVibe-<version>-win-x64-Setup.exe`, alongside a
portable ZIP. The ZIP is not an EXE; launching the Setup EXE starts the installer,
not the installed application.

The inspected stable release is
[v1.2.141](https://github.com/iricigor/fingvibe/releases/tag/v1.2.141), with
`FingVibe-1.2.141-win-x64-Setup.exe`. This is an example, not a permanent latest
version. Query release metadata on each request:

```powershell
gh release view --repo iricigor/fingvibe --json tagName,url,assets,isDraft,isPrerelease
```

Omitting `-Tag` selects GitHub's latest published, non-prerelease release.
An explicit `-Tag` may select a published prerelease; drafts are always rejected.
For metadata of an explicit tag, append `-- '<tag>'` to the command above.
Never infer architecture from the host or invent an asset name. If multiple
EXEs or architectures are available, list their exact names and ask which one
the user wants; pass that exact name with `-AssetName`. The script fails without
downloading if selection is ambiguous. If only x64 is offered, do not claim a
native ARM64 or x86 build exists.

## Download, report, and optional run

Invoke `scripts\download-release.ps1` from this skill directory, or use its
absolute path in the local checkout when handing a command to the user.
The script pins the repository, creates a fresh GUID-named directory under
`$HOME\Downloads` (or `-DownloadRoot`), and downloads exactly one EXE via
`gh release download`. The root must be a local drive path outside the checkout;
symlink/junction ancestors are rejected to avoid redirected destinations. Existing downloads
are never overwritten. Failed/partial downloads remain for diagnosis and are
never launched.

Report the release URL, tag, exact local file path, and SHA-256 from script
output. **The computed hash is informational, not verification against a
trusted hash**, proof of signing, or malware detection.

Before using `-Run`, inspect the selected release and current release workflow
for published checksums or attestations and reuse the repository's established
verification process if one exists. Verification must succeed before unblocking
or launching. At the inspected revision the application release publishes only
Setup EXE and ZIP, with no checksum manifest, attestations, or established
application-release verifier. GitHub's asset digest is not an independently
trusted checksum; the Gitleaks checksum process verifies a different tool, not
FingVibe. If new verification material appears and its established process cannot
be completed, stop and explain the blocker rather than run.

`-Run` uses `Unblock-File -LiteralPath` on **only the downloaded EXE**, then
`Start-Process` with its download directory as the working directory. It does
not recursively unblock anything or change browser, Defender, SmartScreen, UAC,
execution policy, or signing settings. Signing checks, malware detection, and
launch-time warnings are **not bypassed**; handle any Windows prompts normally.
A successful launch request is not proof that installation completed.

### Download-only example (confirmed asset)

```powershell
& '.\.github\skills\download-release\scripts\download-release.ps1' -Repo 'iricigor/fingvibe' -Tag 'v1.2.141' -AssetName 'FingVibe-1.2.141-win-x64-Setup.exe'
```

### Explicitly authorized run/install example

Only after the user explicitly asks to run/install:

```powershell
& '.\.github\skills\download-release\scripts\download-release.ps1' -Repo 'iricigor/fingvibe' -Tag 'v1.2.141' -AssetName 'FingVibe-1.2.141-win-x64-Setup.exe' -Run
```

For the latest stable release, omit `-Tag` and `-AssetName`; the script selects
only when exactly one EXE exists. Tests use mocked CLI and process commands:
`pwsh -File .\tests\DownloadRelease.Tests.ps1`. Never run a real downloaded EXE
while implementing or testing this skill.
