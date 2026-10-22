# FingVibe

FingVibe is a native Windows 11 LAN scanner built with C# and WinUI 3. It detects active IPv4 network interfaces, shows the machine address and subnet, and probes every usable address concurrently.

## Features

- Native WinUI 3 desktop UI with no embedded web content
- Automatic local IPv4 and CIDR discovery
- Parallel ICMP scanning with up to 256 concurrent probes
- Device names from UPnP/SSDP, reverse DNS, and NetBIOS
- MAC vendor lookup using locally cached IEEE registries, including private/randomized detection
- Bounded probes for common TCP services with compact Fluent port icons
- Live progress, cancellation, and per-host reachability results
- Pull request build artifacts for Windows x64
- Automatically versioned GitHub Releases from `main`

## Run locally

Prerequisites:

- Windows 11
- .NET 8 SDK
- Visual Studio 2022 with the **Windows application development** workload, or the equivalent Windows SDK build tools

```powershell
dotnet restore FingVibe.sln
dotnet run --project src\FingVibe.App\FingVibe.App.csproj -p:Platform=x64
```

The scanner uses ICMP echo requests. Firewall rules and devices configured not to answer ICMP can cause an active host to appear unreachable. On first use, vendor detection downloads the official IEEE MA-L, MA-M, and MA-S registries and caches them under the current user's local application data for 30 days.

## Test

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj
```

## Download builds

Every pull request uploads a `fingvibe-win-x64-pr-*` artifact from the **Actions** run. Every push to `main` publishes a GitHub Release tagged `v1.0.<run number>` with a self-contained Windows x64 ZIP.