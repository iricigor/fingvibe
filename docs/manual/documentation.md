# Maintain this documentation

The website is built with **MkDocs 1.6.1** and **Material 9.6.22**.
Markdown in `docs/index.md` and `docs/manual/` is its single authored source.
Images live under `docs/screenshots/manual/`; the logo is an existing branding asset.
One small theme partial keeps the source link static instead of fetching GitHub
repository statistics. Fonts and search assets are served locally.

Existing technical references, archived designs, agent prompts, and backlog
contracts remain in the repository. They are deliberately not website chapters.
Links to them open their GitHub source.

## Build locally

Use Python 3.12 and run these commands from the repository root.
A virtual environment keeps documentation dependencies separate:

```powershell
python -m venv .venv-docs
.\.venv-docs\Scripts\python.exe -m pip install -r tools\requirements-docs.txt
.\.venv-docs\Scripts\python.exe tests\Documentation.Tests.py
.\.venv-docs\Scripts\python.exe -m mkdocs build --strict
.\.venv-docs\Scripts\python.exe tools\Check-Documentation.py site
```

The generated output is `site/`, which is ignored by Git.
Do not commit it. For a local preview:

```powershell
.\.venv-docs\Scripts\python.exe -m mkdocs serve
```

Open the local URL printed by MkDocs. Stop the server when finished.
The website is separate from the native WinUI application.

## Publishing

The **Documentation** workflow builds changed documentation on pull requests.
It checks links, fragments, assets, image alternative text, decorative icon
accessibility, and search output before uploading a Pages artifact.
Pull requests and feature-branch manual runs do **not** deploy.

After a matching push to **main**, the deployment job publishes the checked
artifact to [GitHub Pages](https://iricigor.github.io/fingvibe/).
A manual workflow run on main can republish it without changing app releases.
The deployment has only Pages and OIDC permissions, not repository write access.

The repository previously published from the `gh-pages` branch.
This workflow uses **Settings > Pages > Source: GitHub Actions** instead.
The `github-pages` environment must allow the main branch.
These are deployment settings, not changes to application release policy or
branch protection. The old branch can remain for provenance.

A successful PR build is not proof that the live site was deployed.
After merge, check the deployment result and the real `/fingvibe/` project URL.
Verify search, links, and images there.

## Writing rules

Use short sentences and familiar words for non-native speakers.
Explain a technical term when it first appears.
Use exact UI labels and one action per numbered step.
Describe the expected result and keep warnings beside risky actions.

Keep detailed implementation/test internals in contributor or technical records.
Avoid idioms, decorative jargon, and claims of continuous presence.
When behavior changes, update related pages together and update the homepage's
release baseline after verification.

## Images and icons

Reuse meaningful app imagery where possible. Keep text beside icons and provide
descriptive alternative text for screenshots. Decorative SVGs should be hidden
from assistive technology, not announced repeatedly.

Use privacy-safe native screenshots, never an unredacted real inventory.
Record source revision, run, test identity, dimensions, edits, and visible state
in [Screenshot sources](screenshots.md). Do not imply that a ready-state capture
shows real measured results.

Do not obtain fresh screenshots by automating a working user's desktop.
Use existing disposable Windows CI capture tooling.

## Related work

[#253](https://github.com/iricigor/fingvibe/issues/253) owns the separate
documentation refresh/audit-agent request. This site adds no agent or schedule.
Shared technical/contributor documentation and Activity restoration can evolve
independently; reconcile their released behavior before changing user instructions.
