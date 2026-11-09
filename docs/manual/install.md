# Install and update

Choose the installer for a normal installation, or the ZIP for a portable copy.

## Before you start

FingVibe supports **Windows 11 on an x64 PC**. Official downloads include the
.NET components needed by the app. You do not need the .NET SDK or Visual
Studio unless you want to build FingVibe from source.

The optional speed test needs Microsoft Edge WebView2.
If it cannot start, see [Speed test problems](problems.md#the-speed-test-does-not-start).

## Install FingVibe

1. Open the [latest release](https://github.com/iricigor/fingvibe/releases/latest).
2. Download `FingVibe-<version>-win-x64-Setup.exe`.
3. Close any running copy of FingVibe.
4. Run the installer.
5. Open FingVibe from the Start menu.

The installer installs the app for your Windows user. It does not need
administrator rights. Its default app folder is
`%LOCALAPPDATA%\Programs\FingVibe`.

!!! warning "Unsigned download"
    FingVibe downloads are unsigned. Windows may show an unknown-publisher or
    SmartScreen warning. Check that the file came from the repository's
    official release page before deciding whether to run it. Do not disable
    Windows security or ignore a warning for an untrusted download.

After launch, follow [Your first scan](first-scan.md).

## Use the portable ZIP

1. Download `FingVibe-<version>-win-x64.zip` from the release page.
2. Extract the ZIP into a new folder.
3. Open that folder.
4. Run `FingVibe.App.exe`.

Keep **all extracted files together**. Do not run the executable from inside
the ZIP or copy only the executable to another folder.

"Portable" describes the app files. Your saved data still lives under your
Windows user profile, not beside the executable. Installed and portable copies
use the same [data folder](data.md) for that user.

## Update

FingVibe does not automatically install a new release.

1. Check the [release page](https://github.com/iricigor/fingvibe/releases/latest).
2. Make a [backup](data.md#make-a-backup) before an important update.
3. Close all running copies of FingVibe.
4. For an installed copy, run the newer installer.
5. For a portable copy, extract the new ZIP into a fresh folder.
6. Start the updated app.
7. Check **Tools > About FingVibe** for the expected version.

The app upgrades supported saved data when needed. The installer rejects
downgrades. Older app builds may not understand the current database; do not
use an old build as a way to undo a data upgrade.

## Remove the app

For an installed copy, open **Windows Settings > Apps > Installed apps**,
find **FingVibe**, and choose **Uninstall** after closing the app.

For a portable copy, close FingVibe and remove its extracted app folder.

Removing the application does not remove the separate saved-data folder.
To remove your data as well, follow [Remove saved data](data.md#remove-saved-data).
