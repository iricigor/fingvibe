# Install FingVibe from the right-click menu

`Install-FingVibe.ps1` unblocks a selected release ZIP, extracts it to
`%LOCALAPPDATA%\Programs\FingVibe`, and launches `FingVibe.App.exe`. It requires
Windows PowerShell 5.1 or later and does not need administrator rights.

## One-time setup

1. Create `%USERPROFILE%\Scripts` and save `Install-FingVibe.ps1` there. Keep
   this local copy outside the app's installation folder.
2. If Windows marks the script itself as downloaded, open its **Properties**,
   select **Unblock**, and apply. Only do this after reviewing the script.
3. Press **Win+R**, enter `shell:sendto`, and press Enter.
4. In that folder, choose **New > Shortcut**, using this target:

   ```text
   powershell.exe -NoProfile -File "%USERPROFILE%\Scripts\Install-FingVibe.ps1"
   ```

5. Name the shortcut **Install FingVibe**.

If your PowerShell execution policy prevents scripts from running, this shortcut
does not bypass it. Follow your machine's script policy; on a managed machine,
ask your administrator.

## Install or update

Download a Windows x64 release ZIP from
[this repository's releases](https://github.com/iricigor/fingvibe/releases),
then close FingVibe. Right-click the ZIP and choose
**Show more options > Send to > Install FingVibe**. On Windows versions using
the classic context menu, choose **Send to > Install FingVibe** directly.

Select one ZIP at a time. Its name must match `FingVibe-*-win-x64.zip`.
The script uses the selected file, not the newest file in Downloads. Updates
overwrite matching installed files; they do not delete obsolete files or change
the app's saved settings. Errors stay visible until you press Enter.

You can also run the script directly:

```powershell
& "$env:USERPROFILE\Scripts\Install-FingVibe.ps1" `
    -ZipPath "$env:USERPROFILE\Downloads\FingVibe-1.0.123-win-x64.zip"
```

## Trust and limitations

Only use this command for builds you trust. The filename check is a convenience,
not an authenticity or malware check. Unblocking removes the selected archive's
internet-download marker before extraction, just like **Properties > Unblock**.
It does not disable SmartScreen globally, sign the app, establish a verified
publisher, or guarantee that other Windows security controls will allow it.

This is a local convenience script, not a registered Windows installer. To
remove it, close FingVibe, delete `%LOCALAPPDATA%\Programs\FingVibe`, and remove
the shortcut from `shell:sendto`. You can also delete the local script copy.
The app's saved settings remain in `%LOCALAPPDATA%\FingVibe`.
