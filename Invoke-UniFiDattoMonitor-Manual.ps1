<#
.SYNOPSIS
    UniFi network health monitor for Datto RMM — manual host list edition.
.DESCRIPTION
    Runs on any machine with outbound HTTPS to api.ui.com. Host IDs are defined
    directly in the CONFIGURATION region below — no Datto RMM API required.

    Alert output matches the Autotask ticket format: each alert includes a full
    detail block (alert summary, device details, network context, mitigation
    steps) so the ticket Datto creates from the alert already contains everything
    needed to investigate.

    LOCAL TESTING
        Set $TestMode = $true in the config block, or pass -Test on the command
        line, to get verbose colour-coded output. The final STATUS block is still
        printed exactly as Datto RMM would receive it.

            .\Invoke-UniFiDattoMonitor-Manual.ps1 -Test

    UnifiSiteKeys format examples:
        HostID only          : @{ HostId = 'abc123';         NetworkId = $null }
        Host + specific net  : @{ HostId = 'abc123';         NetworkId = 'net456' }

    Exit codes:
        0 — all sites healthy
        1 — one or more alert conditions detected, or a fatal error occurred
#>

param(
    [switch]$Test   # Verbose local output — or set $TestMode = $true below
)

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

$UnifiApiBase = 'https://api.ui.com/v1'

# UniFi Cloud API key from account.ui.com
$UnifiApiKey  = 'YOUR_UNIFI_API_KEY_HERE'
# $UnifiApiKey = $env:CS_UnifiApiKey   # <- uncomment to use a Datto global variable instead

# Set to $true to enable verbose local output without passing -Test on the command line
$TestMode = $false

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
    # Add more entries here...
)

#endregion

#region HELPERS

$TestMode = $TestMode -or $Test

function Write-DattoResult {
    param([string]$Status)
    Write-Host '<-Start Result->'
    Write-Host "STATUS=$Status"
    Write-Host '<-End Result->'
}

function Write-TestInfo    { param([string]$Msg) if ($TestMode) { Write-Host "[INFO]    $Msg" -ForegroundColor Cyan } }
function Write-TestOk      { param([string]$Msg) if ($TestMode) { Write-Host "[OK]      $Msg" -ForegroundColor Green } }
function Write-TestAlert   { param([string]$Msg) if ($TestMode) { Write-Host "[ALERT]   $Msg" -ForegroundColor Red } }
function Write-TestWarning { param([string]$Msg) if ($TestMode) { Write-Host "[WARNING] $Msg" -ForegroundColor Yellow } }

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
        if ($status -eq 401 -or $status -eq 403) { throw "UniFi API authentication failed (HTTP $status). Check UnifiApiKey." }
        elseif ($status -ge 500)                  { throw "UniFi API server error (HTTP $status) for '$Endpoint'." }
        else                                       { throw "UniFi API unreachable at '$uri': $($_.Exception.Message)" }
    }
    catch { throw "UniFi unexpected error calling '$uri': $($_.Exception.Message)" }
}

function Get-HostName {
    # hostName lives in the /v1/devices wrapper (data[].hostName), not on /v1/hosts/{id}
    param([string]$HostId)
    try {
        $encodedId = [System.Uri]::EscapeDataString($HostId)
        $resp      = Invoke-UniFiRequest -Endpoint "/devices?hostIds[]=$encodedId&pageSize=1"
        $wrapper   = ($resp.data | Where-Object { $_.hostId -eq $HostId }) | Select-Object -First 1
        if ($wrapper -and $wrapper.hostName) { return $wrapper.hostName }
    }
    catch { }
    return $HostId
}

function Get-AllUniFiSites {
    $all = [System.Collections.Generic.List[object]]::new()
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
    $all = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null
    do {
        $encodedId = [System.Uri]::EscapeDataString($HostId)
        $qs        = "hostIds[]=$encodedId&pageSize=100"
        if ($nextToken) { $qs += "&nextToken=$([System.Uri]::EscapeDataString($nextToken))" }
        $uri    = "$UnifiApiBase/devices?$qs"
        $uriObj = New-Object System.Uri($uri, $true)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = [System.Net.WebClient]::new()
        $wc.Headers.Add('Accept', 'application/json')
        $wc.Headers.Add('X-API-Key', $UnifiApiKey)
        try {
            $response = $wc.DownloadString($uriObj) | ConvertFrom-Json
        }
        catch { throw "Failed to retrieve devices for host '$HostId': $($_.Exception.Message)" }
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
    param([object[]]$AllSites, [string]$HostId, [string]$NetworkId)
    $hostSites = @($AllSites | Where-Object { $_.hostId -eq $HostId })
    if ($NetworkId) {
        $match = $hostSites | Where-Object {
            ($_.id -and $_.id -eq $NetworkId) -or
            ($_.meta -and $_.meta.name -and $_.meta.name -eq $NetworkId)
        } | Select-Object -First 1
        if ($match) {
            $networkName = if ($match.meta -and $match.meta.desc) { $match.meta.desc }
                           elseif ($match.meta -and $match.meta.name) { $match.meta.name }
                           else { $NetworkId }
            return @{ Site = $match; NetworkName = $networkName }
        }
        Write-TestWarning "NetworkId '$NetworkId' not matched for host '$HostId' — using first available site."
    }
    $first = $hostSites | Select-Object -First 1
    $networkName = if ($first -and $first.meta -and $first.meta.desc) { $first.meta.desc }
                   elseif ($first -and $first.meta -and $first.meta.name) { $first.meta.name }
                   else { 'Unknown Network' }
    return @{ Site = $first; NetworkName = $networkName }
}

function Get-MitigationSteps {
    param([string]$AlertType)
    switch ($AlertType) {
        'DeviceOffline' { return @"
1. Check physical power and cabling to the device.
2. Attempt a remote reboot via UniFi Network Console: Devices -> select device -> Restart.
3. If the device does not come back online within 10 minutes, escalate to an on-site visit.
4. Check for upstream switch or PoE injector failures if the device is PoE-powered.
"@ }
        'MultipleDevicesOffline' { return @"
1. Treat as a potential site-wide outage. Attempt to contact the site directly.
2. Verify ISP circuit status and check for power outages at the premises.
3. Check the gateway device (UDM/UDR/USG) first — all other devices depend on it.
4. Escalate to an on-site visit if remote diagnostics are inconclusive.
"@ }
        { $_ -in @('TxRetryWarning','TxRetryCritical') } { return @"
1. Log in to UniFi Network Console -> Analytics and check WAN graphs for the affected period.
2. Contact the ISP to report packet loss and request a line check.
3. Check WAN cable and SFP module if applicable.
4. Consider failing over to a secondary WAN if available.
"@ }
        'WanUptimeDegraded' { return @"
1. Check UniFi Network Console -> Dashboard -> WAN status for current connectivity.
2. Confirm ISP service status for the ASN listed in this alert.
3. Check gateway device logs for disconnection events.
4. Engage ISP support if the issue is not self-resolved.
"@ }
        'CriticalNotifications' { return @"
1. Log in to UniFi Network Console -> Notifications tab to view the specific alerts.
2. Triage each notification and resolve or acknowledge as appropriate.
3. If notifications relate to hardware faults, escalate per the offline device procedure.
"@ }
        default { return @"
1. Review the alert details and investigate the affected device or site.
2. Consult the UniFi Network Console for current device status.
3. Escalate if the issue cannot be resolved remotely.
"@ }
    }
}

function Build-AlertDetail {
    param(
        [hashtable]$Alert
    )

    $device = $Alert.Device
    $site   = $Alert.Site
    $label  = $Alert.Label
    $ts     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    $devName     = if ($device -and $device.name)    { $device.name }    else { 'N/A' }
    $devMac      = if ($device -and $device.mac)     { $device.mac }     else { 'N/A' }
    $devIp       = if ($device -and $device.ip)      { $device.ip }      else { 'N/A' }
    $devModel    = if ($device -and $device.model)   { $device.model }   else { 'N/A' }
    $devFirmware = if ($device -and $device.version) { $device.version } else { 'N/A' }

    $stats      = if ($site -and $site.statistics)                  { $site.statistics }   else { $null }
    $pct        = if ($stats -and $stats.percentages)               { $stats.percentages } else { $null }
    $ispInfo    = if ($stats -and $stats.ispInfo)                   { $stats.ispInfo }      else { $null }
    $counts     = if ($stats -and $stats.counts)                    { $stats.counts }       else { $null }
    $wansObj    = if ($stats -and $stats.wans -and $stats.wans.WAN) { $stats.wans.WAN }     else { $null }

    $wanUptime    = if ($pct    -and $null -ne $pct.wanUptime)         { "$([math]::Round([double]$pct.wanUptime, 2))%" }  else { 'N/A' }
    $txRetryVal   = if ($pct    -and $null -ne $pct.txRetry)           { "$([math]::Round([double]$pct.txRetry, 2))%" }    else { 'N/A' }
    $ispName      = if ($ispInfo -and $ispInfo.name)                   { $ispInfo.name }                                    else { 'N/A' }
    $externalIp   = if ($wansObj -and $wansObj.externalIp)             { $wansObj.externalIp }                              else { 'N/A' }
    $wiredClients = if ($counts  -and $null -ne $counts.wiredClient)   { $counts.wiredClient.ToString() }                   else { 'N/A' }
    $wifiClients  = if ($counts  -and $null -ne $counts.wifiClient)    { $counts.wifiClient.ToString() }                    else { 'N/A' }
    $siteHostId   = if ($site -and $site.hostId)                       { $site.hostId }                                     else { 'N/A' }

    $alertSummary = switch ($Alert.AlertType) {
        'DeviceOffline'         { "Device '$devName' at '$label' is reporting as offline and may require immediate attention." }
        'MultipleDevicesOffline'{ "$($Alert.Extra.OfflineCount) network devices are offline simultaneously at '$label' ($($Alert.Extra.NameList)), indicating a potential site-wide outage." }
        'TxRetryWarning'        { "Elevated WAN packet retry rate ($txRetryVal) detected at '$label', indicating potential network degradation." }
        'TxRetryCritical'       { "Critical WAN packet retry rate ($txRetryVal) detected at '$label'. Immediate investigation is recommended." }
        'WanUptimeDegraded'     { "WAN uptime ($wanUptime) at '$label' has fallen below the ${WanUptimeWarningPct}% threshold, indicating connectivity instability." }
        'CriticalNotifications' { "$($Alert.Extra.Count) critical notification(s) are present on the UniFi controller for '$label'." }
        default                 { "An alert condition has been detected at '$label' requiring review." }
    }

    $mitigation = Get-MitigationSteps -AlertType $Alert.AlertType

    return @"
ALERT SUMMARY
=============
$alertSummary

DEVICE DETAILS
==============
Device Name   : $devName
MAC Address   : $devMac
IP Address    : $devIp
Model         : $devModel
Firmware      : $devFirmware
Site          : $label
Host ID       : $siteHostId

NETWORK CONTEXT
===============
WAN Uptime    : $wanUptime
TX Retry Rate : $txRetryVal
ISP Name      : $ispName
External IP   : $externalIp
Wired Clients : $wiredClients
Wifi Clients  : $wifiClients

DETECTED AT
===========
$ts

RECOMMENDED MITIGATION
======================
$mitigation
FURTHER INFORMATION
===================
https://help.ui.com/hc/en-us/categories/200320654-UniFi-Network
"@
}

#endregion

#region VALIDATION

if (-not $UnifiApiKey -or $UnifiApiKey -eq 'YOUR_UNIFI_API_KEY_HERE') {
    Write-DattoResult -Status 'CONFIGURATION ERROR: UnifiApiKey is not set.'
    exit 1
}
if (-not $HostEntries -or $HostEntries.Count -eq 0) {
    Write-DattoResult -Status 'CONFIGURATION ERROR: HostEntries is empty. Add at least one host ID.'
    exit 1
}

#endregion

#region ALERT EVALUATION

if ($TestMode) {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  UniFi Monitor — Test Mode' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
}

$alerts    = [System.Collections.Generic.List[hashtable]]::new()
$apiErrors = [System.Collections.Generic.List[string]]::new()

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

foreach ($entry in $HostEntries) {
    $hostId    = $entry.HostId
    $networkId = $entry.NetworkId

    try {
        $hostName      = Get-HostName -HostId $hostId
        $networkResult = Resolve-Network -AllSites $allUniFiSites -HostId $hostId -NetworkId $networkId
        $site          = $networkResult.Site
        $networkName   = $networkResult.NetworkName
        $label         = "$hostName > $networkName"

        if ($TestMode) {
            Write-Host ''
            Write-Host "  --- $label ---" -ForegroundColor White
        }

        $devices = @(Get-Devices -HostId $hostId)
        Write-TestInfo "$($devices.Count) device(s) on host '$hostName'."

        if ($TestMode) {
            foreach ($dev in $devices) {
                $devName   = if ($dev.name)          { $dev.name }          else { $dev.model }
                $devStatus = if ($dev.status)         { $dev.status }        else { 'unknown' }
                $devFw     = if ($dev.firmwareStatus) { $dev.firmwareStatus } else { 'n/a' }
                $color     = if ($devStatus -eq 'online') { 'Green' } else { 'Red' }
                Write-Host ("    {0,-30} status={1,-8} firmware={2}" -f $devName, $devStatus, $devFw) -ForegroundColor $color
            }
        }

        $stats  = if ($site -and $site.statistics)    { $site.statistics }   else { $null }
        $pct    = if ($stats -and $stats.percentages) { $stats.percentages } else { $null }
        $counts = if ($stats -and $stats.counts)      { $stats.counts }      else { $null }

        if ($TestMode -and $pct) {
            $txVal  = if ($null -ne $pct.txRetry)  { "$([math]::Round($pct.txRetry,1))%" }  else { 'n/a' }
            $wanVal = if ($null -ne $pct.wanUptime) { "$([math]::Round($pct.wanUptime,2))%" } else { 'n/a' }
            Write-TestInfo "  TX retry: $txVal   WAN uptime: $wanVal"
        }

        # --- Offline devices ---
        $offlineDevices = @($devices | Where-Object { $_.status -eq 'offline' })
        $offlineCount   = if ($counts -and $null -ne $counts.offlineDevice) { [int]$counts.offlineDevice } else { $offlineDevices.Count }

        if ($offlineCount -gt 1) {
            $nameList = if ($offlineDevices.Count -gt 0) {
                ($offlineDevices | ForEach-Object { if ($_.name) { $_.name } else { $_.model } }) -join ', '
            } else { 'multiple devices' }
            $alertObj = @{
                AlertType = 'MultipleDevicesOffline'
                Title     = "NETWORK OUTAGE -- ${label}: $offlineCount devices offline"
                Label     = $label; Site = $site; Device = $null
                Extra     = @{ OfflineCount = $offlineCount; NameList = $nameList }
            }
            $alerts.Add($alertObj)
            Write-TestAlert "$($alertObj.Title) — $nameList"
        }
        elseif ($offlineCount -eq 1) {
            $dev  = $offlineDevices | Select-Object -First 1
            $name = if ($dev -and $dev.name) { $dev.name } elseif ($dev -and $dev.model) { $dev.model } else { 'Unknown' }
            $alertObj = @{
                AlertType = 'DeviceOffline'
                Title     = "NETWORK ALERT -- ${label}: $name is offline"
                Label     = $label; Site = $site; Device = $dev
                Extra     = @{}
            }
            $alerts.Add($alertObj)
            Write-TestAlert $alertObj.Title
        }
        else {
            Write-TestOk "[$label] All devices online."
        }

        # --- TX retry rate ---
        if ($pct -and $null -ne $pct.txRetry) {
            $txRetry = [double]$pct.txRetry
            $txRound = [math]::Round($txRetry, 1)
            if ($txRetry -gt $TxRetryCriticalPct) {
                $alertObj = @{
                    AlertType = 'TxRetryCritical'
                    Title     = "NETWORK CRITICAL -- ${label}: WAN retry rate ${txRound}%"
                    Label     = $label; Site = $site; Device = $null; Extra = @{}
                }
                $alerts.Add($alertObj); Write-TestAlert $alertObj.Title
            }
            elseif ($txRetry -gt $TxRetryWarningPct) {
                $alertObj = @{
                    AlertType = 'TxRetryWarning'
                    Title     = "NETWORK DEGRADED -- ${label}: Elevated WAN retry rate ${txRound}%"
                    Label     = $label; Site = $site; Device = $null; Extra = @{}
                }
                $alerts.Add($alertObj); Write-TestWarning $alertObj.Title
            }
            else { Write-TestOk "[$label] TX retry ${txRound}% — within threshold." }
        }

        # --- WAN uptime ---
        if ($pct -and $null -ne $pct.wanUptime) {
            $wanUptime = [double]$pct.wanUptime
            if ($wanUptime -lt $WanUptimeWarningPct) {
                $upRound  = [math]::Round($wanUptime, 2)
                $alertObj = @{
                    AlertType = 'WanUptimeDegraded'
                    Title     = "WAN ISSUE -- ${label}: Uptime ${upRound}% below ${WanUptimeWarningPct}% threshold"
                    Label     = $label; Site = $site; Device = $null; Extra = @{}
                }
                $alerts.Add($alertObj); Write-TestWarning $alertObj.Title
            }
            else { Write-TestOk "[$label] WAN uptime $([math]::Round($wanUptime,2))% — within threshold." }
        }

        # --- Critical notifications ---
        if ($counts -and $null -ne $counts.criticalNotification -and [int]$counts.criticalNotification -gt 0) {
            $n        = [int]$counts.criticalNotification
            $alertObj = @{
                AlertType = 'CriticalNotifications'
                Title     = "ALERT -- ${label}: $n critical notification(s) on controller"
                Label     = $label; Site = $site; Device = $null
                Extra     = @{ Count = $n }
            }
            $alerts.Add($alertObj); Write-TestAlert $alertObj.Title
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

if ($TestMode) {
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
    $parts = [System.Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($alertObj in $alerts) {
        $i++
        $detail = Build-AlertDetail -Alert $alertObj
        $header = if ($alerts.Count -gt 1) { "ALERT $i OF $($alerts.Count): $($alertObj.Title)" } else { $alertObj.Title }
        $parts.Add("$header`n`n$detail")
    }
    $separator = "`n" + ('=' * 80) + "`n"
    $summary   = $parts -join $separator
    if ($apiErrors.Count -gt 0) {
        $summary += "`n`nAPI ERRORS`n==========`n$($apiErrors -join "`n")"
    }
    Write-DattoResult -Status $summary
    if ($TestMode) { Write-Host ''; Write-Host "Exit code: 1 (alert)" -ForegroundColor Red }
    exit 1
}

Write-DattoResult -Status 'All sites healthy'
if ($TestMode) { Write-Host ''; Write-Host "Exit code: 0 (healthy)" -ForegroundColor Green }
exit 0

#endregion
