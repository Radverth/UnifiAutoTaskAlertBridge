<#
.SYNOPSIS
    UniFi Cloud API to Autotask PSA alert bridge for MSP network monitoring.
.DESCRIPTION
    Queries the UniFi Cloud API for network events and raises formatted tickets
    in Autotask PSA for MSP-relevant conditions.
.PARAMETER TestMode
    Run in preview mode — no tickets will be created.
.PARAMETER CheckDeps
    Check dependencies and configuration, then exit.
#>

[CmdletBinding()]
param(
    [switch]$TestMode,
    [switch]$CheckDeps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

$Config = @{
    # UniFi Cloud API key (generate in ui.com account settings)
    UnifiApiKey             = ''

    # UniFi Cloud API base URL — no trailing slash
    UnifiApiBase            = 'https://api.ui.com/v1'

    # Number of records to request per API page
    UnifiPageSize           = 100

    # Autotask zone number (check your Autotask URL, e.g. webservices1 = zone '1')
    AutotaskZone            = '1'

    # Autotask API credentials
    AutotaskApiUser         = ''
    AutotaskApiSecret       = ''
    AutotaskIntegrationCode = ''

    # Default Autotask company name when no site mapping is found
    DefaultAccountName      = 'Affinity IT'

    # Autotask ticket field values
    TicketQueueId           = 29683994   # integer queue ID
    TicketStatusNew         = 1          # status ID for "New"
    TicketSourceMonitor     = 8          # source ID for "Monitoring Alert"

    # Status IDs considered closed/resolved/cancelled — used for duplicate suppression
    ClosedStatusIds         = @(5, 9, 10)

    # TX retry rate thresholds (percentage)
    TxRetryWarningPct       = 5.0
    TxRetryCriticalPct      = 15.0

    # WAN uptime threshold (percentage)
    WanUptimeWarningPct     = 99.9

    # UniFi site name (lowercase) → Autotask company name
    # Add entries as needed: 'site-name' = 'Company Name in Autotask'
    SiteMapping             = @{
        'default' = 'Affinity IT'
    }
}

#endregion CONFIGURATION

#region DEPENDENCIES

function Test-Dependencies {
    [CmdletBinding()]
    param()

    Write-Host "`n===== DEPENDENCY CHECK =====" -ForegroundColor Cyan
    $allPass = $true

    # 1. PowerShell version >= 5.1
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -gt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -ge 1)) {
        Write-Host "[PASS] PowerShell version: $($psVersion.ToString())" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] PowerShell version $($psVersion.ToString()) is below minimum 5.1" -ForegroundColor Red
        $allPass = $false
    }

    # 2. TLS 1.2 available
    try {
        $availableProtocols = [System.Net.SecurityProtocolType]::Tls12
        if ($availableProtocols) {
            Write-Host "[PASS] TLS 1.2 is available" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "[FAIL] TLS 1.2 is not available on this system" -ForegroundColor Red
        $allPass = $false
    }

    # 3. Invoke-RestMethod available
    if (Get-Command -Name 'Invoke-RestMethod' -ErrorAction SilentlyContinue) {
        Write-Host "[PASS] Invoke-RestMethod cmdlet is available" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] Invoke-RestMethod cmdlet is not available" -ForegroundColor Red
        $allPass = $false
    }

    # 4. Both API keys non-empty
    if (-not [string]::IsNullOrWhiteSpace($Config.UnifiApiKey)) {
        Write-Host "[PASS] UniFi API key is set" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] UniFi API key (Config.UnifiApiKey) is empty" -ForegroundColor Red
        $allPass = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.AutotaskApiSecret)) {
        Write-Host "[PASS] Autotask API secret is set" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] Autotask API secret (Config.AutotaskApiSecret) is empty" -ForegroundColor Red
        $allPass = $false
    }

    # 5. SiteMapping has >= 1 entry
    if ($Config.SiteMapping -and $Config.SiteMapping.Count -ge 1) {
        Write-Host "[PASS] SiteMapping has $($Config.SiteMapping.Count) entry/entries" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] SiteMapping is empty — add at least one site-to-company mapping" -ForegroundColor Red
        $allPass = $false
    }

    # 6. DefaultAccountName set
    if (-not [string]::IsNullOrWhiteSpace($Config.DefaultAccountName)) {
        Write-Host "[PASS] DefaultAccountName is set: '$($Config.DefaultAccountName)'" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] DefaultAccountName is empty" -ForegroundColor Red
        $allPass = $false
    }

    Write-Host "============================`n" -ForegroundColor Cyan

    if ($allPass) {
        Write-Host "All dependency checks passed." -ForegroundColor Green
    }
    else {
        Write-Host "One or more dependency checks failed. Please review the configuration." -ForegroundColor Red
    }

    return $allPass
}

#endregion DEPENDENCIES

#region UNIFI-API

function Invoke-UniFiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [hashtable]$QueryParams = @{}
    )

    # Enforce TLS 1.2
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $headers = @{
        'Accept'    = 'application/json'
        'X-API-Key' = $Config.UnifiApiKey
    }

    $uri = "$($Config.UnifiApiBase)$Endpoint"

    if ($QueryParams.Count -gt 0) {
        $queryString = ($QueryParams.GetEnumerator() | ForEach-Object {
            "$([System.Uri]::EscapeDataString($_.Key))=$([System.Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri = "${uri}?${queryString}"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -ContentType 'application/json'
        return $response
    }
    catch {
        $statusCode = $null
        $body = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
            }
            catch { $body = '(unable to read response body)' }
        }
        Write-Host "[ERROR] UniFi API request failed: $uri | Status: $statusCode | Body: $body" -ForegroundColor Red
        throw
    }
}

function Get-UniFiSites {
    [CmdletBinding()]
    param()

    $allSites = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null
    $pageSize = $Config.UnifiPageSize

    do {
        $params = @{ pageSize = $pageSize }
        if ($nextToken) { $params['nextToken'] = $nextToken }

        try {
            $response = Invoke-UniFiRequest -Endpoint '/sites' -QueryParams $params
            if ($response.data) {
                foreach ($site in $response.data) {
                    $allSites.Add($site)
                }
            }
            elseif ($response -is [array]) {
                foreach ($site in $response) {
                    $allSites.Add($site)
                }
            }
            $nextToken = if ($response.nextToken) { $response.nextToken } else { $null }
        }
        catch {
            Write-Host "[ERROR] Failed to retrieve UniFi sites. Aborting site enumeration." -ForegroundColor Red
            return $allSites
        }
    } while ($nextToken)

    return $allSites
}

function Get-UniFiDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostId
    )

    $allDevices = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null
    $pageSize = $Config.UnifiPageSize

    do {
        $params = @{
            'hostIds[]' = $HostId
            'pageSize'  = $pageSize
        }
        if ($nextToken) { $params['nextToken'] = $nextToken }

        try {
            $response = Invoke-UniFiRequest -Endpoint '/devices' -QueryParams $params
            if ($response.data) {
                foreach ($device in $response.data) {
                    $allDevices.Add($device)
                }
            }
            elseif ($response -is [array]) {
                foreach ($device in $response) {
                    $allDevices.Add($device)
                }
            }
            $nextToken = if ($response.nextToken) { $response.nextToken } else { $null }
        }
        catch {
            Write-Host "[ERROR] Failed to retrieve devices for host '$HostId'." -ForegroundColor Red
            return $allDevices
        }
    } while ($nextToken)

    return $allDevices
}

#endregion UNIFI-API

#region AUTOTASK-API

function Get-AutotaskHeaders {
    return @{
        'ApiIntegrationCode' = $Config.AutotaskIntegrationCode
        'UserName'           = $Config.AutotaskApiUser
        'Secret'             = $Config.AutotaskApiSecret
        'Content-Type'       = 'application/json'
        'Accept'             = 'application/json'
    }
}

function Get-AutotaskBaseUrl {
    return "https://webservices$($Config.AutotaskZone).autotask.net/ATServicesRest/V1.0"
}

function Invoke-AutotaskRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [ValidateSet('GET', 'POST', 'PUT', 'PATCH')]
        [string]$Method = 'GET',

        [string]$Body = $null,

        [string]$SearchFilter = $null
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $headers = Get-AutotaskHeaders
    $uri = "$(Get-AutotaskBaseUrl)$Endpoint"

    if ($SearchFilter) {
        $encoded = [System.Uri]::EscapeDataString($SearchFilter)
        $uri = "${uri}?search=${encoded}"
    }

    $splat = @{
        Uri     = $uri
        Headers = $headers
        Method  = $Method
    }

    if ($Body -and $Method -ne 'GET') {
        $splat['Body'] = $Body
    }

    try {
        $response = Invoke-RestMethod @splat
        return $response
    }
    catch {
        $statusCode = $null
        $responseBody = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
            }
            catch { $responseBody = '(unable to read response body)' }
        }
        Write-Host "[ERROR] Autotask API request failed: $uri | Method: $Method | Status: $statusCode | Body: $responseBody" -ForegroundColor Red
        throw
    }
}

function Get-AutotaskCompanyId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CompanyName
    )

    $filter = @{
        filter = @(
            @{ field = 'companyName'; op = 'eq'; value = $CompanyName }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-AutotaskRequest -Endpoint '/Companies' -SearchFilter $filter
        if ($response.items -and $response.items.Count -gt 0) {
            return $response.items[0].id
        }
        return $null
    }
    catch {
        Write-Host "[ERROR] Failed to look up Autotask company: '$CompanyName'" -ForegroundColor Red
        return $null
    }
}

function Get-AutotaskPrimaryContact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$CompanyId
    )

    $filter = @{
        filter = @(
            @{ field = 'companyID'; op = 'eq'; value = $CompanyId },
            @{ field = 'isActive'; op = 'eq'; value = $true }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-AutotaskRequest -Endpoint '/Contacts' -SearchFilter $filter
        if ($response.items -and $response.items.Count -gt 0) {
            return $response.items[0]
        }
        return $null
    }
    catch {
        Write-Host "[ERROR] Failed to look up primary contact for company ID $CompanyId" -ForegroundColor Red
        return $null
    }
}

function New-AutotaskTicket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TicketData
    )

    $body = $TicketData | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-AutotaskRequest -Endpoint '/Tickets' -Method 'POST' -Body $body
        return $response
    }
    catch {
        Write-Host "[ERROR] Failed to create Autotask ticket: $($TicketData.title)" -ForegroundColor Red
        return $null
    }
}

function Get-ExistingOpenTicket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [int]$CompanyId,

        [Parameter(Mandatory)]
        [int[]]$ClosedStatusIds
    )

    # Build filter: title contains, companyID eq, and status noteq each closed status
    $filterConditions = [System.Collections.Generic.List[object]]::new()
    $filterConditions.Add(@{ field = 'title';     op = 'contains'; value = $Title })
    $filterConditions.Add(@{ field = 'companyID'; op = 'eq';       value = $CompanyId })

    foreach ($statusId in $ClosedStatusIds) {
        $filterConditions.Add(@{ field = 'status'; op = 'noteq'; value = $statusId })
    }

    $filter = @{
        filter = $filterConditions.ToArray()
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-AutotaskRequest -Endpoint '/Tickets' -SearchFilter $filter
        if ($response.items -and $response.items.Count -gt 0) {
            return $response.items[0]
        }
        return $null
    }
    catch {
        Write-Host "[ERROR] Failed to check for existing open ticket: '$Title'" -ForegroundColor Red
        return $null
    }
}

#endregion AUTOTASK-API

#region ALERT-EVALUATION

function Invoke-AlertEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Site,

        [Parameter(Mandatory)]
        [object[]]$Devices
    )

    $alerts = [System.Collections.Generic.List[object]]::new()
    $siteName = if ($Site.name) { $Site.name } else { 'Unknown Site' }

    # Count offline and gateway devices for multi-device checks
    $offlineDevices  = @($Devices | Where-Object { $_.status -eq 'offline' })
    $gatewayDevices  = @($Devices | Where-Object {
        $_.type -eq 'gateway' -or $_.type -eq 'ugw' -or $_.type -eq 'udm' -or
        $_.type -eq 'udr' -or $_.isGateway -eq $true
    })

    # Per-device alerts
    foreach ($device in $Devices) {
        $deviceName = if ($device.name) { $device.name } elseif ($device.model) { $device.model } else { 'Unknown Device' }

        # Alert 1: Device Offline
        if ($device.status -eq 'offline') {
            $alerts.Add([pscustomobject]@{
                AlertType  = 'DeviceOffline'
                Priority   = 'Critical'
                Title      = "NETWORK ALERT -- ${siteName}: ${deviceName} is offline"
                SiteName   = $siteName
                DeviceName = $deviceName
                DeviceData = $device
                SiteData   = $Site
            })
        }

        # Alert 2: Firmware Update Available
        if ($device.firmwareStatus -and $device.firmwareStatus -ne 'upToDate') {
            $alerts.Add([pscustomobject]@{
                AlertType  = 'FirmwareUpdateAvailable'
                Priority   = 'High'
                Title      = "MAINTENANCE REQUIRED -- ${siteName}: Firmware update available for ${deviceName}"
                SiteName   = $siteName
                DeviceName = $deviceName
                DeviceData = $device
                SiteData   = $Site
            })
        }

        # Alert 3 & 4: TX Retry Rate
        $txRetryRate = $null
        if ($null -ne $device.txRetryRate) {
            $txRetryRate = [double]$device.txRetryRate
        }
        elseif ($null -ne $device.statistics -and $null -ne $device.statistics.txRetryRate) {
            $txRetryRate = [double]$device.statistics.txRetryRate
        }

        if ($null -ne $txRetryRate) {
            $rateRounded = [math]::Round($txRetryRate, 1)

            if ($txRetryRate -gt $Config.TxRetryCriticalPct) {
                $alerts.Add([pscustomobject]@{
                    AlertType  = 'TxRetryCritical'
                    Priority   = 'Critical'
                    Title      = "NETWORK CRITICAL -- ${siteName}: Critical WAN retry rate (${rateRounded}%)"
                    SiteName   = $siteName
                    DeviceName = $deviceName
                    DeviceData = $device
                    SiteData   = $Site
                })
            }
            elseif ($txRetryRate -gt $Config.TxRetryWarningPct) {
                $alerts.Add([pscustomobject]@{
                    AlertType  = 'TxRetryWarning'
                    Priority   = 'Medium'
                    Title      = "NETWORK DEGRADED -- ${siteName}: Elevated WAN retry rate (${rateRounded}%)"
                    SiteName   = $siteName
                    DeviceName = $deviceName
                    DeviceData = $device
                    SiteData   = $Site
                })
            }
        }
    }

    # Site-level alerts

    # Alert 5: WAN Uptime Degraded
    $wanUptime = $null
    if ($null -ne $Site.wanUptime) {
        $wanUptime = [double]$Site.wanUptime
    }
    elseif ($null -ne $Site.statistics -and $null -ne $Site.statistics.wanUptime) {
        $wanUptime = [double]$Site.statistics.wanUptime
    }

    if ($null -ne $wanUptime -and $wanUptime -lt $Config.WanUptimeWarningPct) {
        $uptimeRounded = [math]::Round($wanUptime, 2)
        $alerts.Add([pscustomobject]@{
            AlertType  = 'WanUptimeDegraded'
            Priority   = 'High'
            Title      = "WAN ISSUE -- ${siteName}: WAN uptime below threshold (${uptimeRounded}%)"
            SiteName   = $siteName
            DeviceName = 'N/A'
            DeviceData = $null
            SiteData   = $Site
        })
    }

    # Alert 6: Critical Notifications Present
    $criticalNotifCount = $null
    if ($null -ne $Site.criticalNotifications) {
        if ($Site.criticalNotifications -is [array]) {
            $criticalNotifCount = $Site.criticalNotifications.Count
        }
        elseif ($Site.criticalNotifications -is [int] -or $Site.criticalNotifications -is [long]) {
            $criticalNotifCount = [int]$Site.criticalNotifications
        }
    }
    elseif ($null -ne $Site.statistics -and $null -ne $Site.statistics.criticalNotifications) {
        $criticalNotifCount = [int]$Site.statistics.criticalNotifications
    }

    if ($null -ne $criticalNotifCount -and $criticalNotifCount -gt 0) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'CriticalNotificationsPresent'
            Priority   = 'High'
            Title      = "ALERT -- ${siteName}: ${criticalNotifCount} critical notification(s) on controller"
            SiteName   = $siteName
            DeviceName = 'N/A'
            DeviceData = $null
            SiteData   = $Site
        })
    }

    # Alert 7: Internet Issues Detected
    $internetIssues = $null
    if ($null -ne $Site.internetIssues) {
        $internetIssues = $Site.internetIssues
    }
    elseif ($null -ne $Site.statistics -and $null -ne $Site.statistics.internetIssues) {
        $internetIssues = $Site.statistics.internetIssues
    }

    $hasInternetIssues = $false
    if ($internetIssues -is [array] -and $internetIssues.Count -gt 0) {
        $hasInternetIssues = $true
    }
    elseif ($internetIssues -is [string] -and -not [string]::IsNullOrWhiteSpace($internetIssues)) {
        $hasInternetIssues = $true
    }
    elseif ($internetIssues -is [bool] -and $internetIssues) {
        $hasInternetIssues = $true
    }

    if ($hasInternetIssues) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'InternetIssuesDetected'
            Priority   = 'High'
            Title      = "CONNECTIVITY ISSUE -- ${siteName}: Internet issues detected by controller"
            SiteName   = $siteName
            DeviceName = 'N/A'
            DeviceData = $null
            SiteData   = $Site
        })
    }

    # Alert 8: Multiple Devices Offline
    if ($offlineDevices.Count -gt 1) {
        $count = $offlineDevices.Count
        $alerts.Add([pscustomobject]@{
            AlertType  = 'MultipleDevicesOffline'
            Priority   = 'Critical'
            Title      = "NETWORK OUTAGE -- ${siteName}: ${count} devices offline simultaneously"
            SiteName   = $siteName
            DeviceName = 'Multiple'
            DeviceData = $null
            SiteData   = $Site
        })
    }

    # Alert 9: No Gateway Device
    if ($Devices.Count -gt 0 -and $gatewayDevices.Count -eq 0) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'NoGatewayDevice'
            Priority   = 'Critical'
            Title      = "CRITICAL -- ${siteName}: No gateway device detected on site"
            SiteName   = $siteName
            DeviceName = 'N/A'
            DeviceData = $null
            SiteData   = $Site
        })
    }

    return $alerts.ToArray()
}

#endregion ALERT-EVALUATION

#region TICKET-BUILDER

function Get-MitigationSteps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AlertType
    )

    switch ($AlertType) {
        'DeviceOffline' {
            return @"
1. Check physical power and cabling to the device.
2. Attempt a remote reboot via UniFi Network Console: log in -> Devices -> select device -> Restart.
3. If the device does not come back online within 10 minutes, escalate to on-site visit.
4. Check for upstream switch or PoE injector failures if device is PoE-powered.
"@
        }
        'FirmwareUpdateAvailable' {
            return @"
1. Log in to UniFi Network Console -> Devices -> select device -> Firmware -> Upgrade.
2. Schedule the upgrade during a maintenance window to avoid user disruption.
3. Verify the device comes back online after upgrade and confirm firmware version in the Devices list.
4. If upgrade fails, perform a factory reset and re-adopt the device.
"@
        }
        { $_ -in @('TxRetryWarning', 'TxRetryCritical') } {
            return @"
1. Log in to UniFi Network Console -> Analytics -> check WAN graphs for the affected period.
2. Contact the ISP to report packet loss and request a line check.
3. Check WAN cable and SFP module if applicable.
4. Consider failing over to a secondary WAN if available.
"@
        }
        'WanUptimeDegraded' {
            return @"
1. Check UniFi Network Console -> Dashboard -> WAN status for current connectivity.
2. Confirm ISP service status for the ASN listed in the ticket.
3. Check gateway device logs for disconnection events.
4. Engage ISP support if the issue is not self-resolved.
"@
        }
        'CriticalNotificationsPresent' {
            return @"
1. Log in to UniFi Network Console -> Notifications tab to view the specific alerts.
2. Triage each notification and resolve or acknowledge as appropriate.
3. If notifications relate to hardware faults, escalate per the offline device procedure.
"@
        }
        { $_ -in @('InternetIssuesDetected', 'MultipleDevicesOffline', 'NoGatewayDevice') } {
            return @"
1. Treat as potential site-wide outage. Attempt to contact the site directly.
2. Verify ISP circuit status and check for power outages at the premises.
3. Check the gateway device (UDM/UDR/USG) first -- all other devices depend on it.
4. Escalate to on-site visit if remote diagnostics are inconclusive.
"@
        }
        default {
            return @"
1. Review the alert details and investigate the affected device or site.
2. Consult the UniFi Network Console for current device status.
3. Escalate if the issue cannot be resolved remotely.
"@
        }
    }
}

function Get-SafeValue {
    [CmdletBinding()]
    param(
        [object]$Object,
        [string]$Property,
        [string]$Default = 'N/A'
    )

    if ($null -eq $Object) { return $Default }
    $val = $Object.$Property
    if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
        return $Default
    }
    return $val.ToString()
}

function Build-TicketDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Alert
    )

    $device  = $Alert.DeviceData
    $site    = $Alert.SiteData
    $ts      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    # Device details
    $devName     = if ($device) { Get-SafeValue $device 'name' }     else { 'N/A' }
    $devMac      = if ($device) { Get-SafeValue $device 'mac' }      else { 'N/A' }
    $devIp       = if ($device) { Get-SafeValue $device 'ip' }       else { 'N/A' }
    $devModel    = if ($device) { Get-SafeValue $device 'model' }    else { 'N/A' }
    $devFirmware = if ($device) { Get-SafeValue $device 'version' }  else { 'N/A' }
    $devHostId   = if ($device) { Get-SafeValue $device 'hostId' }   else { 'N/A' }

    if ($devFirmware -eq 'N/A' -and $device -and $device.firmwareVersion) {
        $devFirmware = $device.firmwareVersion
    }

    # Network context — try both top-level and nested statistics
    $stats = $null
    if ($site -and $site.statistics) { $stats = $site.statistics }

    $wanUptime   = if ($site -and $null -ne $site.wanUptime)   { "$([math]::Round([double]$site.wanUptime, 2))" }
                   elseif ($stats -and $null -ne $stats.wanUptime) { "$([math]::Round([double]$stats.wanUptime, 2))" }
                   else { 'N/A' }

    $txRetry     = if ($device -and $null -ne $device.txRetryRate) { "$([math]::Round([double]$device.txRetryRate, 2))" }
                   elseif ($device -and $device.statistics -and $null -ne $device.statistics.txRetryRate) { "$([math]::Round([double]$device.statistics.txRetryRate, 2))" }
                   else { 'N/A' }

    $ispName     = if ($site)  { Get-SafeValue $site  'ispName' }    else { 'N/A' }
    $ispAsn      = if ($site)  { Get-SafeValue $site  'ispAsn' }     else { 'N/A' }
    $externalIp  = if ($site)  { Get-SafeValue $site  'wanIp' }      else { 'N/A' }

    if ($ispName -eq 'N/A' -and $stats)    { $ispName    = Get-SafeValue $stats 'ispName' }
    if ($ispAsn -eq 'N/A' -and $stats)     { $ispAsn     = Get-SafeValue $stats 'ispAsn' }
    if ($externalIp -eq 'N/A' -and $stats) { $externalIp = Get-SafeValue $stats 'wanIp' }

    $wiredClients = if ($site) { Get-SafeValue $site 'wiredClients' }  else { 'N/A' }
    $wifiClients  = if ($site) { Get-SafeValue $site 'wifiClients' }   else { 'N/A' }
    if ($wiredClients -eq 'N/A' -and $stats) { $wiredClients = Get-SafeValue $stats 'wiredClients' }
    if ($wifiClients -eq 'N/A' -and $stats)  { $wifiClients  = Get-SafeValue $stats 'wifiClients' }

    $mitigationSteps = Get-MitigationSteps -AlertType $Alert.AlertType

    $alertSummary = switch ($Alert.AlertType) {
        'DeviceOffline'                { "Device '$($Alert.DeviceName)' at site '$($Alert.SiteName)' is reporting as offline and may require immediate attention." }
        'FirmwareUpdateAvailable'      { "A firmware update is available for device '$($Alert.DeviceName)' at site '$($Alert.SiteName)' and should be scheduled." }
        'TxRetryWarning'               { "Elevated WAN packet retry rate detected at site '$($Alert.SiteName)', indicating potential network degradation." }
        'TxRetryCritical'              { "Critical WAN packet retry rate detected at site '$($Alert.SiteName)'. Immediate investigation is recommended." }
        'WanUptimeDegraded'            { "WAN uptime at site '$($Alert.SiteName)' has fallen below the acceptable threshold, indicating connectivity instability." }
        'CriticalNotificationsPresent' { "One or more critical notifications are present on the UniFi controller for site '$($Alert.SiteName)'." }
        'InternetIssuesDetected'       { "The UniFi controller has detected internet connectivity issues at site '$($Alert.SiteName)'." }
        'MultipleDevicesOffline'       { "Multiple network devices are offline simultaneously at site '$($Alert.SiteName)', indicating a potential site-wide outage." }
        'NoGatewayDevice'              { "No gateway device is detected on site '$($Alert.SiteName)'. All network connectivity may be affected." }
        default                        { "An alert condition has been detected at site '$($Alert.SiteName)' requiring review." }
    }

    $description = @"
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
Site Name     : $($Alert.SiteName)
Host ID       : $devHostId

NETWORK CONTEXT
===============
WAN Uptime    : $wanUptime%
TX Retry Rate : $txRetry%
ISP Name      : $ispName
ISP ASN       : $ispAsn
External IP   : $externalIp
Wired Clients : $wiredClients
Wifi Clients  : $wifiClients

DETECTED AT
===========
$ts

RECOMMENDED MITIGATION
======================
$mitigationSteps
FURTHER INFORMATION
===================
https://help.ui.com/hc/en-us/categories/200320654-UniFi-Network
"@

    return $description
}

#endregion TICKET-BUILDER

#region OUTPUT

function Get-PriorityInt {
    [CmdletBinding()]
    param([string]$Priority)

    switch ($Priority) {
        'Critical' { return 1 }
        'High'     { return 2 }
        'Medium'   { return 3 }
        default    { return 3 }
    }
}

function Write-TicketPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Alert,

        [Parameter(Mandatory)]
        [int]$Index,

        [Parameter(Mandatory)]
        [int]$Total,

        [string]$CompanyName = '',
        [object]$CompanyId   = $null,
        [object]$Contact     = $null,
        [string]$Description = '',
        [object]$SuppressedTicket = $null
    )

    $border = '=' * 65

    Write-Host "`n╔══ TICKET PREVIEW [$Index of $Total] $border" -ForegroundColor Cyan

    Write-Host "  TITLE    : $($Alert.Title)" -ForegroundColor White

    $companyDisplay = if ($CompanyName) { $CompanyName } else { 'Unknown' }
    $companyIdDisplay = if ($null -ne $CompanyId) { " (ID: $CompanyId)" } else { '' }
    Write-Host "  COMPANY  : $companyDisplay$companyIdDisplay" -ForegroundColor White

    $contactDisplay = if ($Contact) {
        $cName = "$($Contact.firstName) $($Contact.lastName)".Trim()
        $cEmail = if ($Contact.emailAddress) { " ($($Contact.emailAddress))" } else { '' }
        "$cName$cEmail"
    }
    else { 'No contact found' }
    Write-Host "  CONTACT  : $contactDisplay" -ForegroundColor White

    $priorityColor = switch ($Alert.Priority) {
        'Critical' { 'Red' }
        'High'     { 'Yellow' }
        'Medium'   { 'Green' }
        default    { 'White' }
    }
    Write-Host "  PRIORITY : $($Alert.Priority.ToUpper())" -ForegroundColor $priorityColor

    Write-Host "  QUEUE    : (ID: $($Config.TicketQueueId))" -ForegroundColor White

    if ($SuppressedTicket) {
        Write-Host "  [SUPPRESSED -- WOULD NOT CREATE] Existing ticket ID: $($SuppressedTicket.id)" -ForegroundColor Yellow
    }

    Write-Host "  -- DESCRIPTION PREVIEW $('-' * 46)" -ForegroundColor Cyan
    $Description -split "`n" | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Gray
    }
    Write-Host "╚$('=' * 65)╝" -ForegroundColor Cyan
}

function Write-RunSummary {
    [CmdletBinding()]
    param(
        [int]$SitesChecked,
        [int]$DevicesChecked,
        [int]$AlertsTriggered,
        [int]$TicketsRaised,
        [int]$TicketsSuppressed,
        [int]$ErrorsEncountered,
        [bool]$IsTestMode
    )

    $ticketLabel = if ($IsTestMode) { 'Tickets previewed  ' } else { 'Tickets raised     ' }

    Write-Host "`n========== RUN SUMMARY ==========" -ForegroundColor Cyan
    Write-Host "Sites checked       : $SitesChecked"    -ForegroundColor White
    Write-Host "Devices checked     : $DevicesChecked"  -ForegroundColor White
    Write-Host "Alerts triggered    : $AlertsTriggered" -ForegroundColor White
    Write-Host "$ticketLabel : $TicketsRaised"          -ForegroundColor White
    Write-Host "Tickets suppressed  : $TicketsSuppressed" -ForegroundColor White
    Write-Host "Errors encountered  : $ErrorsEncountered"  -ForegroundColor $(if ($ErrorsEncountered -gt 0) { 'Red' } else { 'White' })
    Write-Host "=================================" -ForegroundColor Cyan
}

#endregion OUTPUT

#region MAIN

function Resolve-CompanyAndContact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteName
    )

    # Step 1: lowercase site name, look up in SiteMapping
    $siteNameLower = $SiteName.ToLower()
    $mappedCompanyName = $null

    if ($Config.SiteMapping.ContainsKey($siteNameLower)) {
        $mappedCompanyName = $Config.SiteMapping[$siteNameLower]
    }
    else {
        Write-Host "[WARNING] No SiteMapping entry for site '$SiteName'. Using DefaultAccountName '$($Config.DefaultAccountName)'." -ForegroundColor Yellow
        $mappedCompanyName = $Config.DefaultAccountName
    }

    # Step 2: look up company in Autotask
    $companyId = Get-AutotaskCompanyId -CompanyName $mappedCompanyName

    # Step 3: if not found, fall back to DefaultAccountName
    if ($null -eq $companyId -and $mappedCompanyName -ne $Config.DefaultAccountName) {
        Write-Host "[WARNING] Company '$mappedCompanyName' not found in Autotask. Falling back to '$($Config.DefaultAccountName)'." -ForegroundColor Yellow
        $mappedCompanyName = $Config.DefaultAccountName
        $companyId = Get-AutotaskCompanyId -CompanyName $mappedCompanyName
    }

    if ($null -eq $companyId) {
        Write-Host "[WARNING] Default company '$($Config.DefaultAccountName)' also not found in Autotask. CompanyID will be null." -ForegroundColor Yellow
    }

    # Step 4: look up primary contact
    $contact = $null
    if ($null -ne $companyId) {
        $contact = Get-AutotaskPrimaryContact -CompanyId ([int]$companyId)
        if ($null -eq $contact) {
            Write-Host "[WARNING] No active contact found for company '$mappedCompanyName' (ID: $companyId). ContactID will be null." -ForegroundColor Yellow
        }
    }

    return [pscustomobject]@{
        CompanyName = $mappedCompanyName
        CompanyId   = $companyId
        Contact     = $contact
    }
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    # Counters
    $sitesChecked      = 0
    $devicesChecked    = 0
    $alertsTriggered   = 0
    $ticketsRaised     = 0
    $ticketsSuppressed = 0
    $errorsEncountered = 0

    if ($TestMode) {
        Write-Host "`n*** TEST MODE -- No tickets have been or will be raised during this run ***`n" -ForegroundColor Yellow
    }

    # Retrieve all sites
    Write-Host "[INFO] Retrieving UniFi sites..." -ForegroundColor Cyan
    $sites = $null
    try {
        $sites = Get-UniFiSites
    }
    catch {
        Write-Host "[ERROR] Failed to retrieve UniFi sites. Aborting." -ForegroundColor Red
        $errorsEncountered++
        Write-RunSummary -SitesChecked 0 -DevicesChecked 0 -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$TestMode
        return
    }

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Host "[WARNING] No sites returned from UniFi API." -ForegroundColor Yellow
        Write-RunSummary -SitesChecked 0 -DevicesChecked 0 -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$TestMode
        return
    }

    Write-Host "[INFO] Found $($sites.Count) site(s)." -ForegroundColor Cyan

    # Collect all alerts from all sites first (for preview count in TestMode)
    $allAlertData = [System.Collections.Generic.List[object]]::new()

    foreach ($site in $sites) {
        $sitesChecked++
        $siteDisplayName = if ($site.name) { $site.name } else { "Site[$sitesChecked]" }
        $hostId = if ($site.hostId) { $site.hostId } elseif ($site.id) { $site.id } else { $null }

        Write-Host "[INFO] Processing site: '$siteDisplayName'" -ForegroundColor Cyan

        # Retrieve devices for this site
        $devices = @()
        if ($hostId) {
            try {
                $devResult = Get-UniFiDevices -HostId $hostId
                $devices = if ($devResult) { @($devResult) } else { @() }
            }
            catch {
                Write-Host "[ERROR] Failed to retrieve devices for site '$siteDisplayName'. Skipping site." -ForegroundColor Red
                $errorsEncountered++
                continue
            }
        }
        else {
            Write-Host "[WARNING] Site '$siteDisplayName' has no hostId — device retrieval skipped." -ForegroundColor Yellow
        }

        $devicesChecked += $devices.Count
        Write-Host "[INFO] Site '$siteDisplayName': $($devices.Count) device(s) found." -ForegroundColor Cyan

        # Evaluate alerts
        $alerts = @()
        try {
            $alerts = Invoke-AlertEvaluation -Site $site -Devices $devices
        }
        catch {
            Write-Host "[ERROR] Alert evaluation failed for site '$siteDisplayName': $_" -ForegroundColor Red
            $errorsEncountered++
            continue
        }

        if ($alerts.Count -gt 0) {
            Write-Host "[INFO] Site '$siteDisplayName': $($alerts.Count) alert(s) triggered." -ForegroundColor Cyan
        }

        foreach ($alert in $alerts) {
            $allAlertData.Add([pscustomobject]@{
                Alert = $alert
                Site  = $site
            })
        }
    }

    $alertsTriggered = $allAlertData.Count
    $totalAlerts     = $alertsTriggered

    if ($alertsTriggered -eq 0) {
        Write-Host "[INFO] No alerts triggered. Network looks healthy." -ForegroundColor Green
        Write-RunSummary -SitesChecked $sitesChecked -DevicesChecked $devicesChecked -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$TestMode
        return
    }

    Write-Host "[INFO] Total alerts to process: $alertsTriggered" -ForegroundColor Cyan

    # Process each alert
    $previewIndex = 0
    foreach ($alertEntry in $allAlertData) {
        $alert = $alertEntry.Alert
        $previewIndex++

        # Resolve company and contact
        $resolution = $null
        try {
            $resolution = Resolve-CompanyAndContact -SiteName $alert.SiteName
        }
        catch {
            Write-Host "[ERROR] Failed to resolve company/contact for site '$($alert.SiteName)': $_" -ForegroundColor Red
            $errorsEncountered++
            continue
        }

        $companyName = $resolution.CompanyName
        $companyId   = $resolution.CompanyId
        $contact     = $resolution.Contact
        $contactId   = if ($contact -and $contact.id) { $contact.id } else { $null }

        # Build description
        $description = Build-TicketDescription -Alert $alert

        # Duplicate suppression
        $suppressedTicket = $null
        if ($null -ne $companyId) {
            try {
                $suppressedTicket = Get-ExistingOpenTicket `
                    -Title $alert.Title `
                    -CompanyId ([int]$companyId) `
                    -ClosedStatusIds $Config.ClosedStatusIds
            }
            catch {
                Write-Host "[ERROR] Duplicate check failed for '$($alert.Title)': $_" -ForegroundColor Red
                $errorsEncountered++
            }
        }

        if ($TestMode) {
            Write-TicketPreview `
                -Alert $alert `
                -Index $previewIndex `
                -Total $totalAlerts `
                -CompanyName $companyName `
                -CompanyId $companyId `
                -Contact $contact `
                -Description $description `
                -SuppressedTicket $suppressedTicket

            if ($suppressedTicket) {
                $ticketsSuppressed++
            }
            else {
                $ticketsRaised++
            }
            continue
        }

        # Live mode
        if ($suppressedTicket) {
            Write-Host "[SUPPRESSED] Open ticket already exists (ID: $($suppressedTicket.id)) -- $($alert.Title)" -ForegroundColor Yellow
            $ticketsSuppressed++
            continue
        }

        # Build ticket payload
        $ticketPayload = @{
            title       = $alert.Title
            companyID   = $companyId
            queueID     = $Config.TicketQueueId
            status      = $Config.TicketStatusNew
            source      = $Config.TicketSourceMonitor
            priority    = Get-PriorityInt -Priority $alert.Priority
            description = $description
        }
        if ($null -ne $contactId) {
            $ticketPayload['contactID'] = $contactId
        }

        Write-Host "[INFO] Creating ticket: $($alert.Title)" -ForegroundColor Cyan
        try {
            $result = New-AutotaskTicket -TicketData $ticketPayload
            if ($result -and ($result.id -or ($result.itemId))) {
                $newId = if ($result.id) { $result.id } elseif ($result.itemId) { $result.itemId } else { 'unknown' }
                Write-Host "[SUCCESS] Ticket created (ID: $newId): $($alert.Title)" -ForegroundColor Green
                $ticketsRaised++
            }
            elseif ($result) {
                Write-Host "[SUCCESS] Ticket created: $($alert.Title)" -ForegroundColor Green
                $ticketsRaised++
            }
            else {
                Write-Host "[ERROR] Ticket creation returned no result for: $($alert.Title)" -ForegroundColor Red
                $errorsEncountered++
            }
        }
        catch {
            Write-Host "[ERROR] Ticket creation threw an exception for '$($alert.Title)': $_" -ForegroundColor Red
            $errorsEncountered++
        }
    }

    Write-RunSummary `
        -SitesChecked      $sitesChecked `
        -DevicesChecked    $devicesChecked `
        -AlertsTriggered   $alertsTriggered `
        -TicketsRaised     $ticketsRaised `
        -TicketsSuppressed $ticketsSuppressed `
        -ErrorsEncountered $errorsEncountered `
        -IsTestMode:$TestMode
}

# Entry point
if ($CheckDeps) {
    $result = Test-Dependencies
    exit $(if ($result) { 0 } else { 1 })
}

Invoke-Main

#endregion MAIN
