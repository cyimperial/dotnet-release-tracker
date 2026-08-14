<#
.SYNOPSIS
    Downloads a file from a .NET Release Tracker staging container, or lists a release's assets.

.DESCRIPTION
    Every release exposes a staging blob container (the release record's buildStageContainer,
    e.g. 'stage-3040363'). This script reads blobs out of it through the tracker API, so no
    direct storage account access or SAS token is needed.

    Well-known paths:
        metadata/ReleaseManifest.json      - per-repo builds and barBuildId values
        metadata/ReleaseConfig.json        - release configuration
        metadata/ReleaseDropManifest.json  - full drop contents
        assets/Shipping/assets/Sdk/...     - shipping SDK archives

.PARAMETER Release
    Release name (e.g. '11.0.0-rc.1') or numeric release id. Resolved to its staging container.

.PARAMETER StageContainer
    Use the container directly instead of resolving from a release.

.EXAMPLE
    .\Get-ReleaseTrackerFile.ps1 -Release 11.0.0-rc.1 -Metadata -OutputPath .\rc1
.EXAMPLE
    .\Get-ReleaseTrackerFile.ps1 -Release 159 -BlobPath metadata/ReleaseManifest.json -BarIds
#>
[CmdletBinding(DefaultParameterSetName = 'ByRelease')]
param(
    [Parameter(ParameterSetName = 'ByRelease', Mandatory, Position = 0)]
    [string] $Release,

    [Parameter(ParameterSetName = 'ByContainer', Mandatory)]
    [string] $StageContainer,

    [string[]] $BlobPath,

    # Shorthand for the three metadata/*.json files.
    [switch] $Metadata,

    # Print the repo -> barBuildId table from ReleaseManifest.json instead of dumping the file.
    [switch] $BarIds,

    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReleaseTracker.Common.ps1')

$access = Get-ReleaseTrackerAccess
if (-not $access.Available) {
    Write-Error "Release Tracker unavailable ($($access.Reason)): $($access.Detail)"
    return
}

$releaseName = $StageContainer

if ($PSCmdlet.ParameterSetName -eq 'ByRelease') {
    $all = ConvertTo-Array (Invoke-ReleaseTrackerApi -Endpoint 'releases/load/releases-view/all')

    $match = $all | Where-Object { $_.name -eq $Release } | Select-Object -First 1
    if (-not $match -and $Release -match '^\d+$') {
        $match = $all | Where-Object { $_.releaseId -eq [int]$Release } | Select-Object -First 1
    }
    if (-not $match) {
        $match = $all | Where-Object { $_.name -like "*$Release*" } | Select-Object -First 1
    }

    if (-not $match) {
        $names = ($all | Select-Object -First 15 | ForEach-Object { $_.name }) -join ', '
        throw "No release matched '$Release'. Recent releases: $names"
    }

    $StageContainer = $match.buildStageContainer
    $releaseName = $match.name

    if (-not $StageContainer) {
        throw "Release '$($match.name)' has no staging container yet (stage: $($match.stage))."
    }
}

if ($BarIds -and -not $BlobPath) { $BlobPath = @('metadata/ReleaseManifest.json') }

if ($Metadata) {
    # ReleaseDropManifest.json alone is ~3 MB; never let it land in an agent's context.
    if (-not $OutputPath) {
        throw '-Metadata requires -OutputPath: ReleaseDropManifest.json is multi-megabyte and must be written to disk, not the console.'
    }

    $BlobPath = @(
        'metadata/ReleaseManifest.json'
        'metadata/ReleaseConfig.json'
        'metadata/ReleaseDropManifest.json'
    )
}

if (-not $BlobPath) {
    throw 'Specify -BlobPath, -Metadata or -BarIds.'
}

Write-Verbose "Release '$releaseName' -> container '$StageContainer'"

foreach ($path in $BlobPath) {
    if ($BarIds -and $path -like '*ReleaseManifest.json') {
        $manifest = Get-ReleaseTrackerStageFile -StageContainer $StageContainer -BlobPath $path -Raw | ConvertFrom-Json
        if (-not $manifest.builds) { throw "Manifest does not contain a 'builds' array." }

        Write-Output ''
        Write-Output "=== BAR build ids - $releaseName ($StageContainer) ==="
        ConvertTo-Array $manifest.builds |
            Select-Object @{ n = 'Repo'; e = { $_.repo } },
                          @{ n = 'BarBuildId'; e = { $_.barBuildId } },
                          @{ n = 'Commit'; e = { $_.commit } } |
            Sort-Object Repo | Format-Table -AutoSize | Out-String -Width 4096
        continue
    }

    if ($OutputPath) {
        $folder = $OutputPath
        if ($BlobPath.Count -gt 1) {
            $folder = Join-Path $OutputPath (Get-SafeFileName $releaseName)
        }
        New-Item -ItemType Directory -Force -Path $folder | Out-Null

        # Save bytes, not text: blobs may be binary (SDK archives) and a UTF-8 round-trip
        # would silently corrupt them.
        $bytes = Get-ReleaseTrackerStageFile -StageContainer $StageContainer -BlobPath $path -AsBytes
        $target = Join-Path $folder (Get-SafeFileName (Split-Path $path -Leaf))
        [System.IO.File]::WriteAllBytes($target, $bytes)
        Write-Output ("Saved {0} -> {1} ({2:N0} bytes)" -f $path, $target, (Get-Item $target).Length)
    }
    else {
        Get-ReleaseTrackerStageFile -StageContainer $StageContainer -BlobPath $path -Raw
    }
}
