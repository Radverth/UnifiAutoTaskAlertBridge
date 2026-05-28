<#
.SYNOPSIS
    Local test script — connects to UniFi and displays alerts without touching AutoTask.

.DESCRIPTION
    Fill in the variables below and run the script. It will:
      1. Validate the API key
      2. Call /v1/hosts to discover host IDs
      3. List all sites
      4. Probe candidate event endpoint URLs on the first site to find one that works
      5. Fetch and display negative events across all sites using the working URL pattern
    No AutoTask calls are made. Nothing is written anywhere.

.USAGE
    .\Test-UniFiAlerts.ps1
#>

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ============================================================
# EDIT THESE VALUES
# ============================================================

$UNIFI_BASE_URL    = 'https://api.ui.com'
$UNIFI_API_KEY     = 'YOUR-API-KEY-HERE'

# Optional: set to a site display name to test a single site, or leave blank for all sites
$TEST_SITE         = ''

# Maximum alert age in hours (0 = show all events regardless of age)
$MAX_AGE_HOURS     = 0

# Only these event keys are treated as negative/actionable events.
$NEGATIVE_KEYS = @(
    'EVT_AP_Disconnected',
    'EVT_AP_Restarted',
    'EVT_AP_UpgradeScheduled',
    'EVT_SW_Disconnected',
    'EVT_SW_Restarted',
    'EVT_GW_Disconnected',
    'EVT_GW_WANTransitioned',
    'EVT_GW_VPNDown',
    'EVT_LTE_Disconnected'
)

# ============================================================
# END OF CONFIG — nothing below needs changing
# ============================================================

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Write-Ok     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green  }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red    }
function Write-Info   { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor White  }

function Invoke-UniFiRequest {
    param([string]$Uri, [string]$Method = 'GET', [hashtable]$Body)
    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = @{ 'X-API-Key' = $UNIFI_API_KEY }
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params['SkipCertificateCheck'] = $true }
    Invoke-RestMethod @params
}

function Test-EventUrl {
    param([string]$Uri, [string]$Label)
    Write-Info "Trying [$Label]: $Uri"
    try {
        $r = Invoke-UniFiRequest -Uri $Uri
        # Accept any response that has a data array (even empty is OK — it means the endpoint exists)
        if ($null -ne $r.data) {
            Write-Ok "SUCCESS — $($r.data.Count) event(s) returned"
            return $r
        }
        Write-Warn "Response has no .data field — may be wrong format"
        Write-Warn "Raw: $($r | ConvertTo-Json -Depth 3 -Compress)"
        return $null
    }
    catch {
        $msg = $_.ToString()
        if ($msg -match '404') { Write-Fail "404 Not Found" }
        elseif ($msg -match '401|403') { Write-Fail "Auth error: $msg" }
        else { Write-Fail $msg }
        return $null
    }
}

# ---------------------------------------------------------------------------
# Step 1 — Validate API key + get sites
# ---------------------------------------------------------------------------

Write-Section 'STEP 1 — UniFi API Key Validation'

try {
    $sitesResponse = Invoke-UniFiRequest -Uri "$UNIFI_BASE_URL/ea/sites"
    Write-Ok "API key accepted — $($sitesResponse.data.Count) site(s) visible"
}
catch {
    Write-Fail "API key rejected or unreachable: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2 — Get hosts (discover numeric host IDs)
# ---------------------------------------------------------------------------

Write-Section 'STEP 2 — Hosts (v1/hosts)'

$hostIds = @()

try {
    $hostsResponse = Invoke-UniFiRequest -Uri "$UNIFI_BASE_URL/v1/hosts"
    Write-Ok "$($hostsResponse.data.Count) host(s) found"
    $hostsResponse.data | ForEach-Object {
        Write-Host "    id=$($_.id)  type=$($_.type)  ip=$($_.ipAddress)" -ForegroundColor White
        $hostIds += $_.id
    }
    Write-Host ''
    Write-Host '  Raw fields from first host object:' -ForegroundColor DarkGray
    $hostsResponse.data[0].PSObject.Properties | ForEach-Object {
        Write-Host "    $($_.Name) = $($_.Value)" -ForegroundColor DarkGray
    }
}
catch {
    Write-Warn "Could not call /v1/hosts (non-fatal): $_"
    Write-Info "Host-scoped proxy URL patterns will be skipped."
}

# ---------------------------------------------------------------------------
# Step 3 — List sites
# ---------------------------------------------------------------------------

Write-Section 'STEP 3 — Sites'

$sites = $sitesResponse.data

if ($TEST_SITE -ne '') {
    $sites = $sites | Where-Object { $_.meta.desc -eq $TEST_SITE }
    if ($sites.Count -eq 0) {
        Write-Fail "No site found matching '$TEST_SITE'"
        Write-Info "Available sites:"
        $sitesResponse.data | ForEach-Object {
            Write-Info "  '$($_.meta.desc)'  (network: $($_.meta.name)  siteId: $($_.siteId))"
        }
        exit 1
    }
    Write-Ok "Filtered to site: $TEST_SITE"
}
else {
    Write-Info "Showing all $($sites.Count) site(s) — set TEST_SITE to filter"
}

$sites | ForEach-Object {
    Write-Host "    '$($_.meta.desc)'  (network: $($_.meta.name)  siteId: $($_.siteId)  hostId: $($_.hostId))" -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Step 4 — Probe candidate event URLs on the first site
# ---------------------------------------------------------------------------

Write-Section 'STEP 4 — Endpoint Discovery (first site only)'

$probe      = $sites[0]
$probeName  = $probe.meta.desc
$probeNet   = $probe.meta.name    # e.g. "default"
$probeSite  = $probe.siteId       # UUID
$probeHostRaw = $probe.hostId
$probeHostStripped = if ($probeHostRaw) { ($probeHostRaw -split ':')[0] } else { '' }

Write-Info "Probing site: '$probeName'  network=$probeNet  siteId=$probeSite"
Write-Info "hostId (raw): $probeHostRaw"
Write-Info "hostId (stripped): $probeHostStripped"
Write-Host ''

# Build list of candidate URLs to try
$candidates = [ordered]@{
    # Classic cloud proxy — no console ID needed
    'proxy/stat/event (meta.name)'     = "$UNIFI_BASE_URL/proxy/network/api/s/$probeNet/stat/event"
    'proxy/stat/event (siteId)'        = "$UNIFI_BASE_URL/proxy/network/api/s/$probeSite/stat/event"
    # Network Integration API through cloud proxy
    'integration/v1 (siteId)'          = "$UNIFI_BASE_URL/proxy/network/integration/v1/sites/$probeSite/events"
    'integration/v1 (meta.name)'       = "$UNIFI_BASE_URL/proxy/network/integration/v1/sites/$probeNet/events"
    # v1/consoles path (previously attempted)
    'v1/consoles (hostId stripped)'    = "$UNIFI_BASE_URL/v1/consoles/$probeHostStripped/network/$probeNet/events"
    'v1/consoles+siteId (stripped)'    = "$UNIFI_BASE_URL/v1/consoles/$probeHostStripped/network/$probeSite/events"
}

# Add host-scoped proxy variants for each numeric host ID from /v1/hosts
foreach ($hid in $hostIds) {
    $candidates["hosts/$hid/proxy (meta.name)"] = "$UNIFI_BASE_URL/hosts/$hid/proxy/network/api/s/$probeNet/stat/event"
    $candidates["hosts/$hid/proxy (siteId)"]    = "$UNIFI_BASE_URL/hosts/$hid/proxy/network/api/s/$probeSite/stat/event"
}

$workingUrl     = $null
$workingPattern = $null

foreach ($label in $candidates.Keys) {
    $url = $candidates[$label]
    $result = Test-EventUrl -Uri $url -Label $label
    if ($result) {
        $workingUrl     = $url
        $workingPattern = $label
        Write-Ok "Working pattern found: [$workingPattern]"
        Write-Ok "URL template: $workingUrl"
        break
    }
    Write-Host ''
}

if (-not $workingUrl) {
    Write-Section 'RESULT'
    Write-Fail 'No working event endpoint found. All candidate URLs returned errors.'
    Write-Info 'Paste the full output above into a support request or GitHub issue.'
    exit 1
}

# ---------------------------------------------------------------------------
# Step 5 — Fetch events for all sites using the working pattern
# ---------------------------------------------------------------------------

Write-Section "STEP 5 — Event Log (using: $workingPattern)"

$cutoff    = if ($MAX_AGE_HOURS -gt 0) { (Get-Date).ToUniversalTime().AddHours(-$MAX_AGE_HOURS) } else { $null }
$allAlerts = @()

foreach ($site in $sites) {
    $siteName  = $site.meta.desc
    $networkId = $site.meta.name
    $siteId    = $site.siteId
    $rawHostId = $site.hostId
    $stripped  = if ($rawHostId) { ($rawHostId -split ':')[0] } else { '' }

    # Substitute site-specific values into the working URL pattern
    $eventUri = $workingUrl `
        -replace [regex]::Escape($probeNet),    $networkId `
        -replace [regex]::Escape($probeSite),   $siteId `
        -replace [regex]::Escape($probeHostStripped), $stripped

    Write-Info "[$siteName]  $eventUri"

    try {
        $response   = Invoke-UniFiRequest -Uri $eventUri
        $unarchived = @($response.data | Where-Object { $NEGATIVE_KEYS -contains $_.key })

        if ($cutoff) {
            $unarchived = @($unarchived | Where-Object {
                try {
                    $t = [datetime]::Parse($_.datetime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    $t -ge $cutoff
                }
                catch { $true }
            })
        }

        foreach ($a in $unarchived) {
            $a | Add-Member -MemberType NoteProperty -Name '_site_name' -Value $siteName -Force
        }

        $allAlerts += $unarchived
        Write-Ok "[$siteName]  $($unarchived.Count) negative event(s)"
    }
    catch {
        Write-Fail "[$siteName]  Could not fetch events: $($_)"
    }
}

# ---------------------------------------------------------------------------
# Step 6 — Alert detail
# ---------------------------------------------------------------------------

if ($allAlerts.Count -eq 0) {
    Write-Section 'RESULT'
    Write-Ok 'No matching negative events found'
    exit 0
}

Write-Section "STEP 6 — Alert Detail ($($allAlerts.Count) total)"

foreach ($alert in $allAlerts) {
    $device = if ($alert.ap_name)     { $alert.ap_name }
              elseif ($alert.sw_name) { $alert.sw_name }
              elseif ($alert.gw_name) { $alert.gw_name }
              elseif ($alert.ap)      { $alert.ap }
              elseif ($alert.sw)      { $alert.sw }
              else { 'Unknown Device' }

    Write-Host ''
    Write-Host "  Event ID : $($alert._id)" -ForegroundColor White
    Write-Host "  Site     : $($alert._site_name)" -ForegroundColor White
    Write-Host "  Device   : $device" -ForegroundColor White
    Write-Host "  Key      : $($alert.key)" -ForegroundColor White
    Write-Host "  Message  : $($alert.msg)" -ForegroundColor White
    Write-Host "  Time     : $($alert.datetime)" -ForegroundColor White
}

# Uncomment to dump raw JSON:
# Write-Section 'RAW ALERT JSON'
# $allAlerts | ConvertTo-Json -Depth 10 | Write-Host

Write-Section 'DONE'
Write-Info "$($allAlerts.Count) event(s) found across $($sites.Count) site(s)"
Write-Info "Working endpoint pattern: $workingPattern"
Write-Info "No AutoTask calls were made. No data was written."
