# Test results

Self-contained PowerShell test suite for the `dotnet-release-tracker` skill. No Pester required.

```powershell
# Everything (requires az login)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SkillTests.ps1

# Static + offline helper tests only
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SkillTests.ps1 -SkipIntegrationTests
```

The suite runs under `Set-StrictMode -Version Latest`, cleans up its own temp files, and exits
non-zero on failure.

## Latest run

| | Passed | Failed | Skipped | Total |
| --- | --- | --- | --- | --- |
| Live (`az login` active) | **48** | 0 | 0 | 48 |
| Offline (`-SkipIntegrationTests`) | **36** | 0 | 12 | 48 |

Environment: Windows PowerShell **5.1.26100.8875**, Windows **10.0.26200**, Azure CLI signed in to
the Microsoft corp tenant. Live run executed 2026-08-15 against 5 active releases (ids 155–159).

The 12 offline skips are exactly the tests that need the live API; they are reported as `SKIP`, not
silently passed.

## Coverage by group

### Static checks (15) — run always

Guard the skill's structure and hygiene, independent of the API.

| Test | Protects against |
| --- | --- |
| every script parses | Shipping a syntax error |
| test suite itself parses | A broken suite reporting false green |
| no hardcoded user profile paths | The skill only working for its author |
| no bearer tokens or secrets committed | Credential leakage |
| tenant resource GUID is not hardcoded | Baking in a tenant-specific id |
| SKILL.md has valid frontmatter with name and description | The skill failing to load |
| description carries the discovery triggers | The agent never invoking the skill |
| SKILL.md references only scripts that exist | Dangling script references |
| SKILL.md links resolve on disk | Broken doc links |
| every markdown relative link resolves | README/docs cross-links dying after a rename |
| README documents installation and limitations | An undocumented install |
| installation doc carries a limitations section | Silently dropping the limitations list |
| SKILL.md tells the agent to resolve its own folder | Hardcoded paths in agent usage |
| common helper is dot-source only (no side effects on load) | Network calls at import time |
| reference doc exists and is non-trivial | An empty endpoint catalog |

### Helper unit tests (20) — run always, no network

Cover the request plumbing, the read-only guard, the table projection and the path sanitizer.

| Test | Protects against |
| --- | --- |
| `ConvertTo-Array` flattens a `ConvertFrom-Json` array (count-of-1 regression) | 5 releases silently counting as 1 |
| `ConvertTo-Array` on null yields an empty array | `return @()` unrolling to `$null` |
| `ConvertTo-Array` on a scalar yields one element | `return @($scalar)` unrolling back to the scalar |
| read-only guard blocks every mutating endpoint | Mutating a live release |
| read-only guard permits read endpoints | An over-broad guard blocking normal reads |
| guard is not defeated by case or a leading slash | Trivial guard bypass |
| table handles an unreleased release (null date) | A bare `[datetime]` cast crashing on in-flight releases |
| table emits one row per release (collapse regression) | All releases collapsing into one row of arrays |
| table accepts a bare (unwrapped) release object | Single-result responses breaking |
| table formats a real date | Date/security columns not mapping through |
| table survives an unparseable date | A bad date throwing instead of passing through |
| helpers are StrictMode-clean against a sparse record | `PropertyNotFound` on releases missing fields |
| `Resolve-AzCli` returns a path or null without throwing | Hard failure when Azure CLI is absent |
| `Get-SafeFileName` neutralizes traversal in a server-supplied name | Path traversal via a release name |
| a traversing name cannot escape the output root | The sanitizer being correct in theory only |
| a blocked write is refused before any network call | The guard running after auth |
| every documented mutating endpoint is in the block list | Docs claiming protection that does not exist |
| `-Metadata` without `-OutputPath` is rejected | ~3 MB dumped into agent context |
| `-IncludeManifests` without `-OutputPath` is rejected | Same, via the bulk path |
| `Get-ReleaseTrackerFile` rejects a request with no blob selector | Silent no-op |

### Integration tests (13) — live API, skipped without access

| Test | Verifies |
| --- | --- |
| access probe reports availability without throwing | Runs offline too — the only integration test that passes without a token |
| active releases return the documented fields | The record shape in `reference/api-endpoints.md` is still accurate |
| unknown API paths are distinguishable from the SPA fallback | A 200 + `index.html` is not mistaken for success |
| staging blob is decoded to text, not `byte[]` (regression) | `application/octet-stream` handling |
| `-AsBytes` returns undecoded bytes that round-trip losslessly | Binary assets are not corrupted on save |
| `ReleaseManifest.json` exposes repo + `barBuildId` | The manifest shape `-BarIds` depends on |
| default run renders a release table | End-to-end table + links output |
| `-AsJson` emits parseable JSON with the expected envelope | Machine-readable contract |
| `-ReleaseId` narrows to a single release | Client-side filter |
| `-OutputPath` writes a JSON dump | Disk output path |
| `Get-ReleaseTrackerFile -BarIds` prints repo and BAR id | The `darc` workflow |
| `Get-ReleaseTrackerFile` rejects an unknown release with a helpful error | Useful failure messages |
| `-ReleaseId` falls back to `release-details` for a non-active release | The fallback path, and that its record shape matches `releases-view` |

## Bugs the suite caught

Three real defects in the skill (not test bugs), all Windows PowerShell 5.1 traps:

| Bug | Root cause | Fix |
| --- | --- | --- |
| `.Count` wrong for 0- and 1-element results | `return @()` unrolls to `$null`; `return @($x)` unrolls to `$x` | Comma operator: `return ,@(...)` |
| All 5 releases collapsed into one table row | The non-unrolling array from the fix above **cannot be piped** — `ConvertTo-Array $x \| ForEach-Object` hands the whole array to one iteration | Iterate with a `foreach` statement |
| StrictMode crash formatting dates | Inside `catch`, `$_` is rebound to the `ErrorRecord`, so `$_.releaseDate` throws | Bind `$release = $_` before the `try` |

The table-collapse bug is notable: the original single-release fixture could not detect it, so a
multi-release regression test was added.

## Issues found by independent review

An independent code review scored the skill **7.5/10**. All findings were fixed and covered by
tests:

| Severity | Finding | Resolution |
| --- | --- | --- |
| High | `Invoke-ReleaseTrackerApi` UTF-8-decoded **before** the `-Raw` check, silently corrupting binary blobs | Added `-AsBytes`; downloads use `WriteAllBytes`. Verified byte-identical output |
| Medium | `-Metadata` without `-OutputPath` dumped the ~3 MB drop manifest to console, contradicting `SKILL.md` | Now throws, mirroring the sibling script |
| Medium | `payload-tracking/*` documented as blocked but absent from the block list | Added, plus a test asserting docs and block list agree |
| Medium | Sanitizer test was tautological — it re-implemented the regex inline | Extracted `Get-SafeFileName` and tested it for real |
| Medium | Write-guard test was gated behind `Assert-Live` though the guard runs pre-auth | Moved to the offline group |
| Low | `-ReleaseId` fallback path was never exercised | Added a test; **this confirmed the `release-details` shape matches `releases-view`**, previously unverified |
| Nit | Projection assumed fully-populated records | `Get-JsonProperty` + a sparse-record StrictMode test |
| Nit | `$StageContainer` was not URL-encoded | Now encoded |
| Nit | `SKILL.md` implied `Get-ReleaseTrackerAccess` reports `NoToken` | Corrected |

## Manual verification

Checks run outside the suite, against live data:

| Check | Result |
| --- | --- |
| Default run | 5 active releases, correct table and links |
| `-Scope Everything` | 145 releases, 700 builds, 3 CVE releases, 0 errors, ~929 KB JSON |
| `-BarIds` for 11.0.0-rc.1 | `github.com/dotnet/dotnet` → BAR `325626`, commit `aedf05ae4b6c7f74f789e64a0a8d9d169414f04f` |
| `-Metadata -OutputPath` | 1,202,385 / 780 / 2,956,723 bytes — byte-identical before and after the binary fix, all still valid JSON |
| Write guard | All 18 mutating endpoints blocked; reads unaffected |
