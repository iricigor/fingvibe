# ISP logos

The Network page loads Logo.dev PNG images by the exact ISP name returned by ipwho.is. It does not strip legal suffixes or country names, maintain aliases, or call the secret-key search API. The square image is requested at 128 pixels for a 32-DIP slot. Name lookup returns the top matching brand; a successful image response is not proof of correct branding.

Logo loading is independent of network identity and scanning, has a five-second cancellation deadline, and accepts at most 1 MiB before decoding. Missing configuration, HTTP errors (including 401, 404, and 429), network failures, and invalid images leave the generic network icon. Diagnostics omit request URLs and exception messages because they may contain the key. No automatic retries occur; the current request/image is reused across UI refreshes and scans. Changing the ISP cancels obsolete work, and closing the window prevents late UI updates.

## Release configuration

Create the GitHub Actions repository secret `LOGO_DEV_PUBLISHABLE_KEY` with a Logo.dev **publishable** (`pk_`) key. The release workflow supplies it only to the app publish step. The build generates an embedded text resource under `obj`; neither the value nor generated configuration belongs in Git. Secret (`sk_`) keys and malformed values fail configuration generation without echoing their contents.

The publishable key is intentionally extractable from the released application. It cannot authorize Logo.dev's secret-key API, but other people can reuse it against the shared CDN allowance. Domain restrictions depend on browser `Referer` headers and do not naturally protect this native app. No Key Vault, backend, or sign-in is involved.

Local builds and PR/fork workflows omit the key by default and still build and run with a generic icon. PR workflows do not receive the repository secret. A keyless rebuild overwrites any previous generated key configuration.

For a local verification build, read the publishable key interactively into the current PowerShell process, rather than putting it in a tracked file or command-line build property:

```powershell
$env:LOGO_DEV_PUBLISHABLE_KEY = Read-Host "Logo.dev publishable key (pk_)"
try {
    dotnet run --project src\FingVibe.App\FingVibe.App.csproj -p:Platform=x64
}
finally {
    Remove-Item Env:\LOGO_DEV_PUBLISHABLE_KEY
}
```

Use the usual Visual Studio/MSBuild prerequisites described in the README. Do not publish verbose diagnostic environment dumps or build logs containing credentials. Generated build output containing a real key is intentionally configured output, not a secret-free artifact.

To rotate, create a replacement publishable key, update the repository secret, and publish an updated app. Revoking the old key prevents fresh logo requests from older installations; already cached images may remain temporarily. There is no remote key-refresh mechanism.

## Provider policies and caching

The Windows HTTP client uses the operating system's normal HTTP caching, rather than an application-managed disk store. Logo.dev documents `Cache-Control: max-age=86400, stale-while-revalidate=600`; actual reuse depends on the Windows HTTP cache, not browser behavior, and is not guaranteed across launches. FingVibe does not force cache bypass, copy logos into a persistent asset library, or proxy/self-host CDN images.

Policies checked on 2026-10-24:

- The Community plan advertises 500,000 CDN requests per month, with a hard cap and additional per-minute limits. Exhaustion leaves generic icons rather than affecting scanning.
- Direct CDN loading in users' apps is permitted. Copying/self-hosting assets instead requires the separate secret-key API.
- Individually maintained, non-revenue open-source/personal projects are exempt from attribution. Commercial or organization-owned projects on Community require a visible Logo.dev link on a public webpage; an in-app-only credit is not sufficient under the documented verification process. Reassess this if project ownership or monetization changes.
- Logos remain their owners' trademarks and do not imply endorsement.

References: [keys](https://www.logo.dev/docs/platform/api-keys), [name matching](https://www.logo.dev/docs/logo-images/name), [caching](https://www.logo.dev/docs/platform/caching), [fair use](https://www.logo.dev/docs/platform/fair-use), [attribution](https://www.logo.dev/docs/platform/attribution), [pricing](https://www.logo.dev/pricing).

## Verification

Run `dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter FullyQualifiedName~IspLogoSession` and `pwsh -File tests\LogoDevConfiguration.Tests.ps1`. The tests use dummy keys and do not contact Logo.dev. UI-review fixtures always disable logo requests even in a configured build.

For live verification, launch a configured build on a connection reporting `T-Mobile Czech Republic a.s.`, open Network, and inspect the logo alongside the unchanged name. Check light/dark appearance and display scaling. Also check a keyless build, offline/invalid-key/missing-image scenarios, and a delayed request while starting a LAN scan. Do not put token-bearing URLs into screenshots or diagnostics.
