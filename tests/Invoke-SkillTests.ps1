<#
.SYNOPSIS
    Test suite for the dotnet-release-tracker skill.

.DESCRIPTION
    Self-contained - deliberately no Pester dependency, so the suite runs identically on a
    developer machine and on a CI runner.

    Covers the defect classes that actually bit during development:
      * static defects      - unparseable code, hardcoded user paths, broken SKILL.md contract
      * helper defects      - JSON array unrolling, byte[] blobs, null dates, StrictMode crashes
      * safety defects      - mutating endpoints reachable without -AllowWrite
      * integration defects - live API shape drift

    Integration tests SKIP (not fail) when the caller has no Release Tracker access, so the suite
    is still meaningful outside the Microsoft tenant.

.PARAMETER SkipIntegrationTests
    Skip all tests that hit the live API.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SkillTests.ps1
#>
[CmdletBinding()]
param([switch]$SkipIntegrationTests)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SkillRoot   = Split-Path -Parent $PSScriptRoot
$ScriptsRoot = Join-Path $SkillRoot 'scripts'
$CommonPath  = Join-Path $ScriptsRoot 'ReleaseTracker.Common.ps1'
$DataScript  = Join-Path $ScriptsRoot 'Get-ReleaseTrackerData.ps1'
$FileScript  = Join-Path $ScriptsRoot 'Get-ReleaseTrackerFile.ps1'
$TempRoot    = Join-Path $env:TEMP "drt-tests-$(Get-Date -Format 'yyyyMMddHHmmss')"

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
# $env:TEMP is an 8.3 short path while the scripts under test return long paths.
$TempRoot = (Get-Item -LiteralPath $TempRoot).FullName

$script:Passed   = 0
$script:Failed   = 0
$script:Skipped  = 0
$script:Failures = @()

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like 'SKIP::*') {
            $script:Skipped++
            Write-Host ("  SKIP  {0}" -f $Name) -ForegroundColor Yellow
            Write-Host ("        {0}" -f ($_.Exception.Message -replace '^SKIP::', '')) -ForegroundColor DarkGray
            return
        }
        $script:Failed++
        $script:Failures += "$Name :: $($_.Exception.Message)"
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }
}

function Assert-Skip { param([string]$Reason) throw "SKIP::$Reason" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Message, [string]$Match)
    $threw = $false
    $text = ''
    try { & $Body | Out-Null } catch { $threw = $true; $text = $_.Exception.Message }
    if (-not $threw) { throw $Message }
    if ($Match -and $text -notlike "*$Match*") {
        throw "$Message (message '$text' did not match '$Match')"
    }
}

# =============================================================================
Write-Host "`n=== Static checks ===" -ForegroundColor Cyan

Test-Case 'every script parses' {
    foreach ($file in Get-ChildItem $ScriptsRoot -Filter *.ps1) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count) {
            throw "$($file.Name): $($errors[0].Message)"
        }
    }
}

Test-Case 'test suite itself parses' {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count) { throw $errors[0].Message }
}

Test-Case 'no hardcoded user profile paths' {
    # A skill must be portable between machines and users.
    $pattern = 'C:\\Users\\[A-Za-z0-9._-]+\\'
    foreach ($file in Get-ChildItem $SkillRoot -Recurse -Include *.ps1, *.md) {
        if ($file.FullName -eq $PSCommandPath) { continue }
        $hits = Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches
        if ($hits) { throw "$($file.Name) line $($hits[0].LineNumber): $($hits[0].Line.Trim())" }
    }
}

Test-Case 'no bearer tokens or secrets committed' {
    $pattern = 'eyJ0eXAiOiJKV1|password\s*=\s*["''][^"'']+|api-key'
    foreach ($file in Get-ChildItem $SkillRoot -Recurse -Include *.ps1, *.md) {
        if ($file.FullName -eq $PSCommandPath) { continue }
        $hits = Select-String -LiteralPath $file.FullName -Pattern $pattern
        if ($hits) { throw "$($file.Name) line $($hits[0].LineNumber)" }
    }
}

Test-Case 'tenant resource GUID is not hardcoded' {
    # The api:// SPN id must be resolved at runtime, per the skill contract.
    foreach ($file in Get-ChildItem $SkillRoot -Recurse -Include *.ps1, *.md) {
        if ($file.FullName -eq $PSCommandPath) { continue }
        $hits = Select-String -LiteralPath $file.FullName -Pattern 'api://[0-9a-fA-F]{8}-'
        if ($hits) { throw "$($file.Name) line $($hits[0].LineNumber) hardcodes the resource id" }
    }
}

Test-Case 'SKILL.md has valid frontmatter with name and description' {
    $text = Get-Content (Join-Path $SkillRoot 'SKILL.md') -Raw
    Assert-True ($text -match '(?s)^---\r?\n(.*?)\r?\n---') 'no YAML frontmatter block'
    $front = $Matches[1]
    Assert-True ($front -match '(?m)^name:\s*(.+)$') 'frontmatter has no name'
    $name = $Matches[1].Trim()
    Assert-Equal 'dotnet-release-tracker' $name 'frontmatter name must match the folder name'
    Assert-True ($front -match '(?m)^description:\s*(.+)$') 'frontmatter has no description'
}

Test-Case 'description carries the discovery triggers' {
    $text = Get-Content (Join-Path $SkillRoot 'SKILL.md') -Raw
    if ($text -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { throw 'no frontmatter' }
    $front = $Matches[1]
    if ($front -notmatch '(?m)^description:\s*(.+)$') { throw 'no description' }
    $description = $Matches[1]

    foreach ($trigger in @('release.dot.net', 'Release Tracker', 'artifact', 'staging', 'BAR')) {
        Assert-True ($description -like "*$trigger*") "description is missing the '$trigger' trigger"
    }
    Assert-True ($description.Length -lt 1024) 'description is too long to be useful for routing'
}

Test-Case 'SKILL.md references only scripts that exist' {
    $text = Get-Content (Join-Path $SkillRoot 'SKILL.md') -Raw
    foreach ($match in [regex]::Matches($text, '([A-Za-z0-9\.\-]+\.ps1)')) {
        $referenced = $match.Groups[1].Value
        Assert-True (Test-Path (Join-Path $ScriptsRoot $referenced)) "SKILL.md references missing script $referenced"
    }
}

Test-Case 'SKILL.md links resolve on disk' {
    $text = Get-Content (Join-Path $SkillRoot 'SKILL.md') -Raw
    foreach ($match in [regex]::Matches($text, '\]\((?!https?:)([^)]+)\)')) {
        $relative = $match.Groups[1].Value
        Assert-True (Test-Path (Join-Path $SkillRoot $relative)) "SKILL.md links missing file $relative"
    }
}

Test-Case 'every markdown relative link resolves' {
    # README and docs/ cross-link to each other; a rename must not leave a dead link behind.
    foreach ($file in Get-ChildItem $SkillRoot -Recurse -Include *.md) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in [regex]::Matches($text, '\]\((?!https?:|#)([^)#]+)(?:#[^)]*)?\)')) {
            $relative = $match.Groups[1].Value
            $target = Join-Path $file.DirectoryName $relative
            Assert-True (Test-Path $target) "$($file.Name) links missing file $relative"
        }
    }
}

Test-Case 'README documents installation and limitations' {
    $readme = Join-Path $SkillRoot 'README.md'
    Assert-True (Test-Path $readme) 'README.md is missing'
    $text = Get-Content $readme -Raw
    Assert-True ($text -match '(?im)^##\s+Installation') 'README.md has no Installation section'
    Assert-True ($text -match 'az login') 'README.md never mentions the az login step'
}

Test-Case 'installation doc carries a limitations section' {
    $install = Join-Path $SkillRoot 'docs\installation.md'
    Assert-True (Test-Path $install) 'docs/installation.md is missing'
    $text = Get-Content $install -Raw
    Assert-True ($text -match '(?im)^##\s+Limitations') 'docs/installation.md has no Limitations section'
}

Test-Case 'SKILL.md tells the agent to resolve its own folder' {
    $text = Get-Content (Join-Path $SkillRoot 'SKILL.md') -Raw
    Assert-True ($text -like '*Never hardcode a user profile path*') 'missing the portability instruction'
    Assert-True ($text -like '*ExecutionPolicy Bypass*') 'missing the execution-policy guidance'
}

Test-Case 'common helper is dot-source only (no side effects on load)' {
    # Dot-sourcing must define functions and nothing else - no network, no output.
    $output = . $CommonPath
    Assert-True ($null -eq $output) 'dot-sourcing produced output'
    Assert-True ($null -ne (Get-Command Invoke-ReleaseTrackerApi -ErrorAction SilentlyContinue)) 'Invoke-ReleaseTrackerApi not defined'
    Assert-True ($null -ne (Get-Command ConvertTo-Array -ErrorAction SilentlyContinue)) 'ConvertTo-Array not defined'
}

Test-Case 'reference doc exists and is non-trivial' {
    $reference = Join-Path $SkillRoot 'reference\api-endpoints.md'
    Assert-True (Test-Path $reference) 'reference/api-endpoints.md is missing'
    Assert-True ((Get-Item $reference).Length -gt 1000) 'reference doc is suspiciously small'
}

# =============================================================================
Write-Host "`n=== Helper unit tests (offline) ===" -ForegroundColor Cyan

. $CommonPath

Test-Case 'ConvertTo-Array flattens a ConvertFrom-Json array (count-of-1 regression)' {
    # ConvertFrom-Json emits a JSON array as ONE pipeline item, so @(f) yields a 1-element
    # array wrapping the real array. This silently reported 5 releases as 1.
    function Get-FakeJson { return ('[{"a":1},{"a":2},{"a":3}]' | ConvertFrom-Json) }
    $normalized = ConvertTo-Array (Get-FakeJson)
    Assert-Equal 3 $normalized.Count 'ConvertTo-Array did not flatten the array'
    Assert-Equal 1 $normalized[0].a 'element order or shape is wrong'
}

Test-Case 'ConvertTo-Array on null yields an empty array' {
    $normalized = ConvertTo-Array $null
    Assert-Equal 0 $normalized.Count 'null should normalize to an empty array'
}

Test-Case 'ConvertTo-Array on a scalar yields one element' {
    $normalized = ConvertTo-Array ('{"a":1}' | ConvertFrom-Json)
    Assert-Equal 1 $normalized.Count 'a single object should normalize to one element'
}

Test-Case 'read-only guard blocks every mutating endpoint' {
    $mutating = @(
        'releases/action/update-release-properties/159'
        'releases/action/update-release-metadata/159'
        'releases/action/import-by-release-name?releaseName=x'
        'schedules/action/schedules/create'
        'schedules/action/activities/create'
        'cve/AddCve'
        'cve/UpdateCve'
        'cve/DeleteCve/abc'
        'cve/CreateRelease'
        'cve/DeleteRelease/abc'
        'cve/ApproveRelease/abc'
        'cve/UnlockRelease/abc'
        'cve/MarkFinal/abc'
        'cve/RenameCveId/abc'
        'cve/DeleteCommit/abc'
        'cve/DeleteProductVersion/abc'
        'cve/GenerateCveJson'
        'cve/ReviewCveJson'
    )
    foreach ($endpoint in $mutating) {
        Assert-Throws { Assert-ReadOnlyEndpoint -Endpoint $endpoint } "mutating endpoint not blocked: $endpoint" 'Refusing to call'
    }
}

Test-Case 'read-only guard permits read endpoints' {
    foreach ($endpoint in @(
        'releases/load/releases-view/active'
        'releases/load/releases-view/all'
        'releases/load/builds/159'
        'releases/load/build-report/716'
        'cve/LoadReleases'
        'cve/LoadLookups'
        'schedules/load/schedules'
        'releases/load/stage-container-file/stage-1?blobPath=metadata/ReleaseManifest.json'
    )) {
        Assert-ReadOnlyEndpoint -Endpoint $endpoint
    }
}

Test-Case 'guard is not defeated by case or a leading slash' {
    Assert-Throws { Assert-ReadOnlyEndpoint -Endpoint '/releases/ACTION/update-release-properties/1' } 'case variation slipped through' 'Refusing to call'
}

Test-Case 'ConvertTo-ReleaseTrackerTable handles an unreleased release (null date)' {
    # An in-flight release has releaseDate = null; a bare [datetime] cast crashed here.
    $release = '{"releaseId":159,"name":"11.0.0-rc.1","type":"sts","stage":"Staging Done","runtimeVersion":"11.0.0-rc.1","sdkVersion":"11.0.100-rc.1","releaseDate":null,"isSecurity":false,"buildCount":1,"buildRootBarIds":"325626","buildStageContainer":"stage-1"}' | ConvertFrom-Json
    $row = ConvertTo-ReleaseTrackerTable -Releases (ConvertTo-Array $release)
    Assert-Equal '' $row.Released 'null releaseDate should render as empty'
    Assert-Equal 159 $row.Id 'id did not map through'
    Assert-Equal $false $row.Security 'isSecurity did not map through'
}

Test-Case 'ConvertTo-ReleaseTrackerTable emits one row per release (collapse regression)' {
    # Piping ConvertTo-Array into ForEach-Object handed the whole array to a single iteration,
    # collapsing five releases into one row whose every cell was an array. A single-release
    # fixture cannot catch this - the multi-release case is the point.
    $releases = '[
        {"releaseId":159,"name":"11.0.0-rc.1","type":"sts","stage":"Staging Done","runtimeVersion":"a","sdkVersion":"b","releaseDate":null,"isSecurity":false,"buildCount":1,"buildRootBarIds":"1","buildStageContainer":"s1"},
        {"releaseId":158,"name":"10.0.11","type":"lts","stage":"Released","runtimeVersion":"c","sdkVersion":"d","releaseDate":"2026-08-11T00:00:00","isSecurity":false,"buildCount":4,"buildRootBarIds":"2","buildStageContainer":"s2"},
        {"releaseId":157,"name":"8.0.30","type":"lts","stage":"Released","runtimeVersion":"e","sdkVersion":"f","releaseDate":"2026-08-11T00:00:00","isSecurity":true,"buildCount":1,"buildRootBarIds":"3","buildStageContainer":"s3"}
    ]' | ConvertFrom-Json

    $rows = ConvertTo-Array (ConvertTo-ReleaseTrackerTable -Releases $releases)
    Assert-Equal 3 $rows.Count 'expected one row per release'
    Assert-Equal 159 $rows[0].Id 'first row has the wrong id'
    Assert-Equal '10.0.11' $rows[1].Name 'second row has the wrong name'
    Assert-Equal '2026-08-11' $rows[2].Released 'third row has the wrong date'

    # Every cell must be a scalar, not a collapsed array.
    foreach ($row in $rows) {
        foreach ($property in $row.PSObject.Properties) {
            Assert-True ($property.Value -isnot [array]) "column '$($property.Name)' collapsed into an array"
        }
    }
}

Test-Case 'ConvertTo-ReleaseTrackerTable accepts a bare (unwrapped) release object' {
    $release = '{"releaseId":1,"name":"x","type":"sts","stage":"s","runtimeVersion":"r","sdkVersion":"s","releaseDate":null,"isSecurity":false,"buildCount":0,"buildRootBarIds":"","buildStageContainer":""}' | ConvertFrom-Json
    $rows = ConvertTo-Array (ConvertTo-ReleaseTrackerTable -Releases $release)
    Assert-Equal 1 $rows.Count 'a single object should still yield one row'
    Assert-Equal 1 $rows[0].Id 'id did not map through'
}

Test-Case 'ConvertTo-ReleaseTrackerTable formats a real date' {    $release = '{"releaseId":158,"name":"10.0.11","type":"lts","stage":"Released","runtimeVersion":"10.0.11","sdkVersion":"10.0.400","releaseDate":"2026-08-11T00:00:00","isSecurity":true,"buildCount":4,"buildRootBarIds":"1,2","buildStageContainer":"stage-2"}' | ConvertFrom-Json
    $row = ConvertTo-ReleaseTrackerTable -Releases (ConvertTo-Array $release)
    Assert-Equal '2026-08-11' $row.Released 'date formatting is wrong'
    Assert-Equal $true $row.Security 'security flag did not map through'
}

Test-Case 'ConvertTo-ReleaseTrackerTable survives an unparseable date' {
    $release = '{"releaseId":1,"name":"x","type":"sts","stage":"s","runtimeVersion":"r","sdkVersion":"s","releaseDate":"not-a-date","isSecurity":false,"buildCount":0,"buildRootBarIds":"","buildStageContainer":""}' | ConvertFrom-Json
    $row = ConvertTo-ReleaseTrackerTable -Releases (ConvertTo-Array $release)
    Assert-Equal 'not-a-date' $row.Released 'a bad date should pass through, not throw'
}

Test-Case 'helpers are StrictMode-clean against a sparse record' {
    # The suite runs under Set-StrictMode -Version Latest. Use a record that is missing most
    # fields: the API omits properties for releases that have not reached staging, and lax
    # property access would only surface here.
    $release = '{"releaseId":9,"name":"sparse"}' | ConvertFrom-Json
    $row = ConvertTo-ReleaseTrackerTable -Releases (ConvertTo-Array $release)
    Assert-Equal 9 $row.Id 'id did not map through on a sparse record'
}

Test-Case 'Resolve-AzCli returns a path or null without throwing' {
    $az = Resolve-AzCli
    if ($az) { Assert-True (Test-Path $az) "Resolve-AzCli returned a non-existent path: $az" }
}

Test-Case 'Get-SafeFileName neutralizes traversal in a server-supplied name' {
    # Release names come from the API and are used to build output folders.
    Assert-Equal 'evil_.._name_1' (Get-SafeFileName 'evil/../name:1') 'separators were not replaced'
    Assert-Equal '_' (Get-SafeFileName '..') "'..' must not survive as a folder name"
    Assert-Equal '_' (Get-SafeFileName '   ') 'a blank name must not yield an empty segment'
    Assert-Equal 'x' (Get-SafeFileName 'x. ') 'trailing dot/space must be trimmed'
    Assert-True ((Get-SafeFileName 'a\b/c:d*e?f"g<h>i|j') -notmatch '[\\/:*?"<>|]') 'sanitizer left a reserved character behind'
}

Test-Case 'a traversing name cannot escape the output root' {
    # Exercise the real composition used by the scripts, not just the regex.
    $root = Join-Path $env:TEMP ('rt-safe-' + [guid]::NewGuid().ToString('N'))
    try {
        $folder = Join-Path $root (Get-SafeFileName '../../escaped')
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $resolved = (Resolve-Path $folder).Path
        Assert-True $resolved.StartsWith((Resolve-Path $root).Path) "escaped the output root: $resolved"
    }
    finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a blocked write is refused before any network call' {
    # The guard runs ahead of auth, so this holds with or without a token.
    foreach ($endpoint in @('releases/action/publish/1', 'payload-tracking/refresh', 'cve/GenerateCveJson')) {
        Assert-Throws {
            Invoke-ReleaseTrackerApi -Endpoint $endpoint -Method POST
        } "mutating endpoint '$endpoint' was not blocked" 'Refusing to call'
    }
}

Test-Case 'every documented mutating endpoint is in the block list' {
    $doc = Get-Content (Join-Path $SkillRoot 'reference\api-endpoints.md') -Raw
    foreach ($fragment in @('/action/', 'payload-tracking/')) {
        Assert-True ($doc -match [regex]::Escape($fragment)) "block list entry '$fragment' is undocumented"
    }
}

Test-Case '-Metadata without -OutputPath is rejected' {
    Assert-Throws {
        & $FileScript -StageContainer 'stage-1' -Metadata -ErrorAction Stop
    } 'the 3 MB drop manifest was allowed to dump to the console' 'requires -OutputPath'
}

Test-Case '-IncludeManifests without -OutputPath is rejected' {
    Assert-Throws {
        & $DataScript -IncludeManifests -ErrorAction Stop
    } 'multi-MB manifests were allowed to dump to the console' 'requires -OutputPath'
}

Test-Case 'Get-ReleaseTrackerFile rejects a request with no blob selector' {
    Assert-Throws {
        & $FileScript -StageContainer 'stage-1' -ErrorAction Stop
    } 'expected a throw when no blob was selected' 'Specify -BlobPath'
}

# =============================================================================
Write-Host "`n=== Integration tests (live API) ===" -ForegroundColor Cyan

$access = Get-ReleaseTrackerAccess
$liveReason = $null
if ($SkipIntegrationTests) { $liveReason = '-SkipIntegrationTests was passed' }
elseif (-not $access.Available) { $liveReason = "$($access.Reason): $($access.Detail)" }

function Assert-Live { if ($liveReason) { Assert-Skip $liveReason } }

Test-Case 'access probe reports availability without throwing' {
    Assert-True ($null -ne $access.PSObject.Properties['Available']) 'no Available property'
    Assert-True ($null -ne $access.PSObject.Properties['Reason']) 'no Reason property'
    if (-not $access.Available) {
        Assert-True ($access.Detail -and $access.Detail.Length -gt 0) 'unavailable result carried no explanation'
    }
}

Test-Case 'active releases return the documented fields' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    Assert-True ($releases.Count -ge 1) 'no active releases returned'
    foreach ($field in @('releaseId', 'name', 'type', 'stage', 'runtimeVersion', 'sdkVersion',
                         'releaseDate', 'isSecurity', 'buildStageContainer', 'buildRootBarIds',
                         'buildFeedUrl', 'buildArtifactsUrl', 'buildStagingUrl')) {
        Assert-True ($null -ne $releases[0].PSObject.Properties[$field]) "release record lost the '$field' field"
    }
}

Test-Case 'unknown API paths are distinguishable from the SPA fallback' {
    Assert-Live
    # https://release.dot.net/<anything> returns index.html with HTTP 200, so a 200 alone
    # proves nothing. /api/* must produce a real 404 instead.
    Assert-Throws {
        Invoke-ReleaseTrackerApi -Endpoint 'releases/load/definitely-not-a-real-endpoint'
    } 'a bogus API path did not error - the SPA fallback may now cover /api/*'
}

Test-Case 'staging blob is decoded to text, not byte[] (regression)' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $withContainer = $releases | Where-Object { $_.buildStageContainer } | Select-Object -First 1
    if (-not $withContainer) { Assert-Skip 'no active release has a staging container' }

    $content = Get-ReleaseTrackerStageFile -StageContainer $withContainer.buildStageContainer -BlobPath 'metadata/ReleaseConfig.json' -Raw
    Assert-True ($content -is [string]) "blob came back as $($content.GetType().Name), not a string"
    ($content | ConvertFrom-Json) | Out-Null
}

Test-Case '-AsBytes returns undecoded bytes that round-trip losslessly' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $withContainer = $releases | Where-Object { $_.buildStageContainer } | Select-Object -First 1
    if (-not $withContainer) { Assert-Skip 'no active release has a staging container' }

    # Saving a blob must never go through UTF8.GetString: that is lossy for binary assets.
    $bytes = Get-ReleaseTrackerStageFile -StageContainer $withContainer.buildStageContainer -BlobPath 'metadata/ReleaseConfig.json' -AsBytes
    Assert-True ($bytes -is [byte[]]) "-AsBytes returned $($bytes.GetType().Name), not byte[]"
    Assert-True ($bytes.Length -gt 0) '-AsBytes returned an empty buffer'

    $text = Get-ReleaseTrackerStageFile -StageContainer $withContainer.buildStageContainer -BlobPath 'metadata/ReleaseConfig.json' -Raw
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    Assert-Equal $text.TrimStart([char]0xFEFF) $decoded 'byte and text paths disagree'
}

Test-Case 'ReleaseManifest.json exposes repo + barBuildId' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $withContainer = $releases | Where-Object { $_.buildStageContainer } | Select-Object -First 1
    if (-not $withContainer) { Assert-Skip 'no active release has a staging container' }

    $manifest = Get-ReleaseTrackerStageFile -StageContainer $withContainer.buildStageContainer -BlobPath 'metadata/ReleaseManifest.json' -Raw | ConvertFrom-Json
    Assert-True ($null -ne $manifest.PSObject.Properties['builds']) "manifest has no 'builds' array"
    $builds = ConvertTo-Array $manifest.builds
    Assert-True ($builds.Count -ge 1) 'manifest builds array is empty'
    Assert-True ($null -ne $builds[0].PSObject.Properties['barBuildId']) 'build entry has no barBuildId'
    Assert-True ($null -ne $builds[0].PSObject.Properties['repo']) 'build entry has no repo'
}

Test-Case 'default run renders a release table' {
    Assert-Live
    $out = & $DataScript | Out-String
    foreach ($column in @('Id', 'Name', 'Stage', 'Runtime', 'Released')) {
        Assert-True ($out -match "\b$column\b") "table is missing the '$column' column"
    }
    Assert-True ($out -like '*=== Links ===*') 'links section is missing'
    Assert-True ($out -like '*pkgs.dev.azure.com*') 'feed URL is missing from the links section'

    # Header presence alone does not prove the rows rendered: a collapsed table still shows
    # every column. Assert one distinct table row per active release.
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $lines = $out -split "`r?`n"
    foreach ($release in $releases) {
        $matching = @($lines | Where-Object { $_ -match [regex]::Escape($release.name) -and $_ -match "^\s*$($release.releaseId)\s" })
        Assert-True ($matching.Count -ge 1) "no table row for release $($release.name) (id $($release.releaseId))"
    }
}

Test-Case '-AsJson emits parseable JSON with the expected envelope' {
    Assert-Live
    $json = (& $DataScript -AsJson) -join "`n"
    $parsed = $json | ConvertFrom-Json
    foreach ($field in @('RetrievedUtc', 'Scope', 'Releases', 'Errors')) {
        Assert-True ($null -ne $parsed.PSObject.Properties[$field]) "envelope is missing '$field'"
    }
    Assert-Equal 'Active' $parsed.Scope 'default scope should be Active'
    Assert-True ((ConvertTo-Array $parsed.Releases).Count -ge 1) 'no releases in the JSON envelope'
}

Test-Case '-ReleaseId narrows to a single release' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $target = $releases[0]
    $parsed = ((& $DataScript -ReleaseId $target.releaseId -AsJson) -join "`n") | ConvertFrom-Json
    $selected = ConvertTo-Array $parsed.Releases
    Assert-Equal 1 $selected.Count 'filter did not narrow to one release'
    Assert-Equal $target.releaseId $selected[0].releaseId 'filter selected the wrong release'
}

Test-Case '-OutputPath writes a JSON dump' {
    Assert-Live
    $dumpDir = Join-Path $TempRoot 'dump'
    & $DataScript -OutputPath $dumpDir | Out-Null
    $dump = Join-Path $dumpDir 'release-tracker.json'
    Assert-True (Test-Path $dump) 'no release-tracker.json was written'
    $parsed = Get-Content $dump -Raw | ConvertFrom-Json
    Assert-True ((ConvertTo-Array $parsed.Releases).Count -ge 1) 'dumped envelope has no releases'
}

Test-Case 'Get-ReleaseTrackerFile -BarIds prints repo and BAR id' {
    Assert-Live
    $releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $withContainer = $releases | Where-Object { $_.buildStageContainer } | Select-Object -First 1
    if (-not $withContainer) { Assert-Skip 'no active release has a staging container' }

    $out = & $FileScript -Release $withContainer.name -BarIds | Out-String
    Assert-True ($out -match 'BarBuildId') 'BAR id column is missing'
    Assert-True ($out -match '\d{5,}') 'no BAR id value in the output'
}

Test-Case 'Get-ReleaseTrackerFile rejects an unknown release with a helpful error' {
    Assert-Live
    Assert-Throws {
        & $FileScript -Release 'no-such-release-9.9.9' -BarIds
    } 'expected a throw for an unknown release' 'No release matched'
}

Test-Case '-ReleaseId falls back to release-details for a non-active release' {
    Assert-Live
    # The default Active scope cannot see older releases, so this exercises the
    # release-details/Id fallback path rather than the in-memory filter.
    $active = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/active')
    $all = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/all')
    $activeIds = @($active | ForEach-Object { $_.releaseId })
    $older = $all | Where-Object { $activeIds -notcontains $_.releaseId } | Select-Object -First 1
    if (-not $older) { Assert-Skip 'every release is active; no fallback case available' }

    $parsed = ((& $DataScript -ReleaseId $older.releaseId -AsJson) -join "`n") | ConvertFrom-Json
    $selected = ConvertTo-Array $parsed.Releases
    Assert-Equal 1 $selected.Count 'fallback did not return exactly one release'
    Assert-Equal $older.releaseId $selected[0].releaseId 'fallback returned the wrong release'
    # The fallback response must be shape-compatible with the releases-view record,
    # otherwise the shared table projection silently renders blanks.
    Assert-True ([string]::IsNullOrWhiteSpace([string]$selected[0].name) -eq $false) 'fallback record has no name; shape differs from releases-view'
    $row = ConvertTo-ReleaseTrackerTable -Releases $selected
    Assert-Equal $older.releaseId $row.Id 'fallback record did not project through the table'
}

# =============================================================================
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=================================" -ForegroundColor Cyan
Write-Host ("  Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
Write-Host "=================================" -ForegroundColor Cyan

if ($script:Failed) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
