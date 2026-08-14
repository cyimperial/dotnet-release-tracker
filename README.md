# dotnet-release-tracker

A GitHub Copilot CLI skill that reads the **Microsoft-internal .NET Release Tracker**
(`https://release.dot.net`) and reports releases, their build artifacts, NuGet feeds, staging
pipelines, BAR build ids and release manifests.

The tracker is a Blazor WebAssembly SPA with **no public API documentation**. This skill wraps the
API surface that was recovered from the client assemblies and verified live, so an agent can answer
"what's in flight?", "give me the artifacts/feed/staging pipeline", or "get the BAR ids for
`darc update-dependencies`" without guessing.

> **Read-only by default.** Every state-changing endpoint is blocked unless `-AllowWrite` is passed
> explicitly. These endpoints operate on live, in-flight .NET releases.

## What it can do

- List **active**, **all**, or **everything** the tracker knows about (145 releases, 700 builds at
  time of writing).
- Emit the artifacts URL, NuGet feed URL and staging pipeline URL per release.
- Pull `ReleaseManifest.json`, `ReleaseConfig.json` and `ReleaseDropManifest.json` out of a
  release's staging container — no storage account access or SAS token needed.
- Print the repo → **BAR build id** → commit table used by `darc update-dependencies`.
- Include CVE releases, schedules, build reports and per-release builds.
- Output terminal tables or machine-readable JSON.

## Installation

**Requirements:** Windows, Windows PowerShell 5.1, [Azure CLI](https://aka.ms/installazurecli), and
a Microsoft corporate tenant account with Release Tracker access.

```powershell
# 1. Clone or copy the skill into your user skills folder
$dest = Join-Path $env:USERPROFILE '.copilot\skills\dotnet-release-tracker'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path .\dotnet-release-tracker\* -Destination $dest -Recurse -Force

# 2. Sign in to the Microsoft corp tenant
az login

# 3. Verify the install (36 offline tests, no network needed)
powershell -NoProfile -ExecutionPolicy Bypass `
    -File "$dest\tests\Invoke-SkillTests.ps1" -SkipIntegrationTests
```

A healthy install prints `Passed: 36   Failed: 0   Skipped: 12`. Drop
`-SkipIntegrationTests` once you are signed in to run all 48 tests against the live API.

Copilot CLI discovers the skill automatically from `~/.copilot/skills/`; no registration step is
required. Ask it something like *"what .NET releases are active?"* to confirm.

Full walkthrough, verification steps, troubleshooting and **limitations**:
[docs/installation.md](docs/installation.md).

## Quick start

Execution policy is commonly `Restricted`, so the bypass is required:

```powershell
$skill = Join-Path $env:USERPROFILE '.copilot\skills\dotnet-release-tracker'

# Active releases (default) - table plus artifact/feed/staging links
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\Get-ReleaseTrackerData.ps1"

# Everything, dumped to disk as JSON
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\Get-ReleaseTrackerData.ps1" `
    -Scope Everything -OutputPath .\tracker-dump

# BAR build ids for darc update-dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\Get-ReleaseTrackerFile.ps1" `
    -Release 11.0.0-rc.1 -BarIds

# All three metadata manifests (-OutputPath is required; they total ~4 MB)
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\Get-ReleaseTrackerFile.ps1" `
    -Release 11.0.0-rc.1 -Metadata -OutputPath .\rc1
```

Sample output:

```
=== Releases (5) - scope: Active ===

 Id Name             Type Stage        Runtime                Sdk                      Released   Security Builds
 -- ----             ---- -----        -------                ---                      --------   -------- ------
159 11.0.0-rc.1      sts  Staging Done 11.0.0-rc.1.26404.101  11.0.100-rc.1.26404.101                False      1
158 10.0.11          lts  Released     10.0.11                10.0.400, 10.0.303       2026-08-11    False      4
```

## Layout

| Path | Purpose |
| --- | --- |
| `SKILL.md` | Agent-facing contract: facts, workflow, output style, hard-won API details |
| `scripts/Get-ReleaseTrackerData.ps1` | Releases, builds, links, CVEs, schedules — tables or JSON |
| `scripts/Get-ReleaseTrackerFile.ps1` | Staging-container blobs, metadata manifests, BAR ids |
| `scripts/ReleaseTracker.Common.ps1` | Shared auth, request plumbing, read-only guard — dot-sourced |
| `reference/api-endpoints.md` | Full verified endpoint catalog, record fields, blob paths |
| `tests/Invoke-SkillTests.ps1` | 48-test self-contained suite (no Pester required) |
| `docs/installation.md` | Install, verification, troubleshooting, limitations |
| `docs/test-result.md` | Latest verified test run and what each group covers |

## Script reference

### `Get-ReleaseTrackerData.ps1`

| Switch | Effect |
| --- | --- |
| `-Scope Active\|All\|Everything` | Release set. `Everything` implies builds + config + CVEs + schedules |
| `-ReleaseId 159` | Restrict to specific release ids (falls back to `release-details` for non-active) |
| `-IncludeBuilds` / `-IncludeReports` | Per-release builds and build reports |
| `-IncludeConfig` / `-IncludeCves` / `-IncludeSchedules` | Extra datasets |
| `-IncludeManifests` | Download staging manifests — **requires `-OutputPath`** |
| `-OutputPath` / `-AsJson` | Write a JSON dump / emit JSON instead of tables |

### `Get-ReleaseTrackerFile.ps1`

| Switch | Effect |
| --- | --- |
| `-Release` | Name (`11.0.0-rc.1`), numeric id, or substring |
| `-StageContainer` | Use a container (`stage-3040363`) directly |
| `-BlobPath` | Any path inside the container |
| `-Metadata` | The three `metadata/*.json` files — **requires `-OutputPath`** |
| `-BarIds` | Print the repo → BAR id → commit table |
| `-OutputPath` | Save to disk (written as raw bytes, so binary assets are not corrupted) |

## Testing

```powershell
# Everything (needs az login)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SkillTests.ps1

# Static + offline helper tests only
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SkillTests.ps1 -SkipIntegrationTests
```

Latest verified run: **48 passed, 0 failed** live; **36 passed, 12 skipped** offline. Details and
per-group coverage in [docs/test-result.md](docs/test-result.md).

## Limitations

This skill is Microsoft-internal, Windows-only, read-only by default, and its endpoint catalog is
reverse-engineered rather than contractual. See
[docs/installation.md#limitations](docs/installation.md#limitations) for the full list.
