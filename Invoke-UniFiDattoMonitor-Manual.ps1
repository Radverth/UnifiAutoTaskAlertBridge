<#
.SYNOPSIS
    UniFi network health monitor for Datto RMM — manual host list edition.
.DESCRIPTION
    Runs on any machine with outbound HTTPS to api.ui.com. Host/network IDs
    are defined directly in the CONFIGURATION region below — no Datto RMM
    API required. Deploy this as a Datto RMM monitor component on a single
    central machine and it will check every listed host on every run.

    To add a site, add an entry to $HostEntries. Use the UniFi host ID from
    account.ui.com (the long alphanumeric string shown in the URL or host list).

    UnifiSiteKeys format examples:
        HostID only          : @{ HostId = 'abc123';           NetworkId = $null }
        Host + specific net  : @{ HostId = 'abc123';           NetworkId = 'net456' }

    Exit codes:
        0 — all sites healthy
        1 — one or more alert conditions detected, or a fatal error occurred
#>

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

$UnifiApiBase = 'https://api.ui.com/v1'

# UniFi Cloud API key from account.ui.com
$UnifiApiKey  = 'YOUR_UNIFI_API_KEY_HERE'
# $UnifiApiKey = $env:CS_UnifiApiKey   # <- uncomment to use a Datto global variable instead

# Alert thresholds
$TxRetryWarningPct   = 50.0
$TxRetryCriticalPct  = 55.0
$WanUptimeWarningPct = 99.0

# Host/network list — add one entry per host or host+network pair.
# HostId    : the UniFi host ID (from account.ui.com)
# NetworkId : the UniFi network/site ID, or $null to monitor all networks on the host
$HostEntries = @(
    @{ HostId = 'HOST_ID_1'; NetworkId = $null      }
    @{ HostId = 'HOST_ID_2'; NetworkId = 'NET_ID_2' }
    # Add more entries here…
)

#endregion

#region VALIDATION

function Write-DattoResult {
    param([string]$Status)
    Write-Host '<-Start Result->'
    Write-Host "STATUS=$Status"
    Write-Host '<-End Result->'
}

if (-not $UnifiApiKey -or $UnifiApiKey -eq 'YOUR_UNIFI_API_KEY_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: UnifiApiKey is not set.'
    exit 1
}

if (-not $HostEntries -or $HostEntries.Count -eq 0) {
    Write-DattoResult -Status 'CONFIGURATION ERROR: HostEntries is empty. Add at least one host ID.'
    exit 1
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
            $networkName = if ($match.meta -and $match.meta.desc)     { $match.meta.desc }
                           elseif ($match.meta -and $match.meta.name) { $match.meta.name }
                           else { $NetworkId }
            return @{ Site = $match; NetworkName = $networkName }
        }
        Write-Host "WARNING: NetworkId '$NetworkId' not matched for host '$HostId'. Using first available site."
    }

    $first = $hostSites | Select-Object -First 1
    $networkName = if ($first -and $first.meta -and $first.meta.desc)     { $first.meta.desc }
                   elseif ($first -and $first.meta -and $first.meta.name) { $first.meta.name }
                   else { 'Unknown Network' }
    return @{ Site = $first; NetworkName = $networkName }
}

#endregion

#region ALERT EVALUATION

$alerts    = [System.Collections.Generic.List[string]]::new()
$apiErrors = [System.Collections.Generic.List[string]]::new()

$allUniFiSites = $null
try {
    $allUniFiSites = @(Get-AllUniFiSites)
}
catch {
    Write-DattoResult -Status "UNIFI API ERROR: Could not retrieve sites — $($_.Exception.Message)"
    exit 1
}

foreach ($entry in $HostEntries) {
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

        $stats  = if ($site -and $site.statistics)    { $site.statistics }    else { $null }
        $pct    = if ($stats -and $stats.percentages) { $stats.percentages }  else { $null }
        $counts = if ($stats -and $stats.counts)      { $stats.counts }       else { $null }

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

Write-DattoResult -Status 'All sites healthy'
exit 0

#endregion
