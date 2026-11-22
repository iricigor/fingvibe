# About FingVibe

Open **Settings > About FingVibe & updates**, or the **About FingVibe** card on
Overview, to identify the application you are running and
find its source. The page shows the version, build kind, build timestamp, and
commit, with links to the pull request and build run when those identifiers
are available. Repository and creator links open in your browser. Settings stays
selected; **Back to Settings** returns focus to the About row without resetting
your preference sections. Official stable builds check for newer stable releases
automatically while open, and offer **Check for updates**. On an unmetered
connection, verified installed copies may silently download and stage the
confirmed Setup in the background; metered or unknown-cost connections do not.
**Update now** still requires confirmation. Choose **Restart now** to reuse or
download and revalidate the Setup, close FingVibe, run Setup and reopen after
success, or choose **When I close** to keep the verified update for the next
completed normal close. The postponed version and its verified installer record
survive restarts; cancelling restores the ordinary available-update state.
About keeps a compact
status summary and reports the result after reopening. An available update's notes
appear in a collapsed **What's new** expander as plain text, with a link to the full
notes on GitHub. Portable copies use manual ZIP
replacement. PR, Test and
Development builds do not check for updates or compare their versions with
stable releases. See [update checks and downloads](manual/navigation.md#check-for-updates)
and [installation and updates](manual/install.md).

<a href="screenshots/manual/about.png"><img src="screenshots/manual/about.png" alt="November 20 FingVibe About capture with Connected home icon, test identity and non-release update explanation" width="960"></a>

November 20 native UI-review capture with the actual Test build's Updates state;
it predates the current fixed header and shaded section headings.
Not an official released executable or private LAN.
Build identifiers belong to the captured application and will differ in your
installation. [Capture provenance and reproduction](manual/screenshots.md).

## When reporting a problem

Include the version and build identity from this page so the report can be
matched to the right source revision. A PR/test build is not an official
release; its diagonal test-build ribbon is intentional. Missing timestamp or
commit metadata is shown as unavailable rather than guessed.

See [Download builds](reference.md#download-builds) for release versus PR
artifacts, build timestamps, and where to obtain the Windows executable.
