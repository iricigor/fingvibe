[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppDirectory,
    [Parameter(Mandatory)][string] $InstallerPath,
    [Parameter(Mandatory)][string] $Version,
    [Parameter(Mandatory)][string] $LogDirectory
)

# The current feature family; keep it equal to the release version in .github/workflows/release.yml.
# Bumping the feature version changes only this value: the previous family and every fixture
# version are derived from it, so no lifecycle case is added per release.
$FeatureFamily = "1.4"

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "Installer lifecycle tests may run only on disposable GitHub-hosted Windows runners."
}
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, Accessibility
# Inno's owner-drawn checklist exposes checked state through MSAA, but no default action.
# Accessibility is a framework interop assembly; unify only its older System.Runtime reference.
Add-Type -ReferencedAssemblies Accessibility, System.Collections `
    -CompilerOptions '/nowarn:1701' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Accessibility;

public sealed class InstallerControl
{
    public IntPtr Handle { get; set; }
    public string Text { get; set; }
    public string ClassName { get; set; }
    public bool Visible { get; set; }
    public bool Enabled { get; set; }
}

public static class InstallerNativeControls
{
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId,
        ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private delegate bool EnumChildProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendTextMessageTimeout(IntPtr window, uint message, IntPtr wParam,
        StringBuilder text, uint flags, uint timeout, out UIntPtr result);

    public static InstallerControl[] GetChildren(IntPtr wizard)
    {
        if (wizard == IntPtr.Zero) throw new ArgumentException("A verified wizard window is required.", "wizard");
        var windows = new List<IntPtr>();
        EnumChildWindows(wizard, (window, parameter) =>
        {
            windows.Add(window);
            return true;
        }, IntPtr.Zero);
        var controls = new List<InstallerControl>();
        foreach (var window in windows)
        {
            var text = new StringBuilder(512);
            var className = new StringBuilder(256);
            GetClassName(window, className, className.Capacity);
            var name = className.ToString();
            if (IsWindowVisible(window) && (name == "TNewButton" || name == "TButton" || name == "Button"))
            {
                // Query control text in the installer process, not just its window caption cache.
                UIntPtr copied;
                if (SendTextMessageTimeout(window, 0x000D, new IntPtr(text.Capacity), text, 2, 1000, out copied) == IntPtr.Zero)
                    throw new InvalidOperationException("Could not read the installer button text (Win32 " + Marshal.GetLastWin32Error() + ").");
            }
            else GetWindowText(window, text, text.Capacity);
            controls.Add(new InstallerControl {
                Handle = window, Text = text.ToString(), ClassName = name,
                Visible = IsWindowVisible(window),
                Enabled = IsWindowEnabled(wizard) && IsWindowEnabled(window)
            });
        }
        return controls.ToArray();
    }

    public static void Click(IntPtr wizard, IntPtr button)
    {
        if (!IsChild(wizard, button) || !IsWindowVisible(button) ||
            !IsWindowEnabled(wizard) || !IsWindowEnabled(button))
            throw new InvalidOperationException("The selected installer button is not a ready child of this wizard.");
        SetForegroundWindow(wizard);
        if (GetForegroundWindow() != wizard)
            throw new InvalidOperationException("The installer wizard could not acquire the foreground.");
        // Post like real input: a sent BM_CLICK runs the handler inside an input-synchronous call, where
        // the installer's WMI running-app check (PrepareToInstall) is refused and blocks on a runtime error.
        if (!PostMessage(button, 0x00F5, IntPtr.Zero, IntPtr.Zero))
            throw new InvalidOperationException("Installer button invocation failed (Win32 " + Marshal.GetLastWin32Error() + ").");
    }

    // Identifies the visible wizard page without messaging the installer thread, which may be busy installing.
    public static string GetPageSignature(IntPtr wizard)
    {
        var pages = new List<string>();
        EnumChildWindows(wizard, (window, parameter) =>
        {
            var className = new StringBuilder(256);
            GetClassName(window, className, className.Capacity);
            if (className.ToString() == "TNewNotebookPage" && IsWindowVisible(window)) pages.Add(window.ToInt64().ToString());
            return true;
        }, IntPtr.Zero);
        return string.Join(",", pages);
    }

    private static IAccessible Open(IntPtr window)
    {
        var id = typeof(IAccessible).GUID;
        IAccessible accessible;
        Marshal.ThrowExceptionForHR(AccessibleObjectFromWindow(window, 0xFFFFFFFC, ref id, out accessible));
        return accessible;
    }

    private static int Find(IAccessible accessible)
    {
        for (var child = 1; child <= accessible.accChildCount; child++)
            if (accessible.get_accName(child) == "Start FingVibe") return child;
        throw new InvalidOperationException("The finish page has no Start FingVibe choice.");
    }

    public static bool IsChecked(IntPtr window)
    {
        var accessible = Open(window);
        try { return (Convert.ToInt32(accessible.get_accState(Find(accessible))) & 0x10) != 0; }
        finally { Marshal.ReleaseComObject(accessible); }
    }

    public static void Toggle(IntPtr window)
    {
        var accessible = Open(window);
        try
        {
            var index = Find(accessible) - 1;
            if (SendMessage(window, 0x0186, new IntPtr(index), IntPtr.Zero).ToInt64() != index)
                throw new InvalidOperationException("Could not select the Start FingVibe choice.");
            SendMessage(window, 0x0100, new IntPtr(0x20), IntPtr.Zero);
            SendMessage(window, 0x0101, new IntPtr(0x20), IntPtr.Zero);
        }
        finally { Marshal.ReleaseComObject(accessible); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int informationClass,
        ref ProcessBasicInformation information, int length, out int returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);

    private static byte[] Read(IntPtr process, IntPtr address, int size)
    {
        var buffer = new byte[size];
        IntPtr read;
        if (!ReadProcessMemory(process, address, buffer, new IntPtr(size), out read) || read.ToInt64() != size)
            throw new InvalidOperationException("Could not read the launched process parameters (Win32 " + Marshal.GetLastWin32Error() + ").");
        return buffer;
    }

    // Inno 6.7 does not log a Run entry's working directory, so read the launched process's own
    // RTL_USER_PROCESS_PARAMETERS.CurrentDirectory (x64: PEB+0x20, parameters+0x38).
    public static string GetCurrentDirectory(IntPtr process)
    {
        if (!Environment.Is64BitProcess) throw new PlatformNotSupportedException("The working-directory check requires a 64-bit test host.");
        var information = new ProcessBasicInformation();
        int returned;
        var status = NtQueryInformationProcess(process, 0, ref information, Marshal.SizeOf(information), out returned);
        if (status != 0) throw new InvalidOperationException("Could not query the launched process (NTSTATUS 0x" + status.ToString("X8") + ").");
        var parameters = new IntPtr(BitConverter.ToInt64(Read(process, information.PebBaseAddress + 0x20, 8), 0));
        var directory = Read(process, parameters + 0x38, 16);
        var length = BitConverter.ToUInt16(directory, 0);
        var text = new IntPtr(BitConverter.ToInt64(directory, 8));
        return Encoding.Unicode.GetString(Read(process, text, length));
    }
}
'@
$app = Join-Path $env:LOCALAPPDATA "Programs\FingVibe"
$data = Join-Path $env:LOCALAPPDATA "FingVibe"
$registration = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BA17F8F1-EF47-4D63-9D8F-E46B23F79225}_is1"
$versionKey = "HKCU:\Software\FingVibe\Installer"
foreach ($path in @($app, $data, $registration, $versionKey)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite an existing FingVibe installation/data: $path" }
}
$logs = [IO.Path]::GetFullPath($LogDirectory)
$null = New-Item -ItemType Directory -Path $logs -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-installer-lifecycle-$([guid]::NewGuid())"
$process = $null
$savedReview = $env:FINGVIBE_UI_REVIEW
$timings = [Collections.Generic.List[object]]::new()
$lifecycle = [Diagnostics.Stopwatch]::StartNew()
$lifecycleOutcome = "failed"

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Get-UninstallerExecutable([string] $CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        throw "Registered UninstallString is missing or empty."
    }
    $match = [regex]::Match($CommandLine.Trim(),
        '^(?:"(?<quoted>[^"]+\.exe)"|(?<plain>\S+\.exe))(?:\s+.*)?$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Could not parse the registered UninstallString: $CommandLine"
    }
    if ($match.Groups["quoted"].Success) { $match.Groups["quoted"].Value }
    else { $match.Groups["plain"].Value }
}
function Resolve-RegisteredUninstaller([object] $Registration, [string] $AppDirectory) {
    $property = if ($null -ne $Registration) { $Registration.PSObject.Properties["UninstallString"] }
    if ($null -eq $property) {
        throw "Registered uninstall information does not contain UninstallString."
    }
    $executable = Get-UninstallerExecutable ([string] $property.Value)
    $directory = [IO.Path]::GetFullPath($AppDirectory).TrimEnd("\")
    $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($executable))
    if (-not $path.StartsWith($directory + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Registered UninstallString resolves outside the FingVibe installation directory: $path"
    }
    if ([IO.Path]::GetFileName($path) -notmatch '^unins\d+\.exe$') {
        throw "Registered UninstallString does not name an Inno Setup uninstaller: $path"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Registered Inno Setup uninstaller is missing: $path"
    }
    $path
}
function Get-RegisteredUninstaller {
    if (-not (Test-Path -LiteralPath $registration)) {
        throw "FingVibe uninstall registration is missing."
    }
    Resolve-RegisteredUninstaller (Get-ItemProperty -LiteralPath $registration) $app
}
function Measure-Phase([string] $Kind, [string] $Name, [scriptblock] $Action) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $outcome = "failed"
    try {
        & $Action
        $outcome = "succeeded"
    } finally {
        $seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1)
        $timings.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Seconds = $seconds; Outcome = $outcome })
        Write-Host "Installer $Kind $Name $outcome in $seconds s."
    }
}
function Get-InnoSecondPhaseProcesses([string] $Path) {
    $marker = "/SECONDPHASE=`"$([IO.Path]::GetFullPath($Path))`""
    @(Get-CimInstance -ClassName Win32_Process | Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}
function Test-InnoUninstallComplete([string] $Path, [string] $LogPath, [bool] $Succeeded) {
    if (@(Get-InnoSecondPhaseProcesses $Path).Count -gt 0 -or
        -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return $false
    }
    $log = Get-Content -LiteralPath $LogPath -Raw
    if ($log -notmatch '(?m)Log closed\.\s*$') { return $false }
    if ($Succeeded) {
        return -not (Test-Path -LiteralPath $registration) -and
            -not (Test-Path -LiteralPath $versionKey) -and
            -not (Test-Path -LiteralPath $Path) -and
            -not (Test-Path -LiteralPath (Join-Path $app "FingVibe.App.exe"))
    }
    (Test-Path -LiteralPath $registration) -and (Test-Path -LiteralPath $Path)
}
function Wait-InnoUninstall([string] $Path, [string] $Name, [bool] $Succeeded) {
    $logPath = Join-Path $logs "$Name.log"
    $null = Wait-UiRegressionState -Description "$Name complete uninstall cleanup" `
        -TimeoutMilliseconds 30000 -PollMilliseconds 50 -Condition {
            Test-InnoUninstallComplete $Path $logPath $Succeeded
        }
}
function Invoke-Installer([string] $Path, [string] $Name,
    [ValidateSet("Install", "Uninstall")][string] $Operation,
    [switch] $ExpectFailure, [string[]] $Extra = @(),
    [ValidateSet("SILENT", "VERYSILENT")][string] $Mode = "VERYSILENT") {
    $kind = $Operation.ToLowerInvariant()
    Measure-Phase $kind $Name {
        $arguments = @("/$Mode", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/LOG=`"$(Join-Path $logs "$Name.log")`"") + $Extra
        $setup = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
        if (-not $setup.WaitForExit(180000)) {
            Stop-Process -Id $setup.Id -Force
            throw "Installer timed out: $Name"
        }
        if ($Operation -eq "Uninstall") {
            Wait-InnoUninstall $Path $Name (-not $ExpectFailure)
        }
        if ($ExpectFailure) {
            Assert-True ($setup.ExitCode -ne 0) "$Name unexpectedly succeeded."
        } else {
            Assert-True ($setup.ExitCode -eq 0) "$Name failed with exit code $($setup.ExitCode). See $logs."
            Assert-True (@(Get-InstalledAppProcess).Count -eq 0) "$Operation in $Mode must not launch FingVibe."
            Assert-True ((Get-Content (Join-Path $logs "$Name.log") -Raw) -notmatch '-- Run entry --') "$Operation in $Mode processed a Run entry."
        }
    }
}
function Get-InstalledAppProcess {
    Get-Process -Name FingVibe.App -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq (Join-Path $app "FingVibe.App.exe") }
}
function Get-InstallerCaption([string] $Text) {
    # Inno Setup 6.7 labels its navigation "&Next"; older versions used "&Next >".
    ($Text.Replace('&', '') -replace '\s*>$', '').Trim()
}
function Get-InstallerButton([object[]] $Controls, [string[]] $Names) {
    $matches = @($Controls | Where-Object { $_.Visible -and $_.Enabled -and
        $_.ClassName -in @('TNewButton', 'TButton', 'Button') -and
        (Get-InstallerCaption $_.Text) -in $Names })
    if ($matches.Count -gt 1) { throw "More than one installer navigation button is ready." }
    if ($matches.Count -eq 1) { $matches[0] }
}
function Invoke-InteractiveSetup([string] $Path, [string] $Name, [bool] $Launch) {
    Measure-Phase "interactive-setup" $Name {
        Assert-True (@(Get-InstalledAppProcess).Count -eq 0) "FingVibe must be stopped before $Name."
        $setup = Start-Process -FilePath $Path -ArgumentList @("/SP-", "/NORESTART",
            "/LOG=`"$(Join-Path $logs "$Name.log")`"") -PassThru
        $wizardProcess = $null
        $wizardWindow = [IntPtr]::Zero
        try {
            $wizard = Wait-UiRegressionState -Description "$Name wizard" -TimeoutMilliseconds 30000 -Condition {
                if ($setup.HasExited) { throw "$Name exited before showing its wizard: $($setup.ExitCode)" }
                $windows = @([System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ClassNameProperty, "TWizardForm")) |
                    Where-Object { (Test-UiRegressionElementVisible $_) -and $_.Current.Name -like '*FingVibe*' })
                if ($windows.Count -gt 1) { throw "More than one FingVibe installer wizard is visible." }
                if ($windows.Count -eq 1) { $windows[0] }
            }
            $wizardProcess = Get-Process -Id $wizard.Current.ProcessId
            $wizardWindow = [IntPtr] $wizard.Current.NativeWindowHandle
            $finish = $null
            for ($step = 0; $step -lt 6; $step++) {
                $button = Wait-UiRegressionState -Description "$Name next wizard action" -TimeoutMilliseconds 120000 -Condition {
                    if ($wizardProcess.HasExited) { throw "$Name wizard exited unexpectedly." }
                    try { $controls = [InstallerNativeControls]::GetChildren($wizardWindow) }
                    catch {
                        # A busy installer thread cannot answer the bounded text query yet; poll again.
                        if ($_.Exception.Message -notlike '*(Win32 1460)*') { throw }
                        return
                    }
                    Get-InstallerButton $controls @('Next', 'Install', 'Finish')
                }
                Write-Host "Installer $Name step ${step}: $($button.ClassName) '$($button.Text)'."
                if ((Get-InstallerCaption $button.Text) -eq 'Finish') { $finish = $button; break }
                $page = [InstallerNativeControls]::GetPageSignature($wizardWindow)
                [InstallerNativeControls]::Click($wizardWindow, $button.Handle)
                # The posted click is asynchronous; never look for the next action on the page just left.
                $null = Wait-UiRegressionState -Description "$Name page after '$($button.Text)'" -TimeoutMilliseconds 60000 -Condition {
                    if ($wizardProcess.HasExited) { throw "$Name wizard exited unexpectedly." }
                    [InstallerNativeControls]::GetPageSignature($wizardWindow) -ne $page
                }
            }
            Assert-True ($null -ne $finish) "$Name did not reach Finish within the expected wizard pages."
            Assert-True (@(Get-InstalledAppProcess).Count -eq 0) "$Name launched before Finish."
            $choices = @([InstallerNativeControls]::GetChildren($wizardWindow) |
                Where-Object { $_.Visible -and $_.Enabled -and $_.ClassName -eq 'TNewCheckListBox' })
            Assert-True ($choices.Count -eq 1) "$Name must expose one finish-screen launch checklist."
            $choiceWindow = $choices[0].Handle
            Assert-True ([InstallerNativeControls]::IsChecked($choiceWindow)) "$Name must default Start FingVibe to checked."
            if (-not $Launch) {
                [InstallerNativeControls]::Toggle($choiceWindow)
                $null = Wait-UiRegressionState -Description "$Name unchecked launch choice" -Condition {
                    -not [InstallerNativeControls]::IsChecked($choiceWindow)
                }
            }
            [InstallerNativeControls]::Click($wizardWindow, $finish.Handle)
            Assert-True ($setup.WaitForExit(30000)) "$Name did not finish without waiting for the app."
            Assert-True ($setup.ExitCode -eq 0) "$Name failed: $($setup.ExitCode)."
            $log = Get-Content (Join-Path $logs "$Name.log") -Raw
            if ($Launch) {
                $script:process = Wait-UiRegressionState -Description "$Name installed app launch" -TimeoutMilliseconds 45000 -Condition {
                    $running = @(Get-InstalledAppProcess)
                    if ($running.Count -gt 1) { throw "$Name launched more than one app process." }
                    if ($running.Count -eq 1) { $running[0] }
                }
                $null = Wait-UiRegressionState -Description "$Name app window" -TimeoutMilliseconds 45000 -Condition {
                    $script:process.Refresh()
                    if ($script:process.HasExited) { throw "$Name app exited before showing a window." }
                    $script:process.MainWindowHandle -ne 0
                }
                $workingDirectory = [InstallerNativeControls]::GetCurrentDirectory($script:process.Handle).TrimEnd('\')
                Assert-True ($workingDirectory -eq $app.TrimEnd('\')) "$Name started FingVibe in '$workingDirectory' instead of the installation directory."
                Assert-True ($script:process.CloseMainWindow()) "$Name app could not close normally."
                Assert-True ($script:process.WaitForExit(15000)) "$Name app did not close."
                $script:process = $null
            } else {
                Assert-True (@(Get-InstalledAppProcess).Count -eq 0) "$Name launched despite being unchecked."
                Assert-True ($log -notmatch '-- Run entry --') "$Name processed the unchecked Run entry."
            }
        } catch {
            $failure = $_
            if ($wizardWindow -ne [IntPtr]::Zero) {
                try {
                    [InstallerNativeControls]::GetChildren($wizardWindow) |
                        Select-Object Text, ClassName, Visible, Enabled, @{Name='Handle';Expression={$_.Handle.ToInt64()}} |
                        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $logs "$Name-controls.json")
                } catch {
                    Write-Warning "Could not capture installer controls: $($_.Exception.Message)"
                }
            }
            throw $failure
        } finally {
            if ($wizardProcess -and -not $wizardProcess.HasExited) { Stop-Process -Id $wizardProcess.Id -Force }
            if (-not $setup.HasExited) { Stop-Process -Id $setup.Id -Force }
            foreach ($launched in @(Get-InstalledAppProcess)) { Stop-Process -Id $launched.Id -Force }
        }
    }
}
function New-FixtureInstaller([string] $Source, [string] $FixtureVersion) {
    Measure-Phase "compile" $FixtureVersion {
        & $builder -AppDirectory $Source -Version $FixtureVersion -OutputDirectory $fixture -FixtureCompression | Out-Host
    }
    Join-Path $fixture "FingVibe-$FixtureVersion-win-x64-Setup.exe"
}
function New-LifecycleFixtureApp([string] $Source, [string] $Destination) {
    $null = New-Item -ItemType Directory -Path (Join-Path $Destination "Assets") -Force
    Copy-Item -LiteralPath (Join-Path $Source "Assets\Scanner.ico") `
        -Destination (Join-Path $Destination "Assets\Scanner.ico")
    "fixture" | Set-Content -LiteralPath (Join-Path $Destination "FingVibe.App.dll")
    $fixtureSource = Join-Path $Destination "FingVibe.LaunchFixture.cs"
    @'
using System;
using System.Drawing;
using System.Windows.Forms;

public static class InstallerLaunchFixture
{
    [STAThread]
    public static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var window = new Form())
        {
            window.Text = "FingVibe installer fixture";
            window.ClientSize = new Size(320, 180);
            window.StartPosition = FormStartPosition.CenterScreen;
            Application.Run(window);
        }
    }
}
'@ | Set-Content -LiteralPath $fixtureSource
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "Installer lifecycle fixture compiler not found: $compiler"
    }
    & $compiler /nologo /target:winexe /platform:x64 "/out:$(Join-Path $Destination "FingVibe.App.exe")" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $fixtureSource
    if ($LASTEXITCODE -ne 0) { throw "Installer lifecycle fixture compilation failed with exit code $LASTEXITCODE." }
    Remove-Item -LiteralPath $fixtureSource
    $Destination
}
function Uninstall-App([string] $Name) {
    $uninstaller = Get-RegisteredUninstaller
    Invoke-Installer -Path $uninstaller -Name $Name -Operation Uninstall
    Assert-True (-not (Test-Path -LiteralPath $registration)) "Uninstall registration was not removed."
    Assert-True (-not (Test-Path -LiteralPath $versionKey)) "Installer version was not removed."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "FingVibe.App.exe"))) "Installed executable was not removed."
}
function Get-SavedDataHashes {
    $hashes = @{}
    Get-ChildItem -LiteralPath $data -Recurse -File | ForEach-Object {
        $hashes[[IO.Path]::GetRelativePath($data, $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    $hashes
}
function Assert-SavedDataUnchanged([hashtable] $Expected, [string] $Message) {
    $actual = Get-SavedDataHashes
    Assert-True ($actual.Count -eq $Expected.Count) "$Message (file count changed)"
    foreach ($relative in $Expected.Keys) {
        Assert-True ($actual[$relative] -eq $Expected[$relative]) "$Message ($relative)"
    }
}
function Assert-InstalledPayload([string] $Message) {
    foreach ($relative in $sourceHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $app $relative)).Hash -eq $sourceHashes[$relative]) "${Message}: $relative"
    }
}
try {
    $v = [version] $Version
    if ($v.Build -lt 1 -or $v.Build -ge 65534) { throw "Lifecycle fixture versions require adjacent lower and higher build numbers." }
    $family = [version] $FeatureFamily
    if ($family.Minor -lt 1) { throw "Define the previous feature family explicitly for a major-version bump." }
    $previousFamily = "$($family.Major).$($family.Minor - 1)"
    $builder = Join-Path $PSScriptRoot "..\tools\New-Installer.ps1"
    $source = (Resolve-Path -LiteralPath $AppDirectory).Path
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $null = New-Item -ItemType Directory -Path $fixture
    $sourceHashes = @{}
    Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
        $sourceHashes[[IO.Path]::GetRelativePath($source, $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    $fixtureSource = Measure-Phase "compile" "launch-fixture" {
        New-LifecycleFixtureApp $source (Join-Path $fixture "fixture-source")
    }
    Invoke-Installer -Path $installer -Name "fresh-install" -Operation Install -Mode SILENT
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Installed version differs from release version."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).InstallLocation.TrimEnd('\') -eq $app) "Installation must be per-user."
    $startShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "FingVibe.lnk"
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "FingVibe.lnk"
    Assert-True (Test-Path -LiteralPath $startShortcut) "Start menu shortcut is missing."
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut should be opt-in."
    Assert-InstalledPayload "Installed payload differs"
    $env:FINGVIBE_UI_REVIEW = "1"
    Measure-Phase "launch" "installed-app-window" {
        $script:process = Start-Process -FilePath (Join-Path $app "FingVibe.App.exe") -WorkingDirectory $app -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            Start-Sleep -Milliseconds 500
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Installed app exited before opening a window: $($script:process.ExitCode)" }
        } until ($script:process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
        Assert-True ($script:process.MainWindowHandle -ne 0) "Installed app did not open a window."
    }
    Invoke-Installer -Path $installer -Name "running-app-blocks-install" -Operation Install -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "running-app-blocks-install.log") -Raw) -match 'Close FingVibe') "App-running rejection was not reported."
    Invoke-Installer -Path (Get-RegisteredUninstaller) -Name "running-app-blocks-uninstall" -Operation Uninstall -ExpectFailure
    Assert-True ($process.CloseMainWindow()) "Could not close the installed app normally."
    Assert-True ($process.WaitForExit(15000)) "Installed app did not close."
    $process = $null
    $null = New-Item -ItemType Directory -Path $data -Force
    $savedData = Join-Path $data "installer-test-saved-data.txt"
    "keep saved data" | Set-Content -LiteralPath $savedData
    Uninstall-App "fresh-uninstall"
    Assert-True (-not (Test-Path -LiteralPath $startShortcut)) "Start menu shortcut survived uninstall."
    Assert-True ((Get-Content -LiteralPath $savedData) -eq "keep saved data") "Saved data was changed by uninstall."

    # One representative previous-feature upgrade with a higher build number, plus downgrade rejection.
    # Release runs upgrade to the actual release installer; other runs use a current-family fixture.
    if ($v -ge $family) {
        $featureVersion = $Version
        $featureInstaller = $installer
    } else {
        $featureVersion = "$FeatureFamily.$($v.Build)"
        $featureInstaller = New-FixtureInstaller $fixtureSource $featureVersion
    }
    $legacyVersion = "$previousFamily.$($v.Build + 1)"
    Assert-True ([version] $legacyVersion -lt [version] $featureVersion) "Feature version must order above the higher-build previous-family fixture."
    $legacyInstaller = New-FixtureInstaller $fixtureSource $legacyVersion
    Invoke-Installer -Path $legacyInstaller -Name "legacy-$previousFamily-install" -Operation Install
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $legacyVersion) "$previousFamily fixture was not installed."
    foreach ($name in @("device-inventory.sqlite", "latest-scan.json", "people-rooms.json", "appearance.json", "device-table.json", "periodic-scan.json")) {
        "synthetic $previousFamily $name" | Set-Content -LiteralPath (Join-Path $data $name)
    }
    $legacyData = Get-SavedDataHashes
    Invoke-Installer -Path $featureInstaller -Name "feature-upgrade-from-$previousFamily" -Operation Install
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $featureVersion) "$previousFamily installation was not upgraded to $featureVersion."
    Assert-SavedDataUnchanged $legacyData "$previousFamily feature-version upgrade changed saved inventory, history, or settings."
    Invoke-Installer -Path $legacyInstaller -Name "reject-$previousFamily-feature-downgrade" -Operation Install -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "reject-$previousFamily-feature-downgrade.log") -Raw) -match 'Downgrades are not supported') "$previousFamily downgrade rejection was not reported."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $featureVersion) "Rejected $previousFamily downgrade changed installed version."
    Assert-SavedDataUnchanged $legacyData "Rejected $previousFamily downgrade changed saved inventory, history, or settings."
    Uninstall-App "feature-upgrade-from-$previousFamily-uninstall"
    Assert-SavedDataUnchanged $legacyData "Uninstall after $previousFamily feature-version upgrade changed saved inventory, history, or settings."

    # The real production-compressed installer upgrades a lower same-family fixture, removing the
    # fixture's obsolete managed file while keeping unknown files and saved data.
    $lowerVersion = "$($v.Major).$($v.Minor).$($v.Build - 1)"
    $fixtureApp = Join-Path $fixture "app"
    $null = New-Item -ItemType Directory -Path $fixtureApp
    Copy-Item -Path (Join-Path $fixtureSource "*") -Destination $fixtureApp -Recurse
    "obsolete managed file" | Set-Content -LiteralPath (Join-Path $fixtureApp "obsolete-test.txt")
    $lowerInstaller = New-FixtureInstaller $fixtureApp $lowerVersion
    $currentInstaller = New-FixtureInstaller $fixtureSource $Version
    Invoke-Installer -Path $lowerInstaller -Name "lower-$lowerVersion-install" -Operation Install
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $lowerVersion) "Lower-version fixture was not installed."
    Assert-True (Test-Path -LiteralPath (Join-Path $app "obsolete-test.txt")) "Lower-version fixture did not install its managed file."
    $unknown = Join-Path $app "user-file.txt"
    "keep unknown file" | Set-Content -LiteralPath $unknown
    $upgradeData = Get-SavedDataHashes
    Invoke-Installer -Path $installer -Name "real-installer-upgrade-from-$lowerVersion" -Operation Install
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Real installer did not upgrade the lower-version installation."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "obsolete-test.txt"))) "Upgrade retained obsolete managed file."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Upgrade changed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Real installer upgrade changed saved data."
    Assert-InstalledPayload "Upgraded payload differs"
    Invoke-Installer -Path $lowerInstaller -Name "reject-downgrade" -Operation Install -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "reject-downgrade.log") -Raw) -match 'Downgrades are not supported') "Downgrade rejection was not reported."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Rejected downgrade changed installed version."
    Assert-SavedDataUnchanged $upgradeData "Rejected downgrade changed saved data."
    Uninstall-App "upgrade-uninstall"
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Uninstall removed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Uninstall removed saved data."

    # Emulate the existing ZIP script over the retained unknown file; the real installer adopts it.
    Copy-Item -Path (Join-Path $source "*") -Destination $app -Recurse -Force
    Invoke-Installer -Path $installer -Name "adopt-script-install" -Operation Install -Extra @("/TASKS=desktopicon")
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Real installer did not adopt the script installation."
    Assert-True (Test-Path -LiteralPath $desktopShortcut) "Selected desktop shortcut is missing."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Adoption removed an unknown file."
    Uninstall-App "adopt-uninstall"
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Uninstall after adoption removed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Uninstall after adoption removed saved data."
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut survived uninstall."
    foreach ($launch in @($true, $false)) {
        $choice = if ($launch) { 'checked' } else { 'unchecked' }
        Invoke-InteractiveSetup $lowerInstaller "fresh-finish-$choice" $launch
        $upgradeInstaller = if ($launch) { $installer } else { $currentInstaller }
        Invoke-InteractiveSetup $upgradeInstaller "upgrade-finish-$choice" $launch
        Uninstall-App "finish-$choice-uninstall"
    }
    $lifecycleOutcome = "succeeded"
    Write-Host "Installer lifecycle, silent suppression, and checked/unchecked fresh/upgrade Finish launch checks passed."
} finally {
    $env:FINGVIBE_UI_REVIEW = $savedReview
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    $total = [Math]::Round($lifecycle.Elapsed.TotalSeconds, 1)
    $timings.Add([pscustomobject]@{ Kind = "lifecycle"; Name = "total"; Seconds = $total; Outcome = $lifecycleOutcome })
    $timings | Export-Csv -LiteralPath (Join-Path $logs "lifecycle-timings.csv") -NoTypeInformation
    if ($env:GITHUB_STEP_SUMMARY) {
        $table = @("", "### Installer lifecycle timings ($lifecycleOutcome, $total s)", "", "| Phase | Action | Seconds | Outcome |", "| --- | --- | ---: | --- |")
        $table += $timings | ForEach-Object { "| $($_.Kind) | $($_.Name) | $($_.Seconds) | $($_.Outcome) |" }
        $table -join "`n" >> $env:GITHUB_STEP_SUMMARY
    }
}
