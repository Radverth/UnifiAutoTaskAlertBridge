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

Set-StrictMode -Version 1
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
    TxRetryWarningPct       = 15.0
    TxRetryCriticalPct      = 20.0

    # WAN uptime threshold (percentage)
    WanUptimeWarningPct     = 99.9

    # Maximum tickets to raise (or preview in TestMode) per run. 0 = unlimited.
    # Useful during testing to avoid flooding Autotask. Alerts beyond this limit
    # are skipped with a console warning.
    MaxTicketsPerRun        = 0

    # Set to $true to run in Test Mode without passing -TestMode on the command line.
    # Useful when deploying via Datto RMM or any runner that cannot pass switch parameters.
    # The -TestMode switch takes precedence if both are set.
    TestMode                = $false

    # Firmware versions to suppress per device shortname.
    # If a device is intentionally pinned to a specific version, add it here to prevent
    # firmware update alerts. Keys are the shortname field from the UniFi device object
    # (e.g. 'US24P250'). Run -TestMode to see the shortname for each device.
    FirmwareExclusions      = @{
        'US24P250'  = @('7.2.123')   # USW Pro 24 PoE 250W
        'US8P150'   = @('7.2.123')   # USW 8 PoE 150W
        'USMINI'    = @('7.2.123')   # USW Flex Mini
    }

    # UniFi host name (lowercase) → Autotask company name
    # Keys are the hostName values returned by GET /v1/hosts/{id} — these are the
    # human-readable names shown in the UniFi console (e.g. 'client site name').
    # Run -TestMode to see the resolved host name for each site.
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
            # Preserve square brackets in parameter names (e.g. hostIds[]) — the API
            # requires them unencoded. Values still get fully encoded.
            $encodedKey = [System.Uri]::EscapeDataString($_.Key) -replace '%5B','[' -replace '%5D',']'
            "$encodedKey=$([System.Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri = "${uri}?${queryString}"
    }

    try {
        # Use Invoke-WebRequest -UseBasicParsing so .NET does not re-parse the URI
        # through [System.Uri], which would re-encode brackets and colons in the path/query.
        $raw      = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -UseBasicParsing
        $response = $raw.Content | ConvertFrom-Json
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
        # Build the query string manually — brackets in hostIds[] must not be percent-encoded
        $encodedHostId = [System.Uri]::EscapeDataString($HostId)
        $qs = "hostIds[]=$encodedHostId&pageSize=$pageSize"
        if ($nextToken) { $qs += "&nextToken=$([System.Uri]::EscapeDataString($nextToken))" }
        $uri = "$($Config.UnifiApiBase)/devices?$qs"

        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

            # Use the legacy Uri(string, dontEscape) constructor so .NET does not re-encode
            # the brackets in hostIds[]. WebClient.DownloadString(Uri) then sends the URI as-is.
            $uriObj = New-Object System.Uri($uri, $true)
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('Accept', 'application/json')
            $wc.Headers.Add('X-API-Key', $Config.UnifiApiKey)
            $raw = $wc.DownloadString($uriObj)
            $wc.Dispose()

            $response = $raw | ConvertFrom-Json

            # /v1/devices returns { data: [ { hostId, hostName, devices: [...] }, ... ] }
            # Each element in data is a host wrapper — we must unwrap .devices from each.
            # Filter by hostId client-side in case the API ignores the hostIds[] query param
            # (e.g. when the colon in the ID is percent-encoded and not recognised by the API).
            $hostWrappers = if ($response.data) { $response.data }
                            elseif ($response -is [array]) { $response }
                            else { @() }

            foreach ($wrapper in $hostWrappers) {
                if ($wrapper.hostId -and $wrapper.hostId -ne $HostId) { continue }
                $devs = if ($wrapper.devices) { $wrapper.devices }
                        elseif ($wrapper.mac)  { @($wrapper) }   # item is already a device
                        else                   { @() }
                foreach ($device in $devs) { $allDevices.Add($device) }
            }

            $nextToken = if ($response.nextToken) { $response.nextToken } else { $null }
        }
        catch {
            Write-Host "[ERROR] Failed to retrieve devices for host '$HostId': $_" -ForegroundColor Red
            return $allDevices
        }
    } while ($nextToken)

    return $allDevices
}

function Get-UniFiHost {
    <#
    .SYNOPSIS
        Retrieves a host record from GET /v1/hosts/{id} and returns the hostName.
        The hostName is the human-readable console name shown in the UniFi portal,
        which is more reliable than site.meta.name for identifying client sites.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostId
    )

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        # Build the URI as a string — colons are valid in path segments and must NOT be
        # percent-encoded, as the API does not accept %3A in this position.
        $uri = "$($Config.UnifiApiBase)/hosts/$HostId"

        $headers = @{
            'Accept'    = 'application/json'
            'X-API-Key' = $Config.UnifiApiKey
        }

        # Use Invoke-WebRequest with -UseBasicParsing so .NET does not re-parse
        # the URI and inadvertently re-encode the colon in the path segment.
        $raw      = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -UseBasicParsing
        $response = $raw.Content | ConvertFrom-Json

        $hostObj = if ($response.data) { $response.data } else { $response }
        if ($hostObj -and $hostObj.reportedState -and $hostObj.reportedState.name) {
            return $hostObj.reportedState.name
        }
        if ($hostObj -and $hostObj.hostName) { return $hostObj.hostName }
        if ($hostObj -and $hostObj.name)     { return $hostObj.name }
        return $null
    }
    catch {
        Write-Host "[WARNING] Could not retrieve host name for hostId '$HostId'. Falling back to site meta name." -ForegroundColor Yellow
        return $null
    }
}

function Get-UniFiHostNameMap {
    <#
    .SYNOPSIS
        Builds a hashtable of hostId → hostName for all sites by finding the
        console device (isConsole = true) per host and calling Get-UniFiHost.
        Results are cached so each hostId is only queried once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Sites
    )

    $map = @{}
    $uniqueHostIds = $Sites | Where-Object { $_.hostId } | ForEach-Object { $_.hostId } | Select-Object -Unique

    foreach ($hostId in $uniqueHostIds) {
        $hostName = Get-UniFiHost -HostId $hostId
        if ($hostName) {
            $map[$hostId] = $hostName
            Write-Host "[INFO] Host '$hostId' → '$hostName'" -ForegroundColor Cyan
        }
        else {
            $map[$hostId] = $null
        }
    }

    return $map
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
        [object[]]$Devices,

        # Pre-resolved human-readable site name (from /v1/hosts lookup).
        # Falls back to site.meta if not provided.
        [string]$SiteDisplayName = ''
    )

    $alerts = [System.Collections.Generic.List[object]]::new()

    # Use the pre-resolved display name if provided; otherwise fall back to meta fields
    $siteName = 'Unknown Site'
    if ($SiteDisplayName)                    { $siteName = $SiteDisplayName }
    elseif ($Site.meta -and $Site.meta.desc) { $siteName = $Site.meta.desc }
    elseif ($Site.meta -and $Site.meta.name) { $siteName = $Site.meta.name }

    # Shortcut to the statistics sub-objects
    $stats    = if ($Site.statistics)              { $Site.statistics }              else { $null }
    $counts   = if ($stats -and $stats.counts)     { $stats.counts }                 else { $null }
    $pct      = if ($stats -and $stats.percentages){ $stats.percentages }            else { $null }
    $ispInfo  = if ($stats -and $stats.ispInfo)    { $stats.ispInfo }                else { $null }

    # Counts used for site-level multi-device alerts (from statistics, not device list)
    $offlineCount  = if ($counts -and $null -ne $counts.offlineDevice)  { [int]$counts.offlineDevice }  else { ($Devices | Where-Object { $_.status -eq 'offline' }).Count }
    $gatewayCount  = if ($counts -and $null -ne $counts.gatewayDevice)  { [int]$counts.gatewayDevice }  else { ($Devices | Where-Object { $_.isConsole -eq $true }).Count }

    # Per-device alerts
    foreach ($device in $Devices) {
        $deviceName = if ($device.name)  { $device.name }
                      elseif ($device.model) { $device.model }
                      else { 'Unknown Device' }

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
            $excludedVersions = if ($device.shortname -and $Config.FirmwareExclusions -and $Config.FirmwareExclusions.ContainsKey($device.shortname)) {
                $Config.FirmwareExclusions[$device.shortname]
            } else { @() }
            $firmwareExcluded = $device.version -and ($excludedVersions -contains $device.version)

            if (-not $firmwareExcluded) {
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
            else {
                Write-Host "[INFO] Firmware alert suppressed for '$deviceName' ($($device.shortname) v$($device.version)) — version excluded in FirmwareExclusions" -ForegroundColor Cyan
            }
        }
    }

    # Alerts 3 & 4: TX Retry Rate — from site statistics.percentages.txRetry
    # For site-level alerts, attach the gateway/console device so tickets show real device info.
    $gatewayDevice = $Devices | Where-Object { $_.isConsole -eq $true } | Select-Object -First 1
    if (-not $gatewayDevice) { $gatewayDevice = $Devices | Select-Object -First 1 }

    $txRetryRate = if ($pct -and $null -ne $pct.txRetry) { [double]$pct.txRetry } else { $null }

    if ($null -ne $txRetryRate) {
        $rateRounded = [math]::Round($txRetryRate, 1)
        $gwName = if ($gatewayDevice -and $gatewayDevice.name) { $gatewayDevice.name } else { 'N/A' }

        if ($txRetryRate -gt $Config.TxRetryCriticalPct) {
            $alerts.Add([pscustomobject]@{
                AlertType  = 'TxRetryCritical'
                Priority   = 'Critical'
                Title      = "NETWORK CRITICAL -- ${siteName}: Critical WAN retry rate (${rateRounded}%)"
                SiteName   = $siteName
                DeviceName = $gwName
                DeviceData = $gatewayDevice
                SiteData   = $Site
            })
        }
        elseif ($txRetryRate -gt $Config.TxRetryWarningPct) {
            $alerts.Add([pscustomobject]@{
                AlertType  = 'TxRetryWarning'
                Priority   = 'Medium'
                Title      = "NETWORK DEGRADED -- ${siteName}: Elevated WAN retry rate (${rateRounded}%)"
                SiteName   = $siteName
                DeviceName = $gwName
                DeviceData = $gatewayDevice
                SiteData   = $Site
            })
        }
    }

    # Alert 5: WAN Uptime Degraded — from site statistics.percentages.wanUptime
    $wanUptime = if ($pct -and $null -ne $pct.wanUptime) { [double]$pct.wanUptime } else { $null }

    if ($null -ne $wanUptime -and $wanUptime -lt $Config.WanUptimeWarningPct) {
        $uptimeRounded = [math]::Round($wanUptime, 2)
        $alerts.Add([pscustomobject]@{
            AlertType  = 'WanUptimeDegraded'
            Priority   = 'High'
            Title      = "WAN ISSUE -- ${siteName}: WAN uptime below threshold (${uptimeRounded}%)"
            SiteName   = $siteName
            DeviceName = if ($gatewayDevice -and $gatewayDevice.name) { $gatewayDevice.name } else { 'N/A' }
            DeviceData = $gatewayDevice
            SiteData   = $Site
        })
    }

    # Alert 6: Critical Notifications — from site statistics.counts.criticalNotification
    $criticalNotifCount = if ($counts -and $null -ne $counts.criticalNotification) { [int]$counts.criticalNotification } else { $null }

    if ($null -ne $criticalNotifCount -and $criticalNotifCount -gt 0) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'CriticalNotificationsPresent'
            Priority   = 'High'
            Title      = "ALERT -- ${siteName}: ${criticalNotifCount} critical notification(s) on controller"
            SiteName   = $siteName
            DeviceName = if ($gatewayDevice -and $gatewayDevice.name) { $gatewayDevice.name } else { 'N/A' }
            DeviceData = $gatewayDevice
            SiteData   = $Site
        })
    }

    # Alert 7: Internet Issues — from site statistics.internetIssues (array)
    # Only raised when WAN uptime is also degraded, to suppress transient/minor events.
    $internetIssues = if ($stats -and $stats.internetIssues) { $stats.internetIssues } else { $null }
    $hasInternetIssues = ($internetIssues -is [array] -and $internetIssues.Count -gt 0) -or
                         ($internetIssues -is [bool] -and $internetIssues)
    $wanUptimeForIssues = if ($pct -and $null -ne $pct.wanUptime) { [double]$pct.wanUptime } else { $null }
    $wanUptimeDegraded  = ($null -ne $wanUptimeForIssues) -and ($wanUptimeForIssues -lt $Config.WanUptimeWarningPct)

    if ($hasInternetIssues -and $wanUptimeDegraded) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'InternetIssuesDetected'
            Priority   = 'High'
            Title      = "CONNECTIVITY ISSUE -- ${siteName}: Internet issues detected by controller"
            SiteName   = $siteName
            DeviceName = if ($gatewayDevice -and $gatewayDevice.name) { $gatewayDevice.name } else { 'N/A' }
            DeviceData = $gatewayDevice
            SiteData   = $Site
        })
    }

    # Alert 8: Multiple Devices Offline — from statistics.counts.offlineDevice
    if ($offlineCount -gt 1) {
        $alerts.Add([pscustomobject]@{
            AlertType  = 'MultipleDevicesOffline'
            Priority   = 'Critical'
            Title      = "NETWORK OUTAGE -- ${siteName}: ${offlineCount} devices offline simultaneously"
            SiteName   = $siteName
            DeviceName = if ($gatewayDevice -and $gatewayDevice.name) { $gatewayDevice.name } else { 'Multiple' }
            DeviceData = $gatewayDevice
            SiteData   = $Site
        })
    }

    # Alert 9: No Gateway Device — from statistics.counts.gatewayDevice
    $totalDeviceCount = if ($counts -and $null -ne $counts.totalDevice) { [int]$counts.totalDevice } else { $Devices.Count }
    if ($totalDeviceCount -gt 0 -and $gatewayCount -eq 0) {
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
    $devName     = if ($device) { Get-SafeValue $device 'name' }    else { 'N/A' }
    $devMac      = if ($device) { Get-SafeValue $device 'mac' }     else { 'N/A' }
    $devIp       = if ($device) { Get-SafeValue $device 'ip' }      else { 'N/A' }
    $devModel    = if ($device) { Get-SafeValue $device 'model' }   else { 'N/A' }
    $devFirmware = if ($device) { Get-SafeValue $device 'version' } else { 'N/A' }

    # Navigate the actual API response structure: site.statistics.{percentages,ispInfo,counts,wans,internetIssues}
    $stats      = if ($site -and $site.statistics)                   { $site.statistics }                   else { $null }
    $pct        = if ($stats -and $stats.percentages)                { $stats.percentages }                 else { $null }
    $ispInfo    = if ($stats -and $stats.ispInfo)                    { $stats.ispInfo }                     else { $null }
    $counts     = if ($stats -and $stats.counts)                     { $stats.counts }                      else { $null }
    $wansObj    = if ($stats -and $stats.wans -and $stats.wans.WAN)  { $stats.wans.WAN }                    else { $null }

    $wanUptime  = if ($pct -and $null -ne $pct.wanUptime)   { "$([math]::Round([double]$pct.wanUptime, 2))" }   else { 'N/A' }
    $txRetry    = if ($pct -and $null -ne $pct.txRetry)     { "$([math]::Round([double]$pct.txRetry, 2))" }     else { 'N/A' }
    $ispName    = if ($ispInfo -and $ispInfo.name)           { $ispInfo.name }                                   else { 'N/A' }
    $ispAsn     = if ($ispInfo -and $null -ne $ispInfo.asn)  { $ispInfo.asn.ToString() }                        else { 'N/A' }
    $externalIp = if ($wansObj -and $wansObj.externalIp)    { $wansObj.externalIp }                            else { 'N/A' }

    # Client counts from statistics.counts.wiredClient / wifiClient
    $wiredClients = if ($counts -and $null -ne $counts.wiredClient)   { $counts.wiredClient.ToString() } else { 'N/A' }
    $wifiClients  = if ($counts -and $null -ne $counts.wifiClient)    { $counts.wifiClient.ToString() }  else { 'N/A' }

    # Host ID for the device details block comes from the site (devices don't carry hostId)
    $siteHostId = if ($site -and $site.hostId) { $site.hostId } else { 'N/A' }

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

    # Build ticket body — omit any field whose value resolved to N/A
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('ALERT SUMMARY')
    $lines.Add('=============')
    $lines.Add($alertSummary)
    $lines.Add('')
    $lines.Add('DEVICE DETAILS')
    $lines.Add('==============')
    if ($devName     -ne 'N/A') { $lines.Add("Device Name   : $devName") }
    if ($devMac      -ne 'N/A') { $lines.Add("MAC Address   : $devMac") }
    if ($devIp       -ne 'N/A') { $lines.Add("IP Address    : $devIp") }
    if ($devModel    -ne 'N/A') { $lines.Add("Model         : $devModel") }
    if ($devFirmware -ne 'N/A' -and $devFirmware -ne '') { $lines.Add("Firmware      : $devFirmware") }
    $lines.Add("Site Name     : $($Alert.SiteName)")
    if ($siteHostId  -ne 'N/A') { $lines.Add("Host ID       : $siteHostId") }
    $lines.Add('')

    # Only include the Network Context section if at least one value is available
    $netLines = [System.Collections.Generic.List[string]]::new()
    if ($wanUptime     -ne 'N/A') { $netLines.Add("WAN Uptime    : $wanUptime%") }
    if ($txRetry       -ne 'N/A') { $netLines.Add("TX Retry Rate : $txRetry%") }
    if ($ispName       -ne 'N/A') { $netLines.Add("ISP Name      : $ispName") }
    if ($ispAsn        -ne 'N/A') { $netLines.Add("ISP ASN       : $ispAsn") }
    if ($externalIp    -ne 'N/A') { $netLines.Add("External IP   : $externalIp") }
    if ($wiredClients  -ne 'N/A') { $netLines.Add("Wired Clients : $wiredClients") }
    if ($wifiClients   -ne 'N/A') { $netLines.Add("Wifi Clients  : $wifiClients") }
    if ($netLines.Count -gt 0) {
        $lines.Add('NETWORK CONTEXT')
        $lines.Add('===============')
        foreach ($nl in $netLines) { $lines.Add($nl) }
        $lines.Add('')
    }

    $lines.Add('DETECTED AT')
    $lines.Add('===========')
    $lines.Add($ts)
    $lines.Add('')
    $lines.Add('RECOMMENDED MITIGATION')
    $lines.Add('======================')
    $lines.Add($mitigationSteps)

    $description = $lines -join "`n"
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

    # Resolve effective test mode — config variable or command-line switch
    $effectiveTestMode = $TestMode -or ($Config.TestMode -eq $true)

    # Counters
    $sitesChecked      = 0
    $devicesChecked    = 0
    $alertsTriggered   = 0
    $ticketsRaised     = 0
    $ticketsSuppressed = 0
    $errorsEncountered = 0

    if ($effectiveTestMode) {
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
        Write-RunSummary -SitesChecked 0 -DevicesChecked 0 -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$effectiveTestMode
        return
    }

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Host "[WARNING] No sites returned from UniFi API." -ForegroundColor Yellow
        Write-RunSummary -SitesChecked 0 -DevicesChecked 0 -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$effectiveTestMode
        return
    }

    Write-Host "[INFO] Found $($sites.Count) site(s)." -ForegroundColor Cyan

    # Build hostId → hostName lookup using GET /v1/hosts/{id}.
    # This gives the real human-readable console name rather than the internal meta slug.
    Write-Host "[INFO] Resolving host names from UniFi API..." -ForegroundColor Cyan
    $hostNameMap = Get-UniFiHostNameMap -Sites @($sites)

    # Collect all alerts from all sites first (for preview count in TestMode)
    $allAlertData = [System.Collections.Generic.List[object]]::new()

    foreach ($site in $sites) {
        $sitesChecked++
        $hostId = if ($site.hostId) { $site.hostId } else { $null }

        # Prefer hostName from /v1/hosts lookup; fall back to meta.desc / meta.name
        $siteDisplayName = $null
        if ($hostId -and $hostNameMap.ContainsKey($hostId) -and $hostNameMap[$hostId]) {
            $siteDisplayName = $hostNameMap[$hostId]
        }
        if (-not $siteDisplayName -and $site.meta -and $site.meta.desc)  { $siteDisplayName = $site.meta.desc }
        if (-not $siteDisplayName -and $site.meta -and $site.meta.name)  { $siteDisplayName = $site.meta.name }
        if (-not $siteDisplayName) { $siteDisplayName = "Site[$sitesChecked]" }

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
            $alerts = Invoke-AlertEvaluation -Site $site -Devices $devices -SiteDisplayName $siteDisplayName
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
        Write-RunSummary -SitesChecked $sitesChecked -DevicesChecked $devicesChecked -AlertsTriggered 0 -TicketsRaised 0 -TicketsSuppressed 0 -ErrorsEncountered $errorsEncountered -IsTestMode:$effectiveTestMode
        return
    }

    Write-Host "[INFO] Total alerts to process: $alertsTriggered" -ForegroundColor Cyan

    # Process each alert
    $previewIndex = 0
    foreach ($alertEntry in $allAlertData) {
        $alert = $alertEntry.Alert
        $previewIndex++

        # Enforce MaxTicketsPerRun limit (0 = unlimited)
        $ticketCount = $ticketsRaised + $ticketsSuppressed
        if ($Config.MaxTicketsPerRun -gt 0 -and $ticketCount -ge $Config.MaxTicketsPerRun) {
            $remaining = $allAlertData.Count - $previewIndex + 1
            Write-Host "[WARNING] MaxTicketsPerRun ($($Config.MaxTicketsPerRun)) reached. Skipping $remaining remaining alert(s)." -ForegroundColor Yellow
            break
        }

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

        if ($effectiveTestMode) {
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
        -IsTestMode:$effectiveTestMode
}

# Entry point
if ($CheckDeps) {
    $result = Test-Dependencies
    exit $(if ($result) { 0 } else { 1 })
}

Invoke-Main

#endregion MAIN
