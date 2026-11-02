#ifndef AppVersion
  #error AppVersion must be supplied by New-Installer.ps1
#endif

[Setup]
AppId={{BA17F8F1-EF47-4D63-9D8F-E46B23F79225}
AppName=FingVibe
AppVersion={#AppVersion}
AppPublisher=FingVibe
AppPublisherURL=https://github.com/iricigor/fingvibe
AppSupportURL=https://github.com/iricigor/fingvibe/issues
DefaultDirName={localappdata}\Programs\FingVibe
DefaultGroupName=FingVibe
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
OutputDir={#OutputDirectory}
OutputBaseFilename=FingVibe-{#AppVersion}-win-x64-Setup
SetupIconFile={#SourceDirectory}\Assets\Scanner.ico
UninstallDisplayIcon={app}\FingVibe.App.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}

[Tasks]
Name: desktopicon; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#OwnershipManifest}"; DestDir: "{app}"; DestName: "_fingvibe-files.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\FingVibe"; Filename: "{app}\FingVibe.App.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\FingVibe"; Filename: "{app}\FingVibe.App.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\FingVibe\Installer"; ValueType: dword; ValueName: "VersionMS"; ValueData: "{#VersionMS}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\FingVibe\Installer"; ValueType: dword; ValueName: "VersionLS"; ValueData: "{#VersionLS}"; Flags: uninsdeletekey

[Code]
function AppIsRunning: Boolean;
var
  Locator, Services, Processes: Variant;
begin
  Locator := CreateOleObject('WbemScripting.SWbemLocator');
  Services := Locator.ConnectServer('', 'root\CIMV2');
  Processes := Services.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name = ''FingVibe.App.exe''');
  Result := Processes.Count > 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  OldMS, OldLS: Cardinal;
  HasVersion: Boolean;
begin
  Result := '';
  if AppIsRunning then begin
    Result := 'Close FingVibe before installing or updating, then try again.';
    Exit;
  end;
  if RegKeyExists(HKCU, 'Software\FingVibe\Installer') then begin
    if not RegQueryDWordValue(HKCU, 'Software\FingVibe\Installer', 'VersionMS', OldMS) or
       not RegQueryDWordValue(HKCU, 'Software\FingVibe\Installer', 'VersionLS', OldLS) then begin
      Result := 'Cannot read the installed FingVibe version. Uninstall FingVibe before reinstalling; saved data will be preserved.';
      Exit;
    end;
    HasVersion := True;
  end else
    HasVersion := GetVersionNumbers(ExpandConstant('{app}\FingVibe.App.dll'), OldMS, OldLS);
  if HasVersion then
    if (OldMS > {#VersionMS}) or ((OldMS = {#VersionMS}) and (OldLS > {#VersionLS})) then
      Result := 'A newer version of FingVibe is already installed. Downgrades are not supported.';
end;

function InitializeUninstall: Boolean;
begin
  Result := not AppIsRunning;
  if not Result then
    SuppressibleMsgBox('Close FingVibe before uninstalling, then try again.', mbError, MB_OK, IDOK);
end;

function SafeRelativePath(Path: String): Boolean;
begin
  Result := (Path <> '') and (Pos(':', Path) = 0) and
    (Pos('/', Path) = 0) and (Pos('*', Path) = 0) and (Pos('?', Path) = 0) and
    (Copy(Path, 1, 1) <> '\') and (Pos('\..\', '\' + Path + '\') = 0) and
    (Pos('\.\', '\' + Path + '\') = 0);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Previous, Incoming: TArrayOfString;
  I, J: Integer;
  StillOwned: Boolean;
  Path, OldManifest: String;
begin
  if CurStep <> ssInstall then Exit;
  OldManifest := ExpandConstant('{app}\_fingvibe-files.txt');
  if not FileExists(OldManifest) then Exit;
  if not LoadStringsFromFile(OldManifest, Previous) then
    RaiseException('Cannot read the previous FingVibe file manifest.');
  ExtractTemporaryFile('_fingvibe-files.txt');
  if not LoadStringsFromFile(ExpandConstant('{tmp}\_fingvibe-files.txt'), Incoming) then
    RaiseException('Cannot read the new FingVibe file manifest.');
  for I := 0 to GetArrayLength(Previous) - 1 do
    if not SafeRelativePath(Previous[I]) then
      RaiseException('The previous FingVibe file manifest contains an unsafe path.');
  for I := 0 to GetArrayLength(Previous) - 1 do begin
    StillOwned := False;
    for J := 0 to GetArrayLength(Incoming) - 1 do
      if CompareText(Previous[I], Incoming[J]) = 0 then begin
        StillOwned := True;
        Break;
      end;
    if not StillOwned then begin
      Path := ExpandConstant('{app}\') + Previous[I];
      if FileExists(Path) then
        if not DeleteFile(Path) then
          RaiseException('Cannot remove obsolete FingVibe file: ' + Path);
    end;
  end;
end;
