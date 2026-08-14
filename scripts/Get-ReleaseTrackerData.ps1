<#
.SYNOPSIS
    Pulls data out of the .NET Release Tracker (https://release.dot.net) and prints it as tables.

.DESCRIPTION
    Read-only. Fetches releases plus, on request, their builds, artifact/feed/staging links,
    build reports, release config, CVE releases and schedules, then renders terminal tables or
    emits JSON.

.PARAMETER Scope
    Active     - releases currently in flight (default).
    All        - every release the tracker knows about.
    Everything - All, plus configuration, dropdown, CVE data, schedules and per-release builds.

.PARAMETER ReleaseId
    Restrict to specific release ids. Overrides -Scope for the release set.

.EXAMPLE
    .\Get-ReleaseTrackerData.ps1
.EXAMPLE
    .\Get-ReleaseTrackerData.ps1 -Scope Everything -OutputPath .\tracker-dump
.EXAMPLE
    .\Get-ReleaseTrackerData.ps1 -ReleaseId 159 -IncludeBuilds -IncludeManifests -AsJson
#>
[CmdletBinding()]
param(
    [ValidateSet('Active', 'All', 'Everything')]
    [string] $Scope = 'Active',

    [int[]] $ReleaseId,

    [switch] $IncludeBuilds,
    [switch] $IncludeReports,
    [switch] $IncludeConfig,
    [switch] $IncludeCves,
    [switch] $IncludeSchedules,

    # Downloads metadata/ReleaseManifest.json, ReleaseConfig.json and ReleaseDropManifest.json
    # from each release's staging container. Requires -OutputPath; manifests are large.
    [switch] $IncludeManifests,

    [string] $OutputPath,
    [switch] $AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReleaseTracker.Common.ps1')

$access = Get-ReleaseTrackerAccess
if (-not $access.Available) {
    Write-Error "Release Tracker unavailable ($($access.Reason)): $($access.Detail)"
    return
}

if ($Scope -eq 'Everything') {
    $IncludeBuilds = $true
    $IncludeConfig = $true
    $IncludeCves = $true
    $IncludeSchedules = $true
}

if ($IncludeManifests -and -not $OutputPath) {
    throw '-IncludeManifests requires -OutputPath: the manifests are multi-megabyte files and are written to disk, not the console.'
}

$errors = @()
$errRef = [ref]$errors

# --- releases -------------------------------------------------------------------------------
$viewFilter = 'active'
if ($Scope -ne 'Active') { $viewFilter = 'all' }

Write-Verbose "Loading releases-view/$viewFilter"
$releases = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint "releases/load/releases-view/$viewFilter")

if ($ReleaseId) {
    $wanted = @($ReleaseId)
    $releases = @($releases | Where-Object { $wanted -contains $_.releaseId })

    # A requested id may sit outside the view; fall back to a direct lookup.
    foreach ($id in $wanted) {
        if (-not ($releases | Where-Object { $_.releaseId -eq $id })) {
            $detail = Invoke-ReleaseTrackerApiSafe -Endpoint "releases/load/release-details/Id/$id" -ErrorLog $errRef
            if ($detail) { $releases += $detail }
        }
    }
}

$result = [ordered]@{
    RetrievedUtc = [datetime]::UtcNow.ToString('s') + 'Z'
    Scope        = $Scope
    Releases     = $releases
}

# --- per-release detail ---------------------------------------------------------------------
if ($IncludeBuilds) {
    $builds = @()
    foreach ($release in $releases) {
        $rows = Invoke-ReleaseTrackerApiSafe -Endpoint "releases/load/builds/$($release.releaseId)" -ErrorLog $errRef
        foreach ($row in (ConvertTo-Array $rows)) {
            if (-not $row) { continue }
            Add-Member -InputObject $row -NotePropertyName 'releaseName' -NotePropertyValue $release.name -Force
            Add-Member -InputObject $row -NotePropertyName 'releaseId' -NotePropertyValue $release.releaseId -Force
            $builds += $row
        }
    }
    $result.Builds = $builds
}

if ($IncludeReports) {
    $reports = @()
    foreach ($release in $releases) {
        if (-not $release.buildId) { continue }
        $report = Invoke-ReleaseTrackerApiSafe -Endpoint "releases/load/build-report/$($release.buildId)" -ErrorLog $errRef
        if ($report) {
            $reports += [pscustomobject]@{
                ReleaseId   = $release.releaseId
                ReleaseName = $release.name
                BuildId     = $release.buildId
                Report      = $report
            }
        }
    }
    $result.BuildReports = $reports
}

if ($IncludeConfig) {
    $result.Configuration = Invoke-ReleaseTrackerApiSafe -Endpoint 'releases/load/configuration' -ErrorLog $errRef
    $result.ReleaseDropdown = ConvertTo-Array (Invoke-ReleaseTrackerApiSafe -Endpoint 'releases/load/releases/dropdown' -ErrorLog $errRef)
}

if ($IncludeCves) {
    $result.CveReleases = ConvertTo-Array (Invoke-ReleaseTrackerApiSafe -Endpoint 'cve/LoadReleases' -ErrorLog $errRef)
    $result.CveLookups = Invoke-ReleaseTrackerApiSafe -Endpoint 'cve/LoadLookups' -ErrorLog $errRef
}

if ($IncludeSchedules) {
    $result.Schedules = ConvertTo-Array (Invoke-ReleaseTrackerApiSafe -Endpoint 'schedules/load/schedules' -ErrorLog $errRef)
    $result.ScheduleReleases = ConvertTo-Array (Invoke-ReleaseTrackerApiSafe -Endpoint 'schedules/load/ScheduleRelease' -ErrorLog $errRef)
}

# --- staging container manifests ------------------------------------------------------------
if ($IncludeManifests) {
    $manifestFiles = @(
        'metadata/ReleaseManifest.json'
        'metadata/ReleaseConfig.json'
        'metadata/ReleaseDropManifest.json'
    )

    $saved = @()
    foreach ($release in $releases) {
        if (-not $release.buildStageContainer) { continue }

        $folder = Join-Path $OutputPath ("manifests\{0}" -f (Get-SafeFileName $release.name))
        New-Item -ItemType Directory -Force -Path $folder | Out-Null

        foreach ($file in $manifestFiles) {
            try {
                $bytes = Get-ReleaseTrackerStageFile -StageContainer $release.buildStageContainer -BlobPath $file -AsBytes
                $target = Join-Path $folder (Get-SafeFileName (Split-Path $file -Leaf))
                [System.IO.File]::WriteAllBytes($target, $bytes)
                $saved += [pscustomobject]@{
                    Release = $release.name
                    File    = $file
                    Path    = $target
                    Bytes   = (Get-Item $target).Length
                }
            }
            catch {
                $status = $null
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                $errors += [pscustomobject]@{
                    Endpoint = "stage-container-file/$($release.buildStageContainer)?blobPath=$file"
                    Status   = $status
                    Message  = $_.Exception.Message
                }
            }
        }
    }
    $result.Manifests = $saved
}

$result.Errors = $errors
$output = [pscustomobject]$result

# --- emit -----------------------------------------------------------------------------------
if ($OutputPath) {
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $jsonPath = Join-Path $OutputPath 'release-tracker.json'
    $output | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Verbose "Wrote $jsonPath"
}

if ($AsJson) {
    $output | ConvertTo-Json -Depth 25
    return
}

Write-Output ''
Write-Output "=== Releases ($($releases.Count)) - scope: $Scope ==="
ConvertTo-ReleaseTrackerTable -Releases $releases | Format-Table -AutoSize | Out-String -Width 4096

Write-Output '=== Links ==='
$releases | ForEach-Object {
    [pscustomobject]@{
        Name      = $_.name
        Artifacts = $_.buildArtifactsUrl
        Staging   = $_.buildStagingUrl
        Feed      = $_.buildFeedUrl
    }
} | Format-List | Out-String -Width 4096

if ($result.Contains('Builds')) {
    Write-Output "=== Builds ($($result.Builds.Count)) ==="
    $result.Builds |
        Select-Object releaseName, buildId, name, stage, runtimeVersion, sdkVersion, isMain, stageContainer, rootBarIds |
        Format-Table -AutoSize | Out-String -Width 4096
}

if ($result.Contains('CveReleases')) {
    Write-Output "=== CVE releases ($($result.CveReleases.Count)) ==="
    $result.CveReleases | Select-Object releaseDate, releaseTitle, status, cves, severities, isFinal |
        Format-Table -AutoSize | Out-String -Width 4096
}

if ($result.Contains('Schedules')) {
    Write-Output "=== Schedules ($($result.Schedules.Count)) ==="
    if ($result.Schedules.Count -gt 0) { $result.Schedules | Format-Table -AutoSize | Out-String -Width 4096 }
}

if ($result.Contains('Manifests')) {
    Write-Output "=== Manifests saved ($($result.Manifests.Count)) ==="
    $result.Manifests | Format-Table -AutoSize | Out-String -Width 4096
}

if ($errors.Count -gt 0) {
    Write-Output "=== Skipped ($($errors.Count)) ==="
    $errors | Format-Table Endpoint, Status -AutoSize | Out-String -Width 4096
}
