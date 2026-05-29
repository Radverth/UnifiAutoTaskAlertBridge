<#
.SYNOPSIS
    UniFi network health monitor for Datto RMM — proactive group edition.
.DESCRIPTION
    Runs on a single central machine with the Datto RMM agent installed.
    Authenticates with the Datto RMM API, queries all devices in a specified
    filter/dynamic group (your proactive service group) to discover which sites
    are in scope, reads the UnifiSiteKeys site variable from each of those sites,
    then queries the UniFi Cloud API for every host/network and raises a Datto
    RMM alert if any issues are found.

    Sites that are NOT in the dynamic group are completely ignored.

    Configuration — edit the CONFIGURATION region below:
        $DattoApiUrl    — your Datto RMM API base URL
                          Format: https://{zone}-api.centrastage.net
                          Zones: pinotage, merlot, concord, vidal, zinfandel, syrah
        $DattoApiKey    — API key from Datto RMM Setup > Users > API Keys
        $DattoApiSecret — API secret key from the same page
        $DattoFilterId  — numeric ID of the filter/dynamic group (proactive service group)
                          Find it in Datto RMM: Manage > Filters — ID shown in the URL
        $UnifiApiKey    — UniFi Cloud API key from account.ui.com

    UnifiSiteKeys site variable format (set on each Datto RMM site):
        Single host          : HostID
        Host + specific net  : HostId|NetworkId
        Multiple entries     : HostId1,HostId2|NetworkId2,HostId3

    LOCAL TESTING
        Run with -Test to get verbose colour-coded output showing which sites
        were found in the filter, which have UnifiSiteKeys set, and what alerts
        would fire — without the compressed Datto result format. Requires that
        your Datto API credentials and UniFi API key are filled in below.

            .\Invoke-UniFiDattoMonitor-DattoAPI.ps1 -Test

        The final STATUS line is still printed so you can see exactly what
        Datto RMM would receive.

    Exit codes:
        0 — all monitored sites healthy (or no sites in group have UnifiSiteKeys set)
        1 — one or more alert conditions detected, or a fatal error occurred
#>

param(
    [switch]$Test   # Verbose local output — use this when testing outside Datto RMM
)

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

# Your Datto RMM zone URL — e.g. https://zinfandel-api.centrastage.net
# Check your Datto RMM browser URL to identify your zone.
$DattoApiUrl    = 'https://zinfandel-api.centrastage.net'
$DattoApiKey    = 'YOUR_DATTO_API_KEY_HERE'
$DattoApiSecret = 'YOUR_DATTO_API_SECRET_HERE'
$DattoFilterId  = 0   # <-- numeric ID of your proactive service filter/dynamic group

$UnifiApiBase   = 'https://api.ui.com/v1'
$UnifiApiKey    = 'YOUR_UNIFI_API_KEY_HERE'
# $UnifiApiKey  = $env:CS_UnifiApiKey   # <- uncomment to use a Datto global variable instead

# Alert thresholds
$TxRetryWarningPct   = 50.0
$TxRetryCriticalPct  = 55.0
$WanUptimeWarningPct = 99.0

#endregion

#region VALIDATION

function Write-DattoResult {
    param([string]$Status)
    Write-Host '<-Start Result->'
    Write-Host "STATUS=$Status"
    Write-Host '<-End Result->'
}

function Write-TestInfo    { param([string]$Msg) if ($Test) { Write-Host "[INFO]    $Msg" -ForegroundColor Cyan } }
function Write-TestOk      { param([string]$Msg) if ($Test) { Write-Host "[OK]      $Msg" -ForegroundColor Green } }
function Write-TestAlert   { param([string]$Msg) if ($Test) { Write-Host "[ALERT]   $Msg" -ForegroundColor Red } }
function Write-TestWarning { param([string]$Msg) if ($Test) { Write-Host "[WARNING] $Msg" -ForegroundColor Yellow } }

if (-not $DattoApiKey -or $DattoApiKey -eq 'YOUR_DATTO_API_KEY_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoApiKey is not set.'
    exit 1
}
if (-not $DattoApiSecret -or $DattoApiSecret -eq 'YOUR_DATTO_API_SECRET_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoApiSecret is not set.'
    exit 1
}
if ($DattoFilterId -eq 0) {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoFilterId is not set. Set it to your proactive service filter ID.'
    exit 1
}
if (-not $UnifiApiKey -or $UnifiApiKey -eq 'YOUR_UNIFI_API_KEY_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: UnifiApiKey is not set.'
    exit 1
}

#endregion

#region DATTO RMM API HELPERS

function Get-DattoBearerToken {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    # Password grant — token endpoint is at /auth/oauth/token (NOT under /api/)
    # Requires HTTP Basic auth with the literal credentials public-client:public
    $tokenUrl  = "$DattoApiUrl/auth/oauth/token"
    $body      = "grant_type=password&username=$([System.Uri]::EscapeDataString($DattoApiKey))&password=$([System.Uri]::EscapeDataString($DattoApiSecret))"
    $basicCred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('public-client:public'))

    $wc = [System.Net.WebClient]::new()
    $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
    $wc.Headers.Add('Authorization', "Basic $basicCred")

    try {
        $raw  = $wc.UploadString($tokenUrl, 'POST', $body)
        $resp = $raw | ConvertFrom-Json
        if (-not $resp.access_token) {
            throw "Token response did not include access_token."
        }
        return $resp.access_token
    }
    catch [System.Net.WebException] {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        throw "Datto RMM authentication failed (HTTP $status). Check DattoApiKey and DattoApiSecret."
    }
    catch {
        throw "Datto RMM authentication error: $($_.Exception.Message)"
    }
}

function Invoke-DattoRequest {
    param(
        [string]$Token,
        [string]$Endpoint,
        [hashtable]$QueryParams = @{}
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    # All API endpoints are under /api/v2 on the zone base URL
    $uri = "$DattoApiUrl/api/v2$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $qs  = ($QueryParams.GetEnumerator() | ForEach-Object {
            "$([System.Uri]::EscapeDataString($_.Key))=$([System.Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri = "${uri}?${qs}"
    }

    $wc = [System.Net.WebClient]::new()
    $wc.Headers.Add('Accept', 'application/json')
    $wc.Headers.Add('Authorization', "Bearer $Token")

    try {
        $uriObj = New-Object System.Uri($uri, $true)
        $raw    = $wc.DownloadString($uriObj)
        return $raw | ConvertFrom-Json
    }
    catch [System.Net.WebException] {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 429) {
            throw "Datto API rate limit hit (HTTP 429). Try again shortly."
        }
        throw "Datto API error (HTTP $status) for '$Endpoint': $($_.Exception.Message)"
    }
    catch {
        throw "Datto API unexpected error for '$Endpoint': $($_.Exception.Message)"
    }
}

function Get-DattoSitesInFilter {
    # Queries /v2/account/devices with filterId to get all devices in the filter,
    # then returns distinct site UIDs and names from those devices.
    # There is no direct "list devices in filter" endpoint — filterId is a query param
    # on the standard device listing endpoint and exclusively determines results.
    param([string]$Token)

    $siteUids = [System.Collections.Generic.HashSet[string]]::new()
    $siteMap  = @{}
    $page     = 0   # Datto API pagination is zero-based

    do {
        $resp    = Invoke-DattoRequest -Token $Token -Endpoint '/account/devices' `
                       -QueryParams @{ filterId = $DattoFilterId; page = $page; max = 250 }
        $devices = if ($resp.devices) { $resp.devices } elseif ($resp -is [array]) { $resp } else { @() }

        foreach ($dev in $devices) {
            $uid = if ($dev.siteUid) { $dev.siteUid } else { $null }
            if ($uid -and $siteUids.Add($uid)) {
                $siteMap[$uid] = @{
                    Uid  = $uid
                    Name = if ($dev.siteName) { $dev.siteName } else { $uid }
                }
            }
        }

        $nextPageUrl = if ($resp.pageDetails -and $resp.pageDetails.nextPageUrl) { $resp.pageDetails.nextPageUrl } else { $null }
        $page++
    } while ($nextPageUrl)

    return $siteMap.Values
}

function Get-DattoSiteVariable {
    # Returns the value of a named site variable, or $null if not set.
    # Endpoint: GET /v2/site/{siteUid}/variables
    # Response: { variables: [ { id, name, value, masked } ] }
    param(
        [string]$Token,
        [string]$SiteUid,
        [string]$VariableName
    )

    try {
        $page = 0
        do {
            $resp = Invoke-DattoRequest -Token $Token -Endpoint "/site/$SiteUid/variables" `
                        -QueryParams @{ page = $page; max = 250 }
            $vars = if ($resp.variables) { $resp.variables } elseif ($resp -is [array]) { $resp } else { @() }

            $match = $vars | Where-Object { $_.name -eq $VariableName } | Select-Object -First 1
            if ($match) { return $match.value }

            $nextPageUrl = if ($resp.pageDetails -and $resp.pageDetails.nextPageUrl) { $resp.pageDetails.nextPageUrl } else { $null }
            $page++
        } while ($nextPageUrl)
    }
    catch { }

    return $null
}

#endregion

#region UNIFI API HELPERS

function Invoke-UniFiRequest {
    param(
        [string]$Endpoint,
        [hashtable]$QueryParams = @{}
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $uri = "$UnifiApiBase$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $qs = ($QueryParams.GetEnumerator() | ForEach-Object {
            $k = [System.Uri]::EscapeDataString($_.Key) -replace '%5B','[' -replace '%5D',']'
            "$k=$([System.Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri = "${uri}?${qs}"
    }

    $wc = [System.Net.WebClient]::new()
    $wc.Headers.Add('Accept', 'application/json')
    $wc.Headers.Add('X-API-Key', $UnifiApiKey)

    try {
        $uriObj = New-Object System.Uri($uri, $true)
        $raw    = $wc.DownloadString($uriObj)
        return $raw | ConvertFrom-Json
    }
    catch [System.Net.WebException] {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -or $status -eq 403) {
            throw "UniFi API authentication failed (HTTP $status). Check UnifiApiKey."
        }
        elseif ($status -ge 500) {
            throw "UniFi API server error (HTTP $status) for '$Endpoint'."
        }
        else {
            throw "UniFi API unreachable at '$uri': $($_.Exception.Message)"
        }
    }
    catch {
        throw "UniFi unexpected error calling '$uri': $($_.Exception.Message)"
    }
}

function Get-HostName {
    # hostName is not present on /v1/hosts/{id} — it exists only in the /v1/devices
    # response wrapper (data[].hostName). Fetch one page of devices to read it.
    param([string]$HostId)
    try {
        $encodedId = [System.Uri]::EscapeDataString($HostId)
        $resp = Invoke-UniFiRequest -Endpoint "/devices?hostIds[]=$encodedId&pageSize=1"
        $wrappers = if ($resp.data) { $resp.data } else { @() }
        $wrapper  = $wrappers | Where-Object { $_.hostId -eq $HostId } | Select-Object -First 1
        if ($wrapper -and $wrapper.hostName) { return $wrapper.hostName }
    }
    catch { }
    return $HostId
}

function Get-AllUniFiSites {
    $all       = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null
    do {
        $params = @{ pageSize = 200 }
        if ($nextToken) { $params['nextToken'] = $nextToken }
        $resp  = Invoke-UniFiRequest -Endpoint '/sites' -QueryParams $params
        $sites = if ($resp.data) { $resp.data } elseif ($resp -is [array]) { $resp } else { @() }
        foreach ($s in $sites) { $all.Add($s) }
        $nextToken = if ($resp.nextToken) { $resp.nextToken } else { $null }
    } while ($nextToken)
    return $all
}

function Get-Devices {
    param([string]$HostId)

    $all       = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null

    do {
        $encodedId = [System.Uri]::EscapeDataString($HostId)
        $qs = "hostIds[]=$encodedId&pageSize=100"
        if ($nextToken) { $qs += "&nextToken=$([System.Uri]::EscapeDataString($nextToken))" }

        $uri    = "$UnifiApiBase/devices?$qs"
        $uriObj = New-Object System.Uri($uri, $true)

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = [System.Net.WebClient]::new()
        $wc.Headers.Add('Accept', 'application/json')
        $wc.Headers.Add('X-API-Key', $UnifiApiKey)

        try {
            $raw      = $wc.DownloadString($uriObj)
            $response = $raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to retrieve devices for host '$HostId': $($_.Exception.Message)"
        }

        $wrappers = if ($response.data) { $response.data } elseif ($response -is [array]) { $response } else { @() }
        foreach ($wrapper in $wrappers) {
            if ($wrapper.hostId -and $wrapper.hostId -ne $HostId) { continue }
            $devs = if ($wrapper.devices) { $wrapper.devices } elseif ($wrapper.mac) { @($wrapper) } else { @() }
            foreach ($d in $devs) { $all.Add($d) }
        }

        $nextToken = if ($response.nextToken) { $response.nextToken } else { $null }
    } while ($nextToken)

    return $all
}

function Resolve-Network {
    param(
        [object[]]$AllSites,
        [string]$HostId,
        [string]$NetworkId
    )

    $hostSites = @($AllSites | Where-Object { $_.hostId -eq $HostId })

    if ($NetworkId) {
        $match = $hostSites | Where-Object {
            ($_.id -and $_.id -eq $NetworkId) -or
            ($_.meta -and $_.meta.name -and $_.meta.name -eq $NetworkId)
        } | Select-Object -First 1

        if ($match) {
            $networkName = if ($match.meta -and $match.meta.desc)     { $match.meta.desc }
                           elseif ($match.meta -and $match.meta.name) { $match.meta.name }
                           else { $NetworkId }
            return @{ Site = $match; NetworkName = $networkName }
        }
        Write-TestWarning "NetworkId '$NetworkId' not matched for host '$HostId' — using first available site."
    }

    $first = $hostSites | Select-Object -First 1
    $networkName = if ($first -and $first.meta -and $first.meta.desc)     { $first.meta.desc }
                   elseif ($first -and $first.meta -and $first.meta.name) { $first.meta.name }
                   else { 'Unknown Network' }
    return @{ Site = $first; NetworkName = $networkName }
}

function Parse-SiteKeys {
    param([string]$Raw)
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($part in $Raw.Split(',')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ($part.Contains('|')) {
            $split = $part.Split('|', 2)
            $entries.Add(@{ HostId = $split[0].Trim(); NetworkId = $split[1].Trim() })
        }
        else {
            $entries.Add(@{ HostId = $part; NetworkId = $null })
        }
    }
    return $entries
}

#endregion

#region MAIN

if ($Test) {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  UniFi Monitor — Test Mode (Datto API)' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
}

$alerts    = [System.Collections.Generic.List[string]]::new()
$apiErrors = [System.Collections.Generic.List[string]]::new()

# --- Step 1: Authenticate with Datto RMM ---
Write-TestInfo "Authenticating with Datto RMM API at $DattoApiUrl..."
$dattoToken = $null
try {
    $dattoToken = Get-DattoBearerToken
    Write-TestOk "Datto RMM authentication successful."
}
catch {
    Write-DattoResult -Status "DATTO API ERROR: Authentication failed — $($_.Exception.Message)"
    exit 1
}

# --- Step 2: Get all sites in the proactive service filter ---
Write-TestInfo "Querying filter $DattoFilterId for proactive sites..."
$proactiveSites = $null
try {
    $proactiveSites = @(Get-DattoSitesInFilter -Token $dattoToken)
    Write-TestInfo "$($proactiveSites.Count) distinct site(s) found in filter."
}
catch {
    Write-DattoResult -Status "DATTO API ERROR: Could not retrieve devices for filter $DattoFilterId — $($_.Exception.Message)"
    exit 1
}

if ($proactiveSites.Count -eq 0) {
    Write-DattoResult -Status "No sites found in filter $DattoFilterId — nothing to monitor"
    exit 0
}

# --- Step 3: Collect UnifiSiteKeys from each proactive site ---
$allEntries = [System.Collections.Generic.List[hashtable]]::new()

foreach ($dattoSite in $proactiveSites) {
    $siteUid  = $dattoSite.Uid
    $siteName = $dattoSite.Name

    $siteKeysRaw = $null
    try {
        $siteKeysRaw = Get-DattoSiteVariable -Token $dattoToken -SiteUid $siteUid -VariableName 'UnifiSiteKeys'
    }
    catch {
        $apiErrors.Add("[Datto/$siteName] Failed to read site variables: $($_.Exception.Message)")
        Write-TestWarning "[$siteName] Failed to read site variables: $($_.Exception.Message)"
        continue
    }

    if (-not $siteKeysRaw) {
        Write-TestInfo "[$siteName] No UnifiSiteKeys set — skipping."
        continue
    }

    Write-TestInfo "[$siteName] UnifiSiteKeys = $siteKeysRaw"
    $parsed = Parse-SiteKeys -Raw $siteKeysRaw
    foreach ($e in $parsed) { $allEntries.Add($e) }
}

if ($allEntries.Count -eq 0) {
    Write-DattoResult -Status 'No UnifiSiteKeys configured on any proactive site — nothing to monitor'
    exit 0
}

# --- Step 4: Fetch UniFi sites once ---
Write-TestInfo "Fetching all UniFi sites..."
$allUniFiSites = $null
try {
    $allUniFiSites = @(Get-AllUniFiSites)
    Write-TestInfo "$($allUniFiSites.Count) site/network entries retrieved."
}
catch {
    Write-DattoResult -Status "UNIFI API ERROR: Could not retrieve sites — $($_.Exception.Message)"
    exit 1
}

# --- Step 5: Evaluate each host/network entry ---
foreach ($entry in $allEntries) {
    $hostId    = $entry.HostId
    $networkId = $entry.NetworkId

    try {
        $hostName      = Get-HostName -HostId $hostId
        $networkResult = Resolve-Network -AllSites $allUniFiSites -HostId $hostId -NetworkId $networkId
        $site          = $networkResult.Site
        $networkName   = $networkResult.NetworkName
        $label         = "$hostName > $networkName"

        if ($Test) {
            Write-Host ''
            Write-Host "  --- $label ---" -ForegroundColor White
        }

        $allDevices = @(Get-Devices -HostId $hostId)

        # The cloud API returns all devices for a host with no per-device network/site ID,
        # so we cannot filter devices by NetworkId at the device level. Statistics (offline
        # count, TX retry, WAN uptime) are correctly scoped to the network via Resolve-Network.
        $devices = $allDevices

        Write-TestInfo "$($devices.Count) device(s) on host '$hostName'."

        if ($Test) {
            foreach ($dev in $devices) {
                $devName   = if ($dev.name)  { $dev.name }  else { $dev.model }
                $devStatus = if ($dev.status) { $dev.status } else { 'unknown' }
                $devFw     = if ($dev.firmwareStatus) { $dev.firmwareStatus } else { 'n/a' }
                $color     = if ($devStatus -eq 'online') { 'Green' } else { 'Red' }
                Write-Host ("    {0,-30} status={1,-8} firmware={2}" -f $devName, $devStatus, $devFw) -ForegroundColor $color
            }
        }

        $stats  = if ($site -and $site.statistics)    { $site.statistics }   else { $null }
        $pct    = if ($stats -and $stats.percentages) { $stats.percentages } else { $null }
        $counts = if ($stats -and $stats.counts)      { $stats.counts }      else { $null }

        if ($Test -and $pct) {
            $txVal  = if ($null -ne $pct.txRetry)   { "$([math]::Round($pct.txRetry,1))%" }   else { 'n/a' }
            $wanVal = if ($null -ne $pct.wanUptime)  { "$([math]::Round($pct.wanUptime,2))%" } else { 'n/a' }
            Write-TestInfo "  TX retry: $txVal   WAN uptime: $wanVal"
        }

        # --- Offline devices ---
        $offlineDevices = @($devices | Where-Object { $_.status -eq 'offline' })
        $offlineCount   = if ($counts -and $null -ne $counts.offlineDevice) { [int]$counts.offlineDevice } else { $offlineDevices.Count }

        if ($offlineCount -gt 1) {
            $nameList = if ($offlineDevices.Count -gt 0) {
                ($offlineDevices | ForEach-Object { if ($_.name) { $_.name } else { $_.model } }) -join ', '
            } else { 'multiple devices' }
            $msg = "[$label] OUTAGE: $offlineCount devices offline — $nameList"
            $alerts.Add($msg); Write-TestAlert $msg
        }
        elseif ($offlineCount -eq 1) {
            $dev  = $offlineDevices | Select-Object -First 1
            $name = if ($dev -and $dev.name) { $dev.name } elseif ($dev -and $dev.model) { $dev.model } else { 'Unknown' }
            $msg  = "[$label] OFFLINE: $name is offline"
            $alerts.Add($msg); Write-TestAlert $msg
        }
        else {
            Write-TestOk "[$label] All devices online."
        }

        # --- TX retry rate ---
        if ($pct -and $null -ne $pct.txRetry) {
            $txRetry = [double]$pct.txRetry
            $txRound = [math]::Round($txRetry, 1)
            if ($txRetry -gt $TxRetryCriticalPct) {
                $msg = "[$label] CRITICAL: WAN packet retry rate ${txRound}% (threshold: ${TxRetryCriticalPct}%)"
                $alerts.Add($msg); Write-TestAlert $msg
            }
            elseif ($txRetry -gt $TxRetryWarningPct) {
                $msg = "[$label] WARNING: Elevated WAN packet retry rate ${txRound}% (threshold: ${TxRetryWarningPct}%)"
                $alerts.Add($msg); Write-TestWarning $msg
            }
            else {
                Write-TestOk "[$label] TX retry ${txRound}% — within threshold."
            }
        }

        # --- WAN uptime ---
        if ($pct -and $null -ne $pct.wanUptime) {
            $wanUptime = [double]$pct.wanUptime
            if ($wanUptime -lt $WanUptimeWarningPct) {
                $upRound = [math]::Round($wanUptime, 2)
                $msg = "[$label] WARNING: WAN uptime ${upRound}% is below threshold (${WanUptimeWarningPct}%)"
                $alerts.Add($msg); Write-TestWarning $msg
            }
            else {
                $upRound = [math]::Round($wanUptime, 2)
                Write-TestOk "[$label] WAN uptime ${upRound}% — within threshold."
            }
        }

        # --- Critical notifications ---
        if ($counts -and $null -ne $counts.criticalNotification -and [int]$counts.criticalNotification -gt 0) {
            $n   = [int]$counts.criticalNotification
            $msg = "[$label] ALERT: $n critical notification(s) on controller"
            $alerts.Add($msg); Write-TestAlert $msg
        }
    }
    catch {
        $entryLabel = if ($networkId) { "$hostId|$networkId" } else { $hostId }
        $errMsg = "[$entryLabel] API error: $($_.Exception.Message)"
        $apiErrors.Add($errMsg)
        Write-TestWarning $errMsg
    }
}

#endregion

#region OUTPUT

if ($Test) {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  Datto RMM Output Preview' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
}

if ($apiErrors.Count -gt 0 -and $alerts.Count -eq 0) {
    Write-DattoResult -Status "API error(s) prevented evaluation: $($apiErrors -join ' | ')"
    exit 1
}

if ($alerts.Count -gt 0) {
    $summary = $alerts -join ' | '
    if ($apiErrors.Count -gt 0) {
        $summary += " | API errors: $($apiErrors -join ' | ')"
    }
    Write-DattoResult -Status $summary
    if ($Test) { Write-Host '' ; Write-Host "Exit code: 1 (alert)" -ForegroundColor Red }
    exit 1
}

Write-DattoResult -Status 'All monitored sites healthy'
if ($Test) { Write-Host '' ; Write-Host "Exit code: 0 (healthy)" -ForegroundColor Green }
exit 0

#endregion
