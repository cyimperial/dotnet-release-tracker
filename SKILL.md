---
name: dotnet-release-tracker
description: Queries the Microsoft-internal .NET Release Tracker at https://release.dot.net for release status, artifacts, NuGet feeds, staging pipelines, builds, BAR build ids, release manifests, CVE releases and release schedules. Use whenever the user asks about release.dot.net, the .NET Release Tracker, what .NET releases are active or in flight, a release's stage or staging container, "get me the artifacts/feed/staging pipeline" for a .NET release, BAR build ids for darc update-dependencies, ReleaseManifest.json, ReleaseDropManifest.json, .NET security/CVE releases, .NET release schedules, or whether they can access the release tracker.
---

# dotnet-release-tracker

Reads the .NET Release Tracker (`https://release.dot.net`) and reports releases, their artifacts,
feeds, staging pipelines and manifests.

## Facts this skill depends on

| Thing | Value |
| --- | --- |
| Site | `https://release.dot.net` (Blazor WebAssembly SPA) |
| API base | `https://release.dot.net/api` |
| Auth | `az login` (Microsoft corp tenant); token resource = the `api://` SPN of the app registration named `ReleaseTracker` |
| Downstream | `dev.azure.com/dnceng/internal` + `pkgs.dev.azure.com/dnceng/internal`, which need the **Azure DevOps** resource `499b84ac-1321-427f-aa17-267ca6975798` |
| Public fallback | `https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json` |

Never hardcode the tracker's resource GUID — resolve it by display name at runtime, as
`Get-ReleaseTrackerAccess` does. Set `$env:RELEASE_TRACKER_RESOURCE` to skip the lookup.

Full endpoint catalog, record fields and blob paths: [reference/api-endpoints.md](reference/api-endpoints.md).
Install, verification and limitations: [docs/installation.md](docs/installation.md).
Test coverage and known traps: [docs/test-result.md](docs/test-result.md).

## Running the bundled scripts

Execution policy is commonly `Restricted`, so the bypass is required:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\<Script>.ps1" @args
```

`<skill>` is this skill's own folder — resolve it from the skill path you were loaded from.
Never hardcode a user profile path.

| Script | Purpose |
| --- | --- |
| `Get-ReleaseTrackerData.ps1` | Releases, builds, links, CVEs, schedules — tables or JSON |
| `Get-ReleaseTrackerFile.ps1` | Pulls blobs (manifests, assets) out of a release's staging container |
| `ReleaseTracker.Common.ps1` | Shared auth + request helpers — dot-sourced, not run directly |

## Workflow

### 1. Confirm access before promising anything

The tracker is Microsoft-internal. Anonymous requests never work — `/.auth/me` returns
`{"clientPrincipal": null}` and the SPA renders "An unhandled error has occurred."

`Get-ReleaseTrackerData.ps1` checks this itself and reports `NoAzCli`, `NotSignedIn` or
`NoTenantAccess` up front; a resource that resolves but yields no token surfaces later as a
token-acquisition error. If access is unavailable, say so plainly and offer the public
fallback rather than guessing at release data.

### 2. Get the data

```powershell
# Active releases (default)
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Get-ReleaseTrackerData.ps1"

# Everything: all releases + config + dropdown + CVEs + schedules + per-release builds
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Get-ReleaseTrackerData.ps1" `
    -Scope Everything -OutputPath .\tracker-dump
```

Useful switches: `-Scope Active|All|Everything`, `-ReleaseId 159`, `-IncludeBuilds`,
`-IncludeReports`, `-IncludeConfig`, `-IncludeCves`, `-IncludeSchedules`, `-IncludeManifests`,
`-OutputPath`, `-AsJson`.

`-IncludeManifests` requires `-OutputPath` — `ReleaseDropManifest.json` alone is ~3 MB and must
never be dumped to the console.

### 3. Reach into a staging container

```powershell
# BAR build ids for darc update-dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Get-ReleaseTrackerFile.ps1" `
    -Release 11.0.0-rc.1 -BarIds

# All three metadata files
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Get-ReleaseTrackerFile.ps1" `
    -Release 11.0.0-rc.1 -Metadata -OutputPath .\rc1
```

`-Release` accepts a name, a numeric release id, or a substring. `-BlobPath` takes any path in the
container.

### 4. Report

Lead with a release table:

**Id | Name | Type | Stage | Runtime | Sdk | Released | Security | Builds**

Then the per-release links (artifacts, staging pipeline, NuGet feed). Call out which releases are
**unreleased** (null `releaseDate`) versus `Released`, and flag `isSecurity` releases.

## Hard-won details — do not regress these

**Every unknown path returns HTTP 200 with the SPA's `index.html`.** `blazor.boot.json`,
`swagger/v1/swagger.json` and `appsettings.json` all "succeed" with 1920 bytes of HTML. Never treat
a 200 as proof an endpoint exists — verify the body parses as JSON. Genuine API misses return real
404s because `/api/*` is not covered by the SPA fallback.

**There is no OpenAPI document.** The endpoint list was recovered from the client WebAssembly
assemblies. Route literals live in the .NET **UTF-16** user-string heap, so a UTF-8 strings dump
finds nothing; page routes come from UTF-8 attribute blobs. Extract both encodings.

**The staging-container parameter is `blobPath`.** `stage-container-file/{container}/{path}` 404s
and a wrong query name 400s. The correct shape is
`releases/load/stage-container-file/stage-3040363?blobPath=metadata/ReleaseManifest.json`.

**Blob responses arrive as `byte[]`, not text.** `stage-container-file` returns
`application/octet-stream`, so `Invoke-WebRequest` surfaces `.Content` as a byte array. Piping that
straight into `ConvertFrom-Json` silently yields an array object and produces the misleading error
"Manifest does not contain a 'builds' array". `Invoke-ReleaseTrackerApi` decodes UTF-8 first — keep
that.

**`ConvertFrom-Json` emits a JSON array as one pipeline item.** So
`@(Invoke-ReleaseTrackerApi ...)` returns a 1-element array wrapping the real array, and the count
silently reads as 1. Assign first, then normalize with `ConvertTo-Array`.

**CVE routes take GUIDs, release routes take ints.** `cve/LoadCves/1` returns 400; get the GUID
from `cve/LoadReleases` first.

**`release-metadata/{id}` legitimately 404s** for releases whose metadata has not been generated —
including current ones. Treat it as optional, never as a failure. This is why the bulk sweep uses
`Invoke-ReleaseTrackerApiSafe` and reports skips instead of aborting.

**Two different tokens are involved.** The tracker token opens `release.dot.net/api`; the artifact,
staging-pipeline and feed links need an Azure DevOps token. Asking for one when you need the other
looks like an access failure but is not.

**Azure CLI is often not on PATH.** The MSI installs to
`%ProgramFiles%\Microsoft SDKs\Azure\CLI2\wbin\az.cmd` without refreshing PATH for running shells,
so a plain `Get-Command az` reports "not installed" even when the user is signed in. `Resolve-AzCli`
probes the known install locations — use it rather than assuming PATH.

**This skill is read-only by default.** `Invoke-ReleaseTrackerApi` refuses `releases/action/*`,
`schedules/action/*` and the CVE write endpoints unless `-AllowWrite` is passed. These operate on
live, in-flight .NET releases — never call them speculatively, and only with an explicit user
instruction naming the change.

## Output style

- Never invent a version, stage, BAR id, container name or URL — every value comes from the API.
- Preserve BAR build ids and stage container names verbatim; they identify exact builds.
- Always state the stage (`Released`, `Staging Done`, …) alongside the version.
- When a release has no `releaseDate`, say it is unreleased rather than showing a blank column.
