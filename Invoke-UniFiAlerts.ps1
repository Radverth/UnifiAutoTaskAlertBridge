<#
.SYNOPSIS
    UniFi → AutoTask Alert Bridge — Datto RMM Component Job

.DESCRIPTION
    Polls a UniFi Cloud Controller for active (unarchived) alerts, identifies
    the corresponding AutoTask company by parsing the account number prefix from
    the UniFi site name, and creates a service ticket in AutoTask. A JSON
    deduplication log prevents duplicate tickets across polling runs.

.PARAMETER TestMode
    Fetch one real alert, dump full JSON to stdout, then exit without creating
    any AutoTask ticket or writing to the dedup log.

.PARAMETER TestSite
    When used with -TestMode, restricts the alert fetch to a single named site.

.EXAMPLE
    # Normal operation (called by Datto RMM scheduler)
    .\Invoke-UniFiAlerts.ps1

.EXAMPLE
    # Test connectivity — no ticket created
    .\Invoke-UniFiAlerts.ps1 -TestMode

.EXAMPLE
    # Test a specific site
    .\Invoke-UniFiAlerts.ps1 -TestMode -TestSite "AFF001_A1 Taxis"
#>

[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestSite = ''
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ---------------------------------------------------------------------------
#region CONFIG
# ---------------------------------------------------------------------------

$Script:RequiredEnvVars = @(
    'UNIFI_BASE_URL',
    'UNIFI_USERNAME',
    'UNIFI_PASSWORD',
    'AT_BASE_URL',
    'AT_USERNAME',
    'AT_SECRET',
    'AT_QUEUE_ID',
    'AT_SOURCE_ID',
    'AT_PRIORITY_ID',
    'DEDUP_LOG_PATH'
)

$Script:UniFiBaseUrl    = $env:UNIFI_BASE_URL
$Script:UniFiUsername   = $env:UNIFI_USERNAME
$Script:UniFiPassword   = $env:UNIFI_PASSWORD
$Script:UniFiSiteFilter = if ($env:UNIFI_SITE_FILTER) {
    $env:UNIFI_SITE_FILTER -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
} else { @() }
$Script:AtBaseUrl       = $env:AT_BASE_URL
$Script:AtUsername      = $env:AT_USERNAME
$Script:AtSecret        = $env:AT_SECRET
$Script:AtQueueId       = $env:AT_QUEUE_ID
$Script:AtSourceId      = $env:AT_SOURCE_ID
$Script:AtPriorityId    = $env:AT_PRIORITY_ID
$Script:DedupLogPath    = $env:DEDUP_LOG_PATH

$Script:DedupRetentionDays = 7

#endregion CONFIG

# ---------------------------------------------------------------------------
#region LOGGING
# ---------------------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to stdout.
    .PARAMETER Level
        Info, Warning, or Error.
    .PARAMETER Message
        The message to log.
    #>
    param(
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [string]$Message
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] [$Level] $Message"
}

#endregion LOGGING

# ---------------------------------------------------------------------------
#region UNIFI-AUTH
# ---------------------------------------------------------------------------

function Enable-SelfSignedCerts {
    <#
    .SYNOPSIS
        Enables self-signed certificate acceptance for PowerShell 5.1.
        PowerShell 7+ uses the -SkipCertificateCheck parameter instead.
    #>
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
            Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint svcPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
'@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
        Write-Log -Level Info -Message 'Self-signed cert bypass enabled (PS 5.1 mode)'
    }
}

function Invoke-UniFiRequest {
    <#
    .SYNOPSIS
        Wrapper around Invoke-RestMethod that injects the UniFi WebSession and
        handles -SkipCertificateCheck for PS 7+.
    #>
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Body,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }

    if ($WebSession) { $params['WebSession'] = $WebSession }
    if ($Body)       { $params['Body']       = ($Body | ConvertTo-Json -Depth 10) }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params['SkipCertificateCheck'] = $true }

    Invoke-RestMethod @params
}

function Get-UniFiSession {
    <#
    .SYNOPSIS
        Authenticates against the UniFi Cloud Controller and returns a session
        hashtable containing the BaseUrl and the authenticated WebSession.
    .OUTPUTS
        Hashtable: { BaseUrl, WebSession }
    #>
    param(
        [string]$BaseUrl   = $Script:UniFiBaseUrl,
        [string]$Username  = $Script:UniFiUsername,
        [string]$Password  = $Script:UniFiPassword
    )

    Enable-SelfSignedCerts

    $loginUri  = "$BaseUrl/api/login"
    $loginBody = @{ username = $Username; password = $Password }

    Write-Log -Level Info -Message "Authenticating to UniFi controller: $BaseUrl"

    $loginParams = @{
        Uri             = $loginUri
        Method          = 'POST'
        Body            = ($loginBody | ConvertTo-Json)
        ContentType     = 'application/json'
        SessionVariable = 'webSession'
        ErrorAction     = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $loginParams['SkipCertificateCheck'] = $true }

    $response = Invoke-RestMethod @loginParams

    if ($response.meta.rc -ne 'ok') {
        throw "UniFi login failed. Controller response: $($response.meta.msg)"
    }

    Write-Log -Level Info -Message 'UniFi authentication successful'

    return @{
        BaseUrl    = $BaseUrl
        WebSession = $webSession
    }
}

#endregion UNIFI-AUTH

# ---------------------------------------------------------------------------
#region UNIFI-ALERTS
# ---------------------------------------------------------------------------

function Get-UniFiSites {
    <#
    .SYNOPSIS
        Returns all sites accessible by the authenticated session.
        Applies UNIFI_SITE_FILTER if set.
    .OUTPUTS
        Array of site objects: { id, name, desc }
    #>
    param(
        [hashtable]$Session
    )

    $uri      = "$($Session.BaseUrl)/api/self/sites"
    $response = Invoke-UniFiRequest -Uri $uri -WebSession $Session.WebSession

    if ($response.meta.rc -ne 'ok') {
        throw "Failed to retrieve UniFi sites: $($response.meta.msg)"
    }

    $sites = $response.data

    if ($Script:UniFiSiteFilter.Count -gt 0) {
        $sites = $sites | Where-Object { $Script:UniFiSiteFilter -contains $_.desc }
        Write-Log -Level Info -Message "Site filter applied — $($sites.Count) site(s) matched"
    }

    Write-Log -Level Info -Message "Found $($sites.Count) site(s) to process"
    return $sites
}

function Get-UniFiAlerts {
    <#
    .SYNOPSIS
        Fetches unarchived alerts for every site returned by Get-UniFiSites.
        Each alert object is annotated with site_name (the site desc field).
    .OUTPUTS
        Array of alert objects.
    #>
    param(
        [hashtable]$Session,
        [array]$Sites
    )

    $allAlerts = @()

    foreach ($site in $Sites) {
        $siteId   = $site.name   # The short ID used in API paths (not the display name)
        $siteName = $site.desc   # The human-readable description e.g. AFF001_A1 Taxis

        $uri = "$($Session.BaseUrl)/api/s/$siteId/stat/alarm"

        try {
            $response = Invoke-UniFiRequest -Uri $uri -WebSession $Session.WebSession

            if ($response.meta.rc -ne 'ok') {
                Write-Log -Level Warning -Message "Could not fetch alerts for site '$siteName': $($response.meta.msg)"
                continue
            }

            $siteAlerts = $response.data | Where-Object { $_.archived -eq $false }

            foreach ($alert in $siteAlerts) {
                # Annotate with site display name for downstream processing
                $alert | Add-Member -MemberType NoteProperty -Name 'site_name' -Value $siteName -Force
            }

            Write-Log -Level Info -Message "Site '$siteName': $($siteAlerts.Count) unarchived alert(s)"
            $allAlerts += $siteAlerts
        }
        catch {
            Write-Log -Level Warning -Message "Error fetching alerts for site '$siteName': $_"
        }
    }

    return $allAlerts
}

#endregion UNIFI-ALERTS

# ---------------------------------------------------------------------------
#region ACCOUNT-PARSE
# ---------------------------------------------------------------------------

function Get-AccountPrefix {
    <#
    .SYNOPSIS
        Extracts the account number prefix from a UniFi site name.
        Returns everything to the left of the first underscore.
        Returns $null if no underscore is present.
    .EXAMPLE
        Get-AccountPrefix 'AFF001_A1 Taxis'  # returns 'AFF001'
        Get-AccountPrefix 'NoUnderscore'      # returns $null (warning logged)
        Get-AccountPrefix '_Leading'          # returns '' (empty — warning logged)
    #>
    param(
        [string]$SiteName
    )

    if ($SiteName -notmatch '_') {
        Write-Log -Level Warning -Message "Site name '$SiteName' has no underscore — cannot extract account prefix. Skipping."
        return $null
    }

    $prefix = $SiteName.Split('_')[0].Trim()

    if ($prefix -eq '') {
        Write-Log -Level Warning -Message "Site name '$SiteName' has a leading underscore — prefix is empty. Skipping."
        return $null
    }

    return $prefix
}

#endregion ACCOUNT-PARSE

# ---------------------------------------------------------------------------
#region AUTOTASK-LOOKUP
# ---------------------------------------------------------------------------

function Get-AutoTaskAuthHeaders {
    <#
    .SYNOPSIS
        Builds the Authorization header for AutoTask REST API calls.
    #>
    $pair    = "$($Script:AtUsername):$($Script:AtSecret)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{
        Authorization = "Basic $encoded"
        'Content-Type' = 'application/json'
    }
}

function Invoke-AutoTaskRequest {
    <#
    .SYNOPSIS
        Wrapper around Invoke-RestMethod for AutoTask REST API calls.
        Implements exponential backoff on 429 (rate limit) responses.
    #>
    param(
        [string]$Uri,
        [string]$Method  = 'GET',
        [object]$Body,
        [hashtable]$Headers
    )

    if (-not $Headers) { $Headers = Get-AutoTaskAuthHeaders }

    $maxAttempts = 3
    $attempt     = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                ContentType = 'application/json'
                ErrorAction = 'Stop'
            }
            if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }

            return Invoke-RestMethod @params
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 429 -and $attempt -lt $maxAttempts) {
                $backoff = [math]::Pow(2, $attempt)
                Write-Log -Level Warning -Message "AutoTask rate limit hit (429). Retrying in ${backoff}s (attempt $attempt of $maxAttempts)..."
                Start-Sleep -Seconds $backoff
            }
            else {
                throw
            }
        }
    }
}

function Find-AutoTaskCompany {
    <#
    .SYNOPSIS
        Searches AutoTask for a company by account number prefix.
        Returns a hashtable with CompanyID and CompanyName, or $null if not found.
    .OUTPUTS
        Hashtable: { CompanyID, CompanyName } or $null
    #>
    param(
        [string]$AccountPrefix
    )

    $uri  = "$($Script:AtBaseUrl)/v1.0/Companies/query"
    $body = @{
        filter = @(
            @{ op = 'eq'; field = 'AccountNumber'; value = $AccountPrefix }
        )
    }

    try {
        $response = Invoke-AutoTaskRequest -Uri $uri -Method 'POST' -Body $body

        if ($response.items -and $response.items.Count -gt 0) {
            $company = $response.items[0]
            Write-Log -Level Info -Message "Matched account prefix '$AccountPrefix' to company '$($company.companyName)' (ID: $($company.id))"
            return @{
                CompanyID   = $company.id
                CompanyName = $company.companyName
            }
        }
        else {
            Write-Log -Level Warning -Message "No AutoTask company found for account prefix '$AccountPrefix'. Skipping alert."
            return $null
        }
    }
    catch {
        Write-Log -Level Error -Message "AutoTask company lookup failed for prefix '$AccountPrefix': $_"
        return $null
    }
}

function Get-PrimaryContact {
    <#
    .SYNOPSIS
        Retrieves the primary contact for an AutoTask company.
        Returns a hashtable with ContactID, Name, Phone, Email, or $null if none set.
    .OUTPUTS
        Hashtable: { ContactID, Name, Phone, Email } or $null
    #>
    param(
        [long]$CompanyID
    )

    $uri  = "$($Script:AtBaseUrl)/v1.0/Contacts/query"
    $body = @{
        filter = @(
            @{ op = 'eq'; field = 'CompanyID'; value = $CompanyID },
            @{ op = 'eq'; field = 'Active';    value = $true }
        )
    }

    try {
        $response = Invoke-AutoTaskRequest -Uri $uri -Method 'POST' -Body $body

        if ($response.items -and $response.items.Count -gt 0) {
            # Prefer flagged primary contact; fall back to first active contact
            $contact = $response.items | Where-Object { $_.isPrimary -eq $true } | Select-Object -First 1
            if (-not $contact) { $contact = $response.items[0] }

            $name  = "$($contact.firstName) $($contact.lastName)".Trim()
            $phone = if ($contact.phone)       { $contact.phone }
                     elseif ($contact.mobilePhone) { $contact.mobilePhone }
                     else { '' }
            $email = if ($contact.emailAddress) { $contact.emailAddress } else { '' }

            Write-Log -Level Info -Message "Primary contact for company $CompanyID: $name"
            return @{
                ContactID = $contact.id
                Name      = $name
                Phone     = $phone
                Email     = $email
            }
        }
        else {
            Write-Log -Level Info -Message "No primary contact found for company $CompanyID"
            return $null
        }
    }
    catch {
        Write-Log -Level Warning -Message "Primary contact lookup failed for company $CompanyID: $_"
        return $null
    }
}

#endregion AUTOTASK-LOOKUP

# ---------------------------------------------------------------------------
#region ALERT-MAP
# ---------------------------------------------------------------------------

$Script:AlertMap = @{
    'EVT_AP_Disconnected'      = 'Access point disconnected from the UniFi controller'
    'EVT_AP_Connected'         = 'Access point reconnected to the UniFi controller'
    'EVT_AP_Restarted'         = 'Access point restarted'
    'EVT_AP_UpgradeScheduled'  = 'Access point firmware upgrade scheduled'
    'EVT_SW_Disconnected'      = 'Network switch disconnected from the UniFi controller'
    'EVT_SW_Connected'         = 'Network switch reconnected to the UniFi controller'
    'EVT_SW_Restarted'         = 'Network switch restarted'
    'EVT_GW_Disconnected'      = 'Gateway / router disconnected from the UniFi controller'
    'EVT_GW_Connected'         = 'Gateway / router reconnected to the UniFi controller'
    'EVT_GW_WANTransitioned'   = 'WAN connection changed state (failover or recovery)'
    'EVT_GW_VPNDown'           = 'VPN tunnel went down'
    'EVT_GW_VPNUp'             = 'VPN tunnel came back up'
    'EVT_LTE_Disconnected'     = 'LTE failover link disconnected'
    'EVT_LTE_Connected'        = 'LTE failover link reconnected'
    'EVT_CLIENT_Roam'          = 'Wireless client roamed between access points'
    'EVT_CLIENT_Blocked'       = 'Wireless client was blocked'
}

function Get-AlertTitle {
    <#
    .SYNOPSIS
        Returns the short plain-English alert type suitable for use in a ticket title.
    #>
    param([string]$EventKey)

    $titleMap = @{
        'EVT_AP_Disconnected'      = 'AP Disconnected'
        'EVT_AP_Connected'         = 'AP Reconnected'
        'EVT_AP_Restarted'         = 'AP Restarted'
        'EVT_AP_UpgradeScheduled'  = 'AP Firmware Upgrade Scheduled'
        'EVT_SW_Disconnected'      = 'Switch Disconnected'
        'EVT_SW_Connected'         = 'Switch Reconnected'
        'EVT_SW_Restarted'         = 'Switch Restarted'
        'EVT_GW_Disconnected'      = 'Gateway Disconnected'
        'EVT_GW_Connected'         = 'Gateway Reconnected'
        'EVT_GW_WANTransitioned'   = 'WAN Failover'
        'EVT_GW_VPNDown'           = 'VPN Tunnel Down'
        'EVT_GW_VPNUp'             = 'VPN Tunnel Up'
        'EVT_LTE_Disconnected'     = 'LTE Link Disconnected'
        'EVT_LTE_Connected'        = 'LTE Link Reconnected'
        'EVT_CLIENT_Roam'          = 'Client Roam'
        'EVT_CLIENT_Blocked'       = 'Client Blocked'
    }

    if ($titleMap.ContainsKey($EventKey)) { return $titleMap[$EventKey] }
    return "Unknown Event ($EventKey)"
}

function Get-AlertDescription {
    <#
    .SYNOPSIS
        Returns the full plain-English description for a UniFi event key.
        Falls back to "Unknown event: {raw code}" for unrecognised keys.
    #>
    param([string]$EventKey)

    if ($Script:AlertMap.ContainsKey($EventKey)) {
        return $Script:AlertMap[$EventKey]
    }
    return "Unknown event: $EventKey"
}

#endregion ALERT-MAP

# ---------------------------------------------------------------------------
#region AUTOTASK-TICKET
# ---------------------------------------------------------------------------

function Build-TicketDescription {
    <#
    .SYNOPSIS
        Constructs the structured multi-section ticket description string.
    #>
    param(
        [psobject]$Alert,
        [hashtable]$Company,
        [hashtable]$Contact,
        [string]$AccountPrefix
    )

    $eventKey    = if ($Alert.key)     { $Alert.key }     else { 'Unknown' }
    $deviceName  = if ($Alert.ap_name) { $Alert.ap_name }
                   elseif ($Alert.sw_name) { $Alert.sw_name }
                   elseif ($Alert.gw_name) { $Alert.gw_name }
                   elseif ($Alert.ap)      { $Alert.ap }
                   else { 'Unknown Device' }
    $macAddress  = if ($Alert.ap)  { $Alert.ap }
                   elseif ($Alert.sw) { $Alert.sw }
                   elseif ($Alert.gw) { $Alert.gw }
                   else { 'N/A' }
    $subsystem   = if ($Alert.subsystem) { $Alert.subsystem } else { 'N/A' }
    $alertType   = Get-AlertTitle       -EventKey $eventKey
    $description = Get-AlertDescription -EventKey $eventKey

    # Parse datetime
    $utcTime   = 'N/A'
    $localTime = 'N/A'
    if ($Alert.datetime) {
        try {
            $dt      = [datetime]::Parse($Alert.datetime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $utcTime = $dt.ToUniversalTime().ToString('dd MMM yyyy HH:mm:ss') + ' UTC'
            $localTime = $dt.ToLocalTime().ToString('dd MMM yyyy HH:mm:ss') + ' ' + [System.TimeZoneInfo]::Local.StandardName
        }
        catch { }
    }

    # Next steps vary by device type
    $deviceSteps = switch -Wildcard ($eventKey) {
        'EVT_AP_*' {
            @(
                'Check physical connectivity and power to the access point',
                'Check the upstream switch port',
                'Log into the UniFi Cloud Controller to review device history',
                'If the AP has reconnected, monitor for recurrence'
            )
        }
        'EVT_SW_*' {
            @(
                'Check physical connectivity and power to the switch',
                'Check upstream link / uplink port status',
                'Log into the UniFi Cloud Controller to review device history',
                'If the switch has reconnected, monitor for recurrence'
            )
        }
        'EVT_GW_*' {
            @(
                'Check WAN connectivity and ISP status for the site',
                'Check physical connectivity and power to the gateway',
                'Log into the UniFi Cloud Controller to review device history and WAN status',
                'If the gateway has reconnected, confirm VPN tunnels are up'
            )
        }
        'EVT_LTE_*' {
            @(
                'Verify LTE signal and SIM status on the device',
                'Check whether the primary WAN is functioning (LTE failover may be expected)',
                'Log into the UniFi Cloud Controller to review LTE device history'
            )
        }
        default {
            @(
                'Review the alert details below',
                'Log into the UniFi Cloud Controller for more context'
            )
        }
    }

    $remoteRebootStep = @"
If the device remains offline, it may require a reboot. This can be done remotely via the UniFi Cloud Controller — locate the device, select Restart, and confirm. If the device is not visible in the controller it is unreachable and a manual power cycle will be needed. In either case, contact the primary contact to schedule a convenient time before proceeding.
"@

    $allSteps   = $deviceSteps + $remoteRebootStep.Trim()
    $stepsText  = ($allSteps | ForEach-Object { $i = [array]::IndexOf($allSteps, $_) + 1; "$i. $_" }) -join "`n"

    # Primary contact block
    if ($Contact) {
        $contactBlock = @"
Name:    $($Contact.Name)
Phone:   $(if ($Contact.Phone) { $Contact.Phone } else { 'Not on file' })
Email:   $(if ($Contact.Email) { $Contact.Email } else { 'Not on file' })
"@
    }
    else {
        $contactBlock = @"
No primary contact assigned in AutoTask.
Please assign manually before contacting the client.
"@
    }

    # Raw JSON of the full alert object
    $rawJson = $Alert | ConvertTo-Json -Depth 10

    $description = @"
ALERT SUMMARY
─────────────────────────────────────────────
Client:        $($Company.CompanyName) ($AccountPrefix)
Site:          $($Alert.site_name)
Device:        $deviceName
MAC Address:   $macAddress
Alert Type:    $alertType
Subsystem:     $subsystem
Time (UTC):    $utcTime
Time (Local):  $localTime

WHAT HAPPENED
─────────────────────────────────────────────
$(Get-AlertDescription -EventKey $eventKey)

NEXT STEPS
─────────────────────────────────────────────
$stepsText

PRIMARY CONTACT
─────────────────────────────────────────────
$contactBlock

RAW ALERT DATA (for reference)
─────────────────────────────────────────────
Alert ID:   $($Alert._id)
Raw Event:  $eventKey
Raw JSON:
$rawJson
"@

    return $description
}

function New-AutoTaskTicket {
    <#
    .SYNOPSIS
        Creates a new AutoTask ticket for a UniFi alert.
        Returns the created ticket ID, or $null on failure.
    .OUTPUTS
        [long] Ticket ID or $null
    #>
    param(
        [psobject]$Alert,
        [hashtable]$Company,
        [hashtable]$Contact,
        [string]$AccountPrefix
    )

    $eventKey   = if ($Alert.key) { $Alert.key } else { 'Unknown' }
    $deviceName = if ($Alert.ap_name) { $Alert.ap_name }
                  elseif ($Alert.sw_name) { $Alert.sw_name }
                  elseif ($Alert.gw_name) { $Alert.gw_name }
                  elseif ($Alert.ap)      { $Alert.ap }
                  else { 'Unknown Device' }

    $alertTitle  = Get-AlertTitle -EventKey $eventKey
    $ticketTitle = "[UniFi] $alertTitle `u{2013} $deviceName ($AccountPrefix / $($Company.CompanyName))"

    # Truncate title to AutoTask's 255-char limit
    if ($ticketTitle.Length -gt 255) { $ticketTitle = $ticketTitle.Substring(0, 252) + '...' }

    $ticketDescription = Build-TicketDescription -Alert $Alert -Company $Company -Contact $Contact -AccountPrefix $AccountPrefix

    $ticketBody = @{
        CompanyID      = $Company.CompanyID
        Title          = $ticketTitle
        Description    = $ticketDescription
        QueueID        = [long]$Script:AtQueueId
        TicketSourceID = [long]$Script:AtSourceId
        PriorityID     = [long]$Script:AtPriorityId
        Status         = 1
    }

    if ($Contact -and $Contact.ContactID) {
        $ticketBody['ContactID'] = $Contact.ContactID
    }

    $uri = "$($Script:AtBaseUrl)/v1.0/Tickets"

    try {
        $response = Invoke-AutoTaskRequest -Uri $uri -Method 'POST' -Body $ticketBody
        $ticketId = $response.itemId
        Write-Log -Level Info -Message "AutoTask ticket created: ID=$ticketId | '$ticketTitle'"
        return $ticketId
    }
    catch {
        Write-Log -Level Error -Message "Failed to create AutoTask ticket for alert $($Alert._id): $_"

        # Log response body if available for diagnosis
        if ($_.Exception.Response) {
            try {
                $reader  = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errBody = $reader.ReadToEnd()
                Write-Log -Level Error -Message "AutoTask response body: $errBody"
            }
            catch { }
        }

        return $null
    }
}

#endregion AUTOTASK-TICKET

# ---------------------------------------------------------------------------
#region DEDUP
# ---------------------------------------------------------------------------

function Read-DedupLog {
    <#
    .SYNOPSIS
        Reads the deduplication log from disk.
        Returns an empty hashtable if the file is missing or corrupt.
    .OUTPUTS
        Hashtable keyed by alert ID.
    #>
    if (-not (Test-Path $Script:DedupLogPath)) {
        Write-Log -Level Info -Message "Dedup log not found at '$($Script:DedupLogPath)' — creating empty log"
        return @{}
    }

    try {
        $content = Get-Content -Path $Script:DedupLogPath -Raw -ErrorAction Stop
        $log     = $content | ConvertFrom-Json -ErrorAction Stop

        # Convert PSCustomObject back to hashtable
        $ht = @{}
        $log.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    }
    catch {
        Write-Log -Level Warning -Message "Dedup log at '$($Script:DedupLogPath)' is corrupt or unreadable — recreating. Error: $_"
        return @{}
    }
}

function Write-DedupLog {
    <#
    .SYNOPSIS
        Appends a new entry to the deduplication log and saves it to disk.
    #>
    param(
        [hashtable]$Log,
        [string]$AlertId,
        [long]$TicketId
    )

    $Log[$AlertId] = @{
        ticketId  = $TicketId
        timestamp = (Get-Date -Format 'o')
    }

    $logDir = Split-Path -Path $Script:DedupLogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $Log | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:DedupLogPath -Encoding UTF8 -Force
}

function Remove-ExpiredDedupEntries {
    <#
    .SYNOPSIS
        Removes dedup log entries older than DedupRetentionDays (default 7).
        Returns the cleaned hashtable.
    #>
    param(
        [hashtable]$Log
    )

    $cutoff  = (Get-Date).AddDays(-$Script:DedupRetentionDays)
    $removed = 0

    $keysToRemove = @($Log.Keys | Where-Object {
        try {
            [datetime]$Log[$_].timestamp -lt $cutoff
        }
        catch { $false }
    })

    foreach ($key in $keysToRemove) {
        $Log.Remove($key)
        $removed++
    }

    if ($removed -gt 0) {
        Write-Log -Level Info -Message "Pruned $removed expired dedup log entries (older than $($Script:DedupRetentionDays) days)"
    }

    return $Log
}

function Test-AlreadyLogged {
    <#
    .SYNOPSIS
        Returns $true if the alert ID exists in the dedup log and is not expired.
    #>
    param(
        [hashtable]$Log,
        [string]$AlertId
    )

    if (-not $Log.ContainsKey($AlertId)) { return $false }

    $entry = $Log[$AlertId]
    try {
        $entryTime = [datetime]$entry.timestamp
        $cutoff    = (Get-Date).AddDays(-$Script:DedupRetentionDays)
        return $entryTime -ge $cutoff
    }
    catch {
        return $false
    }
}

#endregion DEDUP

# ---------------------------------------------------------------------------
#region MAIN
# ---------------------------------------------------------------------------

function Assert-EnvVars {
    <#
    .SYNOPSIS
        Validates all required environment variables are set.
        Exits with code 1 if any are missing.
    #>
    $missing = $Script:RequiredEnvVars | Where-Object { -not (Get-Item -Path "Env:$_" -ErrorAction SilentlyContinue) }

    if ($missing.Count -gt 0) {
        foreach ($var in $missing) {
            Write-Log -Level Error -Message "Required environment variable '$var' is not set"
        }
        Write-Log -Level Error -Message "Aborting: $($missing.Count) required variable(s) missing. Set them as Datto RMM Site Variables."
        exit 1
    }

    Write-Log -Level Info -Message 'All required environment variables are present'
}

# ── Entry point ──────────────────────────────────────────────────────────────

try {
    Assert-EnvVars

    Write-Log -Level Info -Message "=== UniFi AutoTask Alert Bridge starting$(if ($TestMode) { ' [TEST MODE]' }) ==="

    # Authenticate to UniFi
    $session = Get-UniFiSession
    $sites   = Get-UniFiSites -Session $session

    # Optionally restrict to one site when -TestSite is supplied
    if ($TestSite -ne '') {
        $sites = $sites | Where-Object { $_.desc -eq $TestSite }
        if ($sites.Count -eq 0) {
            Write-Log -Level Warning -Message "No site found matching TestSite '$TestSite'"
            exit 0
        }
    }

    $alerts = Get-UniFiAlerts -Session $session -Sites $sites

    # ── TEST MODE — dump first alert and exit ─────────────────────────────
    if ($TestMode) {
        if ($alerts.Count -eq 0) {
            Write-Output '=== TEST MODE - No unarchived alerts found ==='
            exit 0
        }

        $testAlert = $alerts[0]
        $prefix    = Get-AccountPrefix -SiteName $testAlert.site_name

        Write-Output ''
        Write-Output '=== TEST MODE - RAW UNIFI ALERT (no ticket created) ==='
        Write-Output ''
        $testAlert | ConvertTo-Json -Depth 10
        Write-Output ''
        Write-Output "Account prefix parsed: $(if ($prefix) { $prefix } else { '(none — site name has no underscore)' })"
        exit 0
    }

    # ── NORMAL MODE — process all alerts ─────────────────────────────────
    $dedupLog = Read-DedupLog
    $dedupLog = Remove-ExpiredDedupEntries -Log $dedupLog

    $ticketsCreated = 0
    $alertsSkipped  = 0

    foreach ($alert in $alerts) {
        try {
            $alertId  = $alert._id
            $siteName = $alert.site_name

            Write-Log -Level Info -Message "Processing alert $alertId from site '$siteName'"

            # 1 — Parse account prefix
            $prefix = Get-AccountPrefix -SiteName $siteName
            if (-not $prefix) { $alertsSkipped++; continue }

            # 2 — Look up AutoTask company
            $company = Find-AutoTaskCompany -AccountPrefix $prefix
            if (-not $company) { $alertsSkipped++; continue }

            # 3 — Deduplication check
            if (Test-AlreadyLogged -Log $dedupLog -AlertId $alertId) {
                Write-Log -Level Info -Message "Alert $alertId already has a ticket ($(($dedupLog[$alertId]).ticketId)) — skipping"
                $alertsSkipped++
                continue
            }

            # 4 — Get primary contact (best-effort; ticket still created if null)
            $contact = Get-PrimaryContact -CompanyID $company.CompanyID

            # 5 — Create ticket
            $ticketId = New-AutoTaskTicket -Alert $alert -Company $company -Contact $contact -AccountPrefix $prefix
            if (-not $ticketId) {
                # Ticket creation failed — do NOT write dedup entry so it retries next run
                Write-Log -Level Warning -Message "Ticket creation failed for alert $alertId — will retry next run"
                continue
            }

            # 6 — Record in dedup log
            Write-DedupLog -Log $dedupLog -AlertId $alertId -TicketId $ticketId
            $ticketsCreated++
        }
        catch {
            Write-Log -Level Error -Message "Unhandled error processing alert $($alert._id): $_"
        }
    }

    Write-Log -Level Info -Message "Run complete — $ticketsCreated ticket(s) created, $alertsSkipped alert(s) skipped"
    exit 0
}
catch {
    Write-Log -Level Error -Message "Fatal error: $_"
    exit 1
}

#endregion MAIN
