<#
.SYNOPSIS
    Local test script — connects to UniFi and displays alerts without touching AutoTask.

.DESCRIPTION
    Fill in the variables below and run the script. It will:
      1. Authenticate to the UniFi Cloud API
      2. List all sites visible to the API key
      3. Fetch unarchived alerts for each site
      4. Show the parsed account prefix and the ticket title that would be created
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

# The console ID from your unifi.ui.com URL:
# https://unifi.ui.com/consoles/{CONSOLE_ID}/network/default/dashboard
# Leave blank to use api.ui.com proxy (may 404 — fill this in if so)
$UNIFI_CONSOLE_ID  = ''

# Optional: set to a site display name to test a single site, or leave blank for all sites
$TEST_SITE         = ''

# Maximum alert age in hours (0 = show all events regardless of age)
$MAX_AGE_HOURS     = 0

# Only these event keys are shown — everything else (client connects, roams, etc.) is excluded.
# Add or remove keys here to tune what counts as a negative event.
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
    if ($Body)   { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params['SkipCertificateCheck'] = $true }
    Invoke-RestMethod @params
}


# ---------------------------------------------------------------------------
# Step 1 — Validate API key
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
# Step 2 — List sites
# ---------------------------------------------------------------------------

Write-Section 'STEP 2 — Sites'

$sites = $sitesResponse.data

if ($TEST_SITE -ne '') {
    $sites = $sites | Where-Object { $_.name -eq $TEST_SITE }
    if ($sites.Count -eq 0) {
        Write-Fail "No site found matching '$TEST_SITE'"
        Write-Info "Available sites:"
        $sitesResponse.data | ForEach-Object { Write-Info "  $($_.name)  (id: $($_.siteId))" }
        exit 1
    }
    Write-Ok "Filtered to site: $TEST_SITE"
}
else {
    Write-Info "Showing all $($sites.Count) site(s) — set TEST_SITE to filter"
}

$sites | ForEach-Object {
    Write-Host "    $($_.name)  (siteId: $($_.siteId))" -ForegroundColor White
}

# Dump raw fields of the first site — helps identify the correct ID for the alarm endpoint
Write-Host ''
Write-Host '  Raw fields from first site object:' -ForegroundColor DarkGray
$sites[0].PSObject.Properties | ForEach-Object {
    Write-Host "    $($_.Name) = $($_.Value)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 3 — Fetch alerts
# ---------------------------------------------------------------------------

Write-Section 'STEP 3 — Event Log'

$cutoff    = if ($MAX_AGE_HOURS -gt 0) { (Get-Date).ToUniversalTime().AddHours(-$MAX_AGE_HOURS) } else { $null }
$allAlerts = @()

foreach ($site in $sites) {
    $siteId   = $site.siteId
    $siteName = $site.name

    # Build the event endpoint URL.
    # The UI path shows the site as "default" — if the UUID causes 404s, set UNIFI_CONSOLE_ID.
    try {
        $alarmUri = if ($UNIFI_CONSOLE_ID) {
            "https://unifi.ui.com/proxy/network/v1/api/sites/$siteId/events"
        } else {
            "$UNIFI_BASE_URL/proxy/network/api/s/default/stat/event"
        }
        Write-Info "Trying: $alarmUri"
        $response   = Invoke-UniFiRequest -Uri $alarmUri
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
        Write-Ok "[$siteName]  $($unarchived.Count) unarchived alert(s)"
    }
    catch {
        Write-Fail "[$siteName]  Could not fetch alerts: $($_)"
        Write-Warn "  URL tried: $alarmUri"
        Write-Warn "  Try setting UNIFI_CONSOLE_ID to the ID from your unifi.ui.com URL"
        Write-Warn "  e.g. https://unifi.ui.com/consoles/{THIS_PART}/network/default/dashboard"
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Alert detail
# ---------------------------------------------------------------------------

if ($allAlerts.Count -eq 0) {
    Write-Section 'RESULT'
    Write-Ok 'No unarchived alerts found — nothing would be sent to AutoTask'
    exit 0
}

Write-Section "STEP 4 — Alert Detail ($($allAlerts.Count) total)"

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

# ---------------------------------------------------------------------------
# Step 5 — Raw JSON (optional — uncomment if needed)
# ---------------------------------------------------------------------------

# Write-Section 'RAW ALERT JSON'
# $allAlerts | ConvertTo-Json -Depth 10 | Write-Host

Write-Section 'DONE'
Write-Info "$($allAlerts.Count) alert(s) found across $($sites.Count) site(s)"
Write-Info "No AutoTask calls were made. No data was written."
