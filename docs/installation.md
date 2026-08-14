# Installation

How to install, authenticate and verify the `dotnet-release-tracker` skill — and what it cannot do.

## 1. Prerequisites

| Requirement | Notes |
| --- | --- |
| Windows | Verified on Windows 10.0.26200 |
| Windows PowerShell 5.1 | Verified on 5.1.26100.8875. The scripts are written for 5.1 syntax |
| Azure CLI | [aka.ms/installazurecli](https://aka.ms/installazurecli) |
| Microsoft corp tenant account | With Release Tracker access — this is an internal service |
| GitHub Copilot CLI | Discovers skills from `~/.copilot/skills/` |

No PowerShell modules are required. The test suite is self-contained and does **not** need Pester.

## 2. Install the skill

Copilot CLI loads user-scoped skills from `~/.copilot/skills/<skill-name>/`. Copy the folder there:

```powershell
$dest = Join-Path $env:USERPROFILE '.copilot\skills\dotnet-release-tracker'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path .\dotnet-release-tracker\* -Destination $dest -Recurse -Force
```

Confirm the layout:

```powershell
Get-ChildItem $dest -Recurse -File | ForEach-Object { $_.FullName.Replace("$dest\", '') }
```

Expected:

```
README.md
SKILL.md
docs\installation.md
docs\test-result.md
reference\api-endpoints.md
scripts\Get-ReleaseTrackerData.ps1
scripts\Get-ReleaseTrackerFile.ps1
scripts\ReleaseTracker.Common.ps1
tests\Invoke-SkillTests.ps1
```

There is no registration step — Copilot CLI reads `SKILL.md`'s frontmatter to decide when to load
the skill.

## 3. Authenticate

```powershell
az login
```

The scripts request a token for the `api://` SPN of the app registration named `ReleaseTracker`,
**resolved by display name at runtime**. The resource GUID is deliberately not hardcoded.

To skip the lookup (useful in constrained environments or to avoid a Microsoft Graph call):

```powershell
$env:RELEASE_TRACKER_RESOURCE = 'api://<tracker-app-id>'
```

Azure CLI often installs to `%ProgramFiles%\Microsoft SDKs\Azure\CLI2\wbin\az.cmd` without
refreshing `PATH` for already-running shells. The skill probes the known install locations itself,
so `az` does not have to be on `PATH`.

## 4. Verify

### Offline (no network, no sign-in)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
    -File "$dest\tests\Invoke-SkillTests.ps1" -SkipIntegrationTests
```

Expected: `Passed: 36   Failed: 0   Skipped: 12`

### Live (requires `az login`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$dest\tests\Invoke-SkillTests.ps1"
```

Expected: `Passed: 48   Failed: 0   Skipped: 0`

### Smoke test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
    -File "$dest\scripts\Get-ReleaseTrackerData.ps1"
```

A release table plus a `=== Links ===` section means the install is good.

## 5. Troubleshooting

The scripts check access up front and report a specific reason rather than failing at the HTTP
layer.

| Reason | Meaning | Fix |
| --- | --- | --- |
| `NoAzCli` | Azure CLI not found in `PATH` or the known install locations | Install Azure CLI |
| `NotSignedIn` | No active `az` account | `az login` |
| `NoTenantAccess` | Signed in, but the `ReleaseTracker` app registration is not visible | Sign in with a Microsoft corp account that has tracker access |

Other symptoms:

| Symptom | Cause |
| --- | --- |
| `...cannot be loaded because running scripts is disabled` | Execution policy is `Restricted`. Always invoke with `powershell -NoProfile -ExecutionPolicy Bypass -File ...` |
| A request "succeeds" but returns HTML | Every unknown path returns **HTTP 200 with the SPA's `index.html`** (~1920 bytes). A 200 proves nothing — the body must parse as JSON |
| `release-metadata/{id}` returns 404 | Expected for releases whose metadata has not been generated. Treated as optional, not a failure |
| Artifact / feed / staging links prompt for credentials | Those are Azure DevOps resources needing a **different** token — see [Limitations](#limitations) |
| `Refusing to call '<endpoint>'...` | The read-only guard fired. Intentional; see [Limitations](#limitations) |
| `-IncludeManifests requires -OutputPath` | Manifests are multi-megabyte and are never printed to the console |

## Limitations

### Access and scope

1. **Microsoft-internal only.** `https://release.dot.net` is not publicly reachable. Anonymous
   requests always fail — `/.auth/me` returns `{"clientPrincipal": null}` and the SPA renders
   "An unhandled error has occurred." There is no way to use this skill without a corporate
   account that has been granted access.
2. **Two different tokens are involved.** The tracker token opens `release.dot.net/api` only. The
   artifacts, staging-pipeline and NuGet feed links point at `dev.azure.com/dnceng/internal` and
   `pkgs.dev.azure.com/dnceng/internal`, which require the **Azure DevOps** resource
   `499b84ac-1321-427f-aa17-267ca6975798`. This skill returns those links; it does not download
   Azure DevOps artifacts for you, and having tracker access does not imply having ADO access.
3. **Read access does not imply pipeline permissions.** Viewing a staging pipeline is not the same
   as being able to approve or run it; those actions may need additional roles.
4. **Resolving the token resource by display name needs directory read access.** If your account
   cannot enumerate app registrations, set `$env:RELEASE_TRACKER_RESOURCE` manually.
5. **Token lifetime is Azure CLI's.** Long sessions can outlive the cached token; re-run `az login`
   if calls start failing after a period of inactivity.

### Behavioural limits

6. **Read-only by default, on purpose.** `releases/action/*`, `schedules/action/*`, the CVE write
   endpoints and `payload-tracking/*` are refused unless `-AllowWrite` is passed. These act on
   live, in-flight .NET releases. The skill will not create, publish, import, update or delete
   anything on its own initiative, and it deliberately blocks `payload-tracking/*` too — those are
   computation-only POSTs but expensive.
7. **Large payloads must go to disk.** `-Metadata` and `-IncludeManifests` require `-OutputPath`.
   `ReleaseDropManifest.json` alone is ~3 MB and would otherwise flood an agent's context.
8. **`-Scope Everything` is slow and chatty.** It sweeps every release (145) and their builds
   (700+), which is hundreds of sequential API calls and produces a ~929 KB JSON dump. There is no
   parallelism, caching or incremental sync. Use `-Scope Active` for routine questions.
9. **No pagination controls or server-side filtering.** The API returns whole views; filtering by
   `-ReleaseId` happens client-side (with a `release-details` fallback for non-active releases).

### Durability of the API surface

10. **There is no OpenAPI/Swagger document.** The endpoint catalog in
    `reference/api-endpoints.md` was recovered from the client WebAssembly assemblies and verified
    by live calls. It is **not a published contract** — the tracker team can change or remove
    endpoints without notice, and this skill would need re-verification if the SPA is rebuilt.
11. **Endpoint id types are inconsistent and unvalidated.** CVE routes take GUIDs while release
    routes take ints; passing the wrong one returns 400. Get CVE GUIDs from `cve/LoadReleases`
    first.
12. **Not all documented blob paths are guaranteed to exist.** Staging containers vary by release;
    `assets/Shipping/...` paths in particular differ between releases and stages.

### Platform

13. **Windows PowerShell 5.1 on Windows only.** Not tested on PowerShell 7, Linux or macOS. The
    scripts intentionally use 5.1-compatible syntax and Windows path handling, and the test suite
    asserts 5.1 behaviours.
14. **Azure CLI is a hard dependency.** There is no fallback to `Connect-AzAccount`, managed
    identity, device-code flow or a raw bearer token supplied by the caller.
15. **The public fallback is far less detailed.** When the tracker is unreachable, the only
    alternative is
    `https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json`, which has no
    staging, BAR id, pipeline or in-flight information.
