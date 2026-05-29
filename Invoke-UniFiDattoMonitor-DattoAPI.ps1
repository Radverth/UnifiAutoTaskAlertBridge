<#
.SYNOPSIS
    UniFi network health monitor for Datto RMM — proactive group edition.
.DESCRIPTION
    Runs on a single central machine. Authenticates with the Datto RMM API,
    queries all sites in a specified dynamic group (your proactive service group),
    reads the UnifiSiteKeys site variable from each, then queries the UniFi Cloud
    API for every host/network and raises a Datto RMM alert if any issues are found.

    Sites that are NOT in the dynamic group are completely ignored — no UniFi
    queries are made for them.

    Configuration — edit the CONFIGURATION region below:
        $DattoApiUrl    — your Datto RMM API URL (e.g. https://zinfandel-api.centrastage.net)
        $DattoApiKey    — API key from Datto RMM Setup > API Configuration
        $DattoApiSecret — API secret from the same page
        $DattoFilterId  — numeric ID of the dynamic group (proactive service group)
        $UnifiApiKey    — UniFi Cloud API key from account.ui.com

    UnifiSiteKeys site variable format (set on each Datto RMM site):
        Single host          : HostID
        Host with network    : HostId|NetworkId
        Multiple entries     : HostId1,HostId2|NetworkId2,HostId3

    Exit codes:
        0 — all monitored sites healthy (or no sites in group have UnifiSiteKeys set)
        1 — one or more alert conditions detected, or a fatal error occurred
#>

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

$DattoApiUrl    = 'https://zinfandel-api.centrastage.net'   # Your Datto RMM API URL
$DattoApiKey    = 'YOUR_DATTO_API_KEY_HERE'
$DattoApiSecret = 'YOUR_DATTO_API_SECRET_HERE'
$DattoFilterId  = 0   # <-- Set to your proactive service group / dynamic group ID

$UnifiApiBase   = 'https://api.ui.com/v1'
$UnifiApiKey    = 'YOUR_UNIFI_API_KEY_HERE'
# $UnifiApiKey  = $env:CS_UnifiApiKey   # <- uncomment when using Datto global variable

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

if (-not $DattoApiKey -or $DattoApiKey -eq 'YOUR_DATTO_API_KEY_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoApiKey is not set.'
    exit 1
}
if (-not $DattoApiSecret -or $DattoApiSecret -eq 'YOUR_DATTO_API_SECRET_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoApiSecret is not set.'
    exit 1
}
if ($DattoFilterId -eq 0) {
    Write-DattoResult -Status 'CONFIGURATION ERROR: DattoFilterId is not set. Set it to your proactive service dynamic group ID.'
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

    $tokenUrl = "$DattoApiUrl/auth/oauth/token"
    $body     = "grant_type=password&username=$([System.Uri]::EscapeDataString($DattoApiKey))&password=$([System.Uri]::EscapeDataString($DattoApiSecret))"

    $wc = [System.Net.WebClient]::new()
    $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')

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
        throw "Datto RMM authentication failed (HTTP $status): $($_.Exception.Message)"
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
        throw "Datto API error (HTTP $status) for '$Endpoint': $($_.Exception.Message)"
    }
    catch {
        throw "Datto API unexpected error for '$Endpoint': $($_.Exception.Message)"
    }
}

function Get-DattoSitesInFilter {
    # Returns all sites (accounts) that contain at least one device matching the filter.
    # Datto dynamic group filters target devices; we get distinct site UIDs from the device list.
    param([string]$Token)

    $siteUids  = [System.Collections.Generic.HashSet[string]]::new()
    $siteMap   = @{}   # uid -> site object
    $pageNum   = 1
    $pageSize  = 250

    do {
        $resp    = Invoke-DattoRequest -Token $Token -Endpoint "/filter/$DattoFilterId/devices" `
                       -QueryParams @{ page = $pageNum; max = $pageSize }
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

        $totalPages = if ($resp.pageDetails -and $resp.pageDetails.totalPages) { [int]$resp.pageDetails.totalPages } else { 1 }
        $pageNum++
    } while ($pageNum -le $totalPages)

    return $siteMap.Values
}

function Get-DattoSiteVariable {
    # Returns the value of a named site variable, or $null if not set.
    param(
        [string]$Token,
        [string]$SiteUid,
        [string]$VariableName
    )

    try {
        $resp = Invoke-DattoRequest -Token $Token -Endpoint "/account/$SiteUid/variables"
        $vars = if ($resp.variables) { $resp.variables } elseif ($resp -is [array]) { $resp } else { @() }
        $match = $vars | Where-Object { $_.name -eq $VariableName } | Select-Object -First 1
        if ($match) { return $match.value }
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
    param([string]$HostId)
    try {
        $resp = Invoke-UniFiRequest -Endpoint "/hosts/$HostId"
        $obj  = if ($resp.data) { $resp.data } else { $resp }
        if ($obj -and $obj.hostName) { return $obj.hostName }
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
            $networkName = if ($match.meta -and $match.meta.desc)  { $match.meta.desc }
                           elseif ($match.meta -and $match.meta.name) { $match.meta.name }
                           else { $NetworkId }
            return @{ Site = $match; NetworkName = $networkName }
        }
        Write-Host "WARNING: NetworkId '$NetworkId' not matched for host '$HostId'. Using first available site."
    }

    $first = $hostSites | Select-Object -First 1
    $networkName = if ($first -and $first.meta -and $first.meta.desc)  { $first.meta.desc }
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

$alerts    = [System.Collections.Generic.List[string]]::new()
$apiErrors = [System.Collections.Generic.List[string]]::new()

# --- Step 1: Authenticate with Datto RMM ---
$dattoToken = $null
try {
    $dattoToken = Get-DattoBearerToken
}
catch {
    Write-DattoResult -Status "DATTO API ERROR: Authentication failed — $($_.Exception.Message)"
    exit 1
}

# --- Step 2: Get all sites in the proactive service dynamic group ---
$proactiveSites = $null
try {
    $proactiveSites = @(Get-DattoSitesInFilter -Token $dattoToken)
}
catch {
    Write-DattoResult -Status "DATTO API ERROR: Could not retrieve dynamic group $DattoFilterId — $($_.Exception.Message)"
    exit 1
}

if ($proactiveSites.Count -eq 0) {
    Write-DattoResult -Status "No sites found in dynamic group $DattoFilterId — nothing to monitor"
    exit 0
}

# --- Step 3: Collect UnifiSiteKeys from each proactive site ---
# Deduplicated by site UID
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
        continue
    }

    if (-not $siteKeysRaw) {
        # This Datto site has no UnifiSiteKeys — skip silently (not every proactive site has UniFi)
        continue
    }

    $parsed = Parse-SiteKeys -Raw $siteKeysRaw
    foreach ($e in $parsed) { $allEntries.Add($e) }
}

if ($allEntries.Count -eq 0) {
    Write-DattoResult -Status 'No UnifiSiteKeys configured on any proactive site — nothing to monitor'
    exit 0
}

# --- Step 4: Fetch UniFi sites once ---
$allUniFiSites = $null
try {
    $allUniFiSites = @(Get-AllUniFiSites)
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

        $allDevices = @(Get-Devices -HostId $hostId)

        if ($networkId) {
            $networkDevices = @($allDevices | Where-Object {
                ($_.networkId -and $_.networkId -eq $networkId) -or
                ($_.siteId    -and $_.siteId    -eq $networkId)
            })
            $devices = if ($networkDevices.Count -gt 0) { $networkDevices } else { $allDevices }
        }
        else {
            $devices = $allDevices
        }

        $stats  = if ($site -and $site.statistics)          { $site.statistics }          else { $null }
        $pct    = if ($stats -and $stats.percentages)       { $stats.percentages }        else { $null }
        $counts = if ($stats -and $stats.counts)            { $stats.counts }             else { $null }

        # --- Offline devices ---
        $offlineDevices = @($devices | Where-Object { $_.status -eq 'offline' })
        $offlineCount   = if ($counts -and $null -ne $counts.offlineDevice) { [int]$counts.offlineDevice } else { $offlineDevices.Count }

        if ($offlineCount -gt 1) {
            $nameList = if ($offlineDevices.Count -gt 0) {
                ($offlineDevices | ForEach-Object { if ($_.name) { $_.name } else { $_.model } }) -join ', '
            } else { 'multiple devices' }
            $alerts.Add("[$label] OUTAGE: $offlineCount devices offline — $nameList")
        }
        elseif ($offlineCount -eq 1) {
            $dev  = $offlineDevices | Select-Object -First 1
            $name = if ($dev -and $dev.name) { $dev.name } elseif ($dev -and $dev.model) { $dev.model } else { 'Unknown' }
            $alerts.Add("[$label] OFFLINE: $name is offline")
        }

        # --- TX retry rate ---
        if ($pct -and $null -ne $pct.txRetry) {
            $txRetry = [double]$pct.txRetry
            $txRound = [math]::Round($txRetry, 1)
            if ($txRetry -gt $TxRetryCriticalPct) {
                $alerts.Add("[$label] CRITICAL: WAN packet retry rate ${txRound}% (threshold: ${TxRetryCriticalPct}%)")
            }
            elseif ($txRetry -gt $TxRetryWarningPct) {
                $alerts.Add("[$label] WARNING: Elevated WAN packet retry rate ${txRound}% (threshold: ${TxRetryWarningPct}%)")
            }
        }

        # --- WAN uptime ---
        if ($pct -and $null -ne $pct.wanUptime) {
            $wanUptime = [double]$pct.wanUptime
            if ($wanUptime -lt $WanUptimeWarningPct) {
                $upRound = [math]::Round($wanUptime, 2)
                $alerts.Add("[$label] WARNING: WAN uptime ${upRound}% is below threshold (${WanUptimeWarningPct}%)")
            }
        }

        # --- Critical notifications ---
        if ($counts -and $null -ne $counts.criticalNotification -and [int]$counts.criticalNotification -gt 0) {
            $n = [int]$counts.criticalNotification
            $alerts.Add("[$label] ALERT: $n critical notification(s) on controller")
        }
    }
    catch {
        $entryLabel = if ($networkId) { "$hostId|$networkId" } else { $hostId }
        $apiErrors.Add("[$entryLabel] API error: $($_.Exception.Message)")
    }
}

#endregion

#region OUTPUT

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
    exit 1
}

Write-DattoResult -Status 'All monitored sites healthy'
exit 0

#endregion
