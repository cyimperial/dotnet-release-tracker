# Shared helpers for the dotnet-release-tracker skill.
# Dot-source this file; do not run it directly.

$script:ReleaseTrackerBaseUri = 'https://release.dot.net/api'

# Display name of the Entra ID app registration protecting the API. The api:// resource id is
# resolved from this at runtime so no tenant-specific GUID is stored in the skill.
$script:ReleaseTrackerAppName = 'ReleaseTracker'

$script:ReleaseTrackerResource = $null
$script:ReleaseTrackerToken = $null
$script:ReleaseTrackerTokenExpiry = [datetime]::MinValue
$script:AzCliPath = $null

# Endpoint fragments that must not be reached casually: they either change server state or kick
# off expensive server-side compute. Invoke-ReleaseTrackerApi refuses these unless the caller
# passes -AllowWrite, so an accidental agent call cannot mutate a live release.
$script:MutatingFragments = @(
    '/action/'
    'cve/AddCve'
    'cve/UpdateCve'
    'cve/DeleteCve'
    'cve/CreateRelease'
    'cve/UpdateRelease'
    'cve/DeleteRelease'
    'cve/ApproveRelease'
    'cve/UnlockRelease'
    'cve/MarkFinal'
    'cve/RenameCveId'
    'cve/DeleteCommit'
    'cve/DeleteProductVersion'
    'cve/GenerateCveJson'
    'cve/ReviewCveJson'
    'payload-tracking/'
)

function Resolve-AzCli {
    <#
    .SYNOPSIS
        Locates az.cmd / az.exe even when it is not on PATH.
    .DESCRIPTION
        The Azure CLI MSI installs under Program Files but does not refresh PATH for already
        running shells, so a plain PATH lookup reports "not installed" on machines where the
        user is perfectly well signed in.
    #>
    [CmdletBinding()]
    param()

    if ($script:AzCliPath) { return $script:AzCliPath }

    $cmd = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $script:AzCliPath = $cmd.Source
        return $script:AzCliPath
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LocalAppData) | Where-Object { $_ }
    $relatives = @(
        'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        'Programs\Azure CLI\wbin\az.cmd'
        'Azure CLI\wbin\az.cmd'
    )

    foreach ($root in $roots) {
        foreach ($relative in $relatives) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate) {
                $script:AzCliPath = $candidate
                return $script:AzCliPath
            }
        }
    }

    return $null
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $az = Resolve-AzCli
    if (-not $az) { return $null }

    $output = & $az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output
}

function Get-ReleaseTrackerAccess {
    <#
    .SYNOPSIS
        Reports whether the .NET Release Tracker API is usable by the current identity.
    .DESCRIPTION
        Never throws, so callers can degrade to public release metadata instead of hard failing
        for identities outside the Microsoft tenant. Returns Available / Reason / Detail.
    #>
    [CmdletBinding()]
    param()

    if (-not (Resolve-AzCli)) {
        return [pscustomobject]@{
            Available = $false
            Reason    = 'NoAzCli'
            Detail    = 'Azure CLI (az) was not found on PATH or in the usual install locations.'
        }
    }

    if (-not (Invoke-AzCli -Arguments @('account', 'show', '--only-show-errors'))) {
        return [pscustomobject]@{
            Available = $false
            Reason    = 'NotSignedIn'
            Detail    = "Not signed in to Azure. Run 'az login'."
        }
    }

    if (-not $script:ReleaseTrackerResource) {
        if ($env:RELEASE_TRACKER_RESOURCE) {
            $script:ReleaseTrackerResource = $env:RELEASE_TRACKER_RESOURCE
        }
        else {
            # Sibling service principals share the name prefix but are managed identities exposing
            # https://identity.azure.net/... SPNs. The API is the one with an api:// SPN.
            $resource = Invoke-AzCli -Arguments @(
                'ad', 'sp', 'list',
                '--filter', "displayName eq '$($script:ReleaseTrackerAppName)'",
                '--query', "[].servicePrincipalNames[] | [?starts_with(@,'api://')] | [0]",
                '-o', 'tsv', '--only-show-errors'
            )

            if ([string]::IsNullOrWhiteSpace($resource)) {
                return [pscustomobject]@{
                    Available = $false
                    Reason    = 'NoTenantAccess'
                    Detail    = "Signed in, but the '$($script:ReleaseTrackerAppName)' app registration is not visible to this account. The tracker is a Microsoft-internal service."
                }
            }

            $script:ReleaseTrackerResource = ($resource | Select-Object -First 1).Trim()
        }
    }

    return [pscustomobject]@{ Available = $true; Reason = 'Ok'; Detail = $null }
}

function Get-ReleaseTrackerToken {
    [CmdletBinding()]
    param([switch] $Force)

    if (-not $Force -and $script:ReleaseTrackerToken -and [datetime]::UtcNow -lt $script:ReleaseTrackerTokenExpiry) {
        return $script:ReleaseTrackerToken
    }

    $access = Get-ReleaseTrackerAccess
    if (-not $access.Available) {
        throw "Release Tracker unavailable ($($access.Reason)): $($access.Detail)"
    }

    $token = Invoke-AzCli -Arguments @(
        'account', 'get-access-token',
        '--resource', $script:ReleaseTrackerResource,
        '--query', 'accessToken', '-o', 'tsv', '--only-show-errors'
    )

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Release Tracker unavailable (NoToken): could not acquire a token for the current account.'
    }

    $script:ReleaseTrackerToken = ($token | Select-Object -First 1).Trim()
    # az tokens last ~60 min; re-mint well before that rather than tracking the real expiry.
    $script:ReleaseTrackerTokenExpiry = [datetime]::UtcNow.AddMinutes(45)
    return $script:ReleaseTrackerToken
}

function Assert-ReadOnlyEndpoint {
    param([Parameter(Mandatory)][string] $Endpoint)

    foreach ($fragment in $script:MutatingFragments) {
        if ($Endpoint -like "*$fragment*") {
            throw "Refusing to call '$Endpoint': it changes Release Tracker state or triggers expensive server-side work. Pass -AllowWrite only when the user has explicitly asked for that."
        }
    }
}

function Invoke-ReleaseTrackerApi {
    <#
    .SYNOPSIS
        Calls a Release Tracker API endpoint with an Entra ID bearer token.
    .PARAMETER Endpoint
        Path relative to https://release.dot.net/api, e.g. 'releases/load/releases-view/active'.
    .PARAMETER Raw
        Return the raw response body instead of parsed JSON.
    .PARAMETER AllowWrite
        Permit endpoints that change server state. Off by default on purpose.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Endpoint,
        [string] $Method = 'GET',
        $Body,
        [switch] $Raw,
        [switch] $AsBytes,
        [switch] $AllowWrite,
        [int] $TimeoutSec = 180
    )

    if (-not $AllowWrite) { Assert-ReadOnlyEndpoint -Endpoint $Endpoint }

    $token = Get-ReleaseTrackerToken
    $uri = "$($script:ReleaseTrackerBaseUri)/$($Endpoint.TrimStart('/'))"

    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = @{ Authorization = "Bearer $token" }
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
    }

    if ($null -ne $Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 20
        $params.ContentType = 'application/json'
    }

    $response = Invoke-WebRequest @params

    # Blob responses (stage-container-file) come back as application/octet-stream, which
    # Invoke-WebRequest surfaces as byte[]. Callers saving a file must ask for -AsBytes:
    # UTF8.GetString is lossy for non-UTF-8 bytes and would silently corrupt binary assets.
    $content = $response.Content

    if ($AsBytes) {
        if ($content -is [byte[]]) { return , $content }
        return , ([System.Text.Encoding]::UTF8.GetBytes([string]$content))
    }

    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }

    if ($Raw) { return $content }

    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    try { return $content | ConvertFrom-Json }
    catch { return $content }
}

function Invoke-ReleaseTrackerApiSafe {
    <#
    .SYNOPSIS
        Invoke-ReleaseTrackerApi that records failures instead of throwing.
    .DESCRIPTION
        Several endpoints legitimately 404 for a given release (release-metadata is only present
        once metadata has been generated), so a bulk sweep must not abort on the first miss.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Endpoint,
        [ref] $ErrorLog,
        [switch] $Raw
    )

    try {
        return Invoke-ReleaseTrackerApi -Endpoint $Endpoint -Raw:$Raw
    }
    catch {
        $status = $null
        $response = $_.Exception.Response
        if ($response) { $status = [int]$response.StatusCode }

        if ($ErrorLog) {
            $ErrorLog.Value += [pscustomobject]@{
                Endpoint = $Endpoint
                Status   = $status
                Message  = $_.Exception.Message
            }
        }
        return $null
    }
}

function Get-ReleaseTrackerStageFile {
    <#
    .SYNOPSIS
        Reads a blob out of a release's staging container.
    .PARAMETER StageContainer
        The buildStageContainer value from a release record, e.g. 'stage-3040363'.
    .PARAMETER BlobPath
        Path inside the container, e.g. 'metadata/ReleaseManifest.json'.
    .PARAMETER AsBytes
        Return raw bytes. Required for binary assets - decoding them as UTF-8 is lossy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $StageContainer,
        [Parameter(Mandatory)][string] $BlobPath,
        [switch] $Raw,
        [switch] $AsBytes
    )

    $container = [uri]::EscapeDataString($StageContainer)
    $encoded = [uri]::EscapeDataString($BlobPath)
    return Invoke-ReleaseTrackerApi -Endpoint "releases/load/stage-container-file/$container`?blobPath=$encoded" -Raw:$Raw -AsBytes:$AsBytes
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Makes a server-supplied name safe to use as a single path segment.
    .DESCRIPTION
        Release names come from the API and are used to build output folders, so they must not be
        able to escape the output root. Strips every path separator and drive-colon, then trims
        trailing dots and spaces (Windows-hostile, and collapses '..' to nothing).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Name)

    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $safe = $safe.Trim([char]'.', [char]' ')
    if ([string]::IsNullOrWhiteSpace($safe)) { return '_' }
    return $safe
}

function ConvertTo-Array {
    <#
    .SYNOPSIS
        Normalizes an API result into a real array.
    .DESCRIPTION
        ConvertFrom-Json emits a JSON array as a *single* pipeline item, so the usual
        @(Invoke-ReleaseTrackerApi ...) idiom yields a 1-element array whose only element is the
        real array. Assign first, then pass through here.
    #>
    param($InputObject)

    # The comma operator is required: 'return @()' unrolls to nothing (AutomationNull) and
    # 'return @($scalar)' unrolls back to the scalar, so callers doing .Count would break on
    # exactly the 0- and 1-element cases.
    if ($null -eq $InputObject) { return , @() }
    return , @($InputObject)
}

function Get-JsonProperty {
    <#
    .SYNOPSIS
        Reads a property that may be absent from an API record.
    .DESCRIPTION
        The API omits properties rather than nulling them for releases that have not reached
        staging yet. Under Set-StrictMode -Version 3.0+ a plain $record.missing throws, so every
        projection goes through here.
    #>
    param($InputObject, [Parameter(Mandatory)][string] $Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-ReleaseTrackerTable {
    <#
    .SYNOPSIS
        Projects release records down to the columns worth showing in a terminal table.
    #>
    param([Parameter(Mandatory)] $Releases)

    # Iterate with foreach, not a pipeline: ConvertTo-Array deliberately returns the array
    # without unrolling, so 'ConvertTo-Array $x | ForEach-Object' would hand the whole array
    # to a single iteration and collapse the table into one row of arrays.
    $items = ConvertTo-Array $Releases
    foreach ($release in $items) {
        # Bind the pipeline item to a named variable: inside a catch block $_ is rebound to the
        # ErrorRecord, so touching $_.releaseDate there fails under Set-StrictMode.
        $released = ''
        $rawDate = Get-JsonProperty $release 'releaseDate'
        if ($rawDate) {
            try { $released = ([datetime]$rawDate).ToString('yyyy-MM-dd') }
            catch { $released = [string]$rawDate }
        }

        [pscustomobject]@{
            Id        = Get-JsonProperty $release 'releaseId'
            Name      = Get-JsonProperty $release 'name'
            Type      = Get-JsonProperty $release 'type'
            Stage     = Get-JsonProperty $release 'stage'
            Runtime   = Get-JsonProperty $release 'runtimeVersion'
            Sdk       = Get-JsonProperty $release 'sdkVersion'
            Released  = $released
            Security  = [bool](Get-JsonProperty $release 'isSecurity' $false)
            Builds    = Get-JsonProperty $release 'buildCount'
            BarIds    = Get-JsonProperty $release 'buildRootBarIds'
            Container = Get-JsonProperty $release 'buildStageContainer'
        }
    }
}
