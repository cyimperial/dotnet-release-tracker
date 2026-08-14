# Release Tracker API reference

Base URI: `https://release.dot.net/api`
Auth: `Authorization: Bearer <token>` for the Entra ID app registration named **ReleaseTracker**
(resolve its `api://` SPN at runtime; do not hardcode the GUID).

The site itself is a Blazor WebAssembly SPA. Every unknown path returns the SPA's `index.html`
with **HTTP 200**, so a 200 alone does not prove an endpoint exists — check that the body is JSON.
There is no Swagger/OpenAPI document; the endpoint list below was recovered from the client
assemblies and then verified against the live API.

## Read endpoints (verified)

| Endpoint | Returns |
| --- | --- |
| `releases/load/releases-view/active` | Releases in flight |
| `releases/load/releases-view/all` | Every release |
| `releases/load/releases/dropdown` | Compact release list for pickers |
| `releases/load/configuration` | App configuration object |
| `releases/load/release-details/Id/{releaseId}` | One release |
| `releases/load/release-details/BuildId/{buildId}` | Release owning a build |
| `releases/load/builds/{releaseId}` | Builds in a release |
| `releases/load/build-report/{buildId}` | Full build report |
| `releases/load/release-config-preview/{releaseId}` | Pending release config |
| `releases/load/release-config-preview/snapshot/{releaseId}` | Snapshotted release config |
| `releases/load/release-metadata/{releaseId}` | Metadata — **404s** until generated |
| `releases/load/stage-container-file/{container}?blobPath={path}` | Raw blob from the staging container |
| `cve/LoadReleases` | CVE releases |
| `cve/LoadLookups` | CVE lookup tables |
| `cve/LoadReleaseById/{guid}` | One CVE release |
| `cve/LoadCveById/{guid}` | One CVE |
| `cve/LoadCves/{guid}` | CVEs for a CVE release |
| `cve/LoadCveActivityLogs/{guid}` | CVE activity log |
| `cve/LoadProductVersion/{guid}` | Product versions for a CVE |
| `schedules/load/schedules` | All schedules |
| `schedules/load/schedules/{id}` | One schedule |
| `schedules/load/activities/{id}` | Activities for a schedule |
| `schedules/load/ScheduleRelease` | Schedule/release mapping |

CVE ids are **GUIDs**; release ids are **ints**. Passing an int to a `cve/Load*` route returns 400.

## Release record fields

`releaseId`, `name`, `type` (`lts`/`sts`), `stage`, `runtimeVersion`, `sdkVersion`, `releaseDate`,
`isSecurity`, `buildCount`, `buildId`, `buildStageContainer`, `buildRootBarIds`, `buildCreateDate`,
`buildStage`, `buildFeedUrl`, `buildArtifactsUrl`, `buildStagingUrl`.

`buildRootBarIds` is a comma-separated string. `releaseDate` is null until the release ships.

## Staging container blob paths

`buildStageContainer` looks like `stage-3040363` — the digits are the Azure DevOps build id, so
`buildArtifactsUrl` and `buildStagingUrl` point at that same build.

| Path | Contents |
| --- | --- |
| `metadata/ReleaseManifest.json` | Per-repo builds, each with `repo`, `barBuildId`, `commit` |
| `metadata/ReleaseConfig.json` | Release configuration |
| `metadata/ReleaseDropManifest.json` | Full drop contents (multi-MB) |
| `status/job-runs/...` | Publishing job run status |
| `status/report-data/...` | Report data |
| `assets/Shipping/assets/Sdk/...` | Shipping SDK archives |

`ReleaseManifest.json` has a top-level `builds` array; each entry carries `repo`, `barBuildId` and
`commit`. Those `barBuildId` values are what `darc update-dependencies --id <barBuildId>` takes.

Blob responses are served as `application/octet-stream`, so PowerShell exposes them as `byte[]`.
Decode UTF-8 before parsing.

## Mutating endpoints — do not call without explicit user instruction

`releases/action/import-by-release-name`, `releases/action/update-release-metadata/{id}`,
`releases/action/update-release-properties/{id}`, all `schedules/action/*`, and the CVE writes
(`AddCve`, `UpdateCve`, `DeleteCve`, `CreateRelease`, `UpdateRelease`, `DeleteRelease`,
`ApproveRelease`, `UnlockRelease`, `MarkFinal`, `RenameCveId`, `DeleteCommit`,
`DeleteProductVersion`, `GenerateCveJson`, `ReviewCveJson`).

`payload-tracking/analyze`, `payload-tracking/analyze-batch` and
`payload-tracking/compare-manifests` are POSTs that only compute, but they are expensive.

`Invoke-ReleaseTrackerApi` blocks all of the above unless `-AllowWrite` is passed.

## Downstream resources

`buildArtifactsUrl`, `buildStagingUrl` and `buildFeedUrl` point at `dev.azure.com/dnceng/internal`
and `pkgs.dev.azure.com/dnceng/internal`. Those need an **Azure DevOps** token
(resource `499b84ac-1321-427f-aa17-267ca6975798`), not the Release Tracker token.

Feed URL shape:
`https://pkgs.dev.azure.com/dnceng/internal/_packaging/<sdkVersion>-shipping/nuget/v3/index.json`

## Public fallback

Outside the Microsoft tenant, use the public metadata instead — shipped releases only, no staging
containers, no unshipped previews:
`https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json`
