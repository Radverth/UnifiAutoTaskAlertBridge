# UniFi Autotask Monitor

A PowerShell script for MSPs that queries the **UniFi Cloud API** and automatically raises formatted tickets in **Autotask PSA** for network events requiring attention.

Two companion **Datto RMM monitor components** are also included for proactive service clients — one using a manually maintained host list, one that reads site configuration automatically from the Datto RMM API.

---

## Contents

| Script | Purpose |
|--------|---------|
| `Invoke-UniFiAlerts.ps1` | Full Autotask integration — queries UniFi and creates/suppresses tickets |
| `Invoke-UniFiDattoMonitor-Manual.ps1` | Datto RMM monitor — host IDs defined in the script |
| `Invoke-UniFiDattoMonitor-DattoAPI.ps1` | Datto RMM monitor — reads host IDs from site variables via Datto API |

---

## Requirements

- PowerShell 5.1 or higher (compatible with PowerShell 7+)
- A UniFi Cloud API key (from [account.ui.com](https://account.ui.com))
- An Autotask API user with an integration code *(Invoke-UniFiAlerts.ps1 only)*
- Network access to `api.ui.com`
- For Datto monitors: an always-on machine with the Datto RMM agent installed

---

## Invoke-UniFiAlerts.ps1 — Autotask Integration

### Quick Start

1. Open `Invoke-UniFiAlerts.ps1` and fill in the `$Config` block at the top of the file.
2. Validate your environment:
   ```powershell
   .\Invoke-UniFiAlerts.ps1 -CheckDeps
   ```
3. Preview alerts without creating tickets:
   ```powershell
   .\Invoke-UniFiAlerts.ps1 -TestMode
   ```
4. Run normally (creates tickets in Autotask):
   ```powershell
   .\Invoke-UniFiAlerts.ps1
   ```

### Configuration

All settings live in the `$Config` hashtable at the top of the script. No values are hardcoded anywhere else.

| Key | Description | Example |
|-----|-------------|---------|
| `UnifiApiKey` | UniFi Cloud API key from ui.com | `abc123...` |
| `UnifiApiBase` | UniFi API base URL | `https://api.ui.com/v1` |
| `UnifiPageSize` | Results per API page | `100` |
| `AutotaskZone` | Your Autotask zone number | `'1'` |
| `AutotaskApiUser` | Autotask API user email | `api@yourcompany.com` |
| `AutotaskApiSecret` | Autotask API secret key | `secret123` |
| `AutotaskIntegrationCode` | Integration code from API user record | `ABC123` |
| `DefaultAccountName` | Fallback Autotask company name | `'Affinity IT'` |
| `TicketQueueId` | Autotask queue ID for raised tickets | `29682933` |
| `TicketStatusNew` | Autotask status ID for 'New' | `1` |
| `TicketSourceMonitor` | Autotask source ID for 'Monitoring Alert' | `8` |
| `ClosedStatusIds` | Status IDs representing closed/resolved tickets | `@(5, 9, 10)` |
| `TxRetryWarningPct` | WAN retry % for Warning ticket | `50.0` |
| `TxRetryCriticalPct` | WAN retry % for Critical ticket | `55.0` |
| `WanUptimeWarningPct` | WAN uptime % below which a ticket is raised | `99.0` |
| `FirmwareExclusions` | Device shortname → versions to suppress firmware alerts for | `@{ 'US24P250' = @('7.2.123') }` |
| `SiteExclusions` | Site display names (lowercase) to skip entirely | `@('affinity controller')` |
| `GroupAlertsBySite` | Combine all alerts for the same site into a single ticket | `$false` |
| `TestModeOutputFile` | Path to write test mode preview output; empty string disables | `'C:\Scripts\preview.txt'` |
| `SiteMapping` | UniFi host name → Autotask company name | `@{ 'client site' = 'Acme Corp' }` |

### Finding Your Site Names

Run `-TestMode` to see the resolved name for each site — it is logged as:
```
[INFO] Host '1C0B8B...' → 'Client Site Name'
[INFO] Processing site: 'Client Site Name'
```

Use these resolved names (lowercased) as the keys in `SiteMapping`.

### Site Mapping

```powershell
SiteMapping = @{
    'affinity it head office' = 'Affinity IT'
    'acme corporation'        = 'Acme Corporation'
    'retail store ltd'        = 'Retail Client Ltd'
}
```

If a site is not in the mapping, the script falls back to `DefaultAccountName` and logs a warning.

### Closed Status IDs

Populate `ClosedStatusIds` from your Autotask tenant's ticket status picklist. Tickets in these statuses are considered resolved and will not block new alert tickets.

```powershell
ClosedStatusIds = @(5, 9, 10)   # Complete, Closed, Cancelled
```

### Execution Modes

**Normal** — queries UniFi, creates tickets in Autotask:
```powershell
.\Invoke-UniFiAlerts.ps1
```

**Test Mode** — queries UniFi, prints a preview, makes no writes to Autotask:
```powershell
.\Invoke-UniFiAlerts.ps1 -TestMode
```

**CheckDeps** — pre-flight validation only, no API calls:
```powershell
.\Invoke-UniFiAlerts.ps1 -CheckDeps
```

### Scheduling

Use **Windows Task Scheduler** to run on a regular interval (e.g. every 15 minutes):

1. Open Task Scheduler → Create Basic Task
2. Set trigger to your desired interval
3. Action: Start a program
   - Program: `powershell.exe`
   - Arguments: `-NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-UniFiAlerts.ps1"`

---

## Datto RMM Monitors — Proactive Customers

Two monitor scripts are provided. Both run as **Datto RMM monitor components** on a single always-on machine at your office. They output in the Datto RMM result format so the platform raises and clears alerts automatically.

> **A machine is required.** Datto RMM monitor components execute on a managed device (an agent-installed machine). There is no agentless execution. Any always-on server or workstation at your office works — it only needs outbound HTTPS to `api.ui.com`.

### Which script to use

| | Manual | Datto API |
|---|---|---|
| Host IDs configured | In the script | In a site variable per client |
| Adding a new client | Edit script, redeploy | Set site variable, picked up automatically |
| Datto API credentials needed | No | Yes |
| Best for | Small fixed client lists | Growing proactive base |

---

### Option 1 — Manual Host List (`Invoke-UniFiDattoMonitor-Manual.ps1`)

Host IDs are defined directly in the script. No Datto API credentials required.

#### Setup

**Step 1 — Get your UniFi host IDs**

Log in to [account.ui.com](https://account.ui.com), go to **Consoles**, and copy the host ID for each client controller. It is the alphanumeric string in the URL or shown in the console detail view.

**Step 2 — Configure the script**

Open `Invoke-UniFiDattoMonitor-Manual.ps1` and fill in the top section:

```powershell
$UnifiApiKey = 'your-unifi-api-key'

$HostEntries = @(
    @{ HostId = 'abc123def456';  NetworkId = $null      }   # whole controller
    @{ HostId = 'xyz789uvw012';  NetworkId = 'net456'   }   # specific network only
)
```

Set `NetworkId = $null` to monitor all networks on a controller. Set it to a UniFi network/site ID to monitor a specific network only — useful when a controller hosts multiple clients.

**Step 3 — Create a Datto RMM component**

1. In Datto RMM go to **Manage > Components > New Component**
2. Set type to **Monitor**
3. Paste the full script contents into the script body
4. Save the component

**Step 4 — Deploy and schedule**

1. Go to **Manage > Policies** and create a new policy (or edit an existing one)
2. Add the monitor component
3. Set the schedule — every **15 or 30 minutes** is recommended
4. Target the policy at your central monitoring machine (the always-on device at your office)

Datto RMM will run the script on that schedule. If the script exits with code 1, Datto raises an alert. Exit code 0 clears it.

---

### Option 2 — Datto API (`Invoke-UniFiDattoMonitor-DattoAPI.ps1`)

Authenticates with the Datto RMM API, queries a filter/dynamic group to find all proactive service sites, reads the `UnifiSiteKeys` site variable from each, then checks UniFi for every discovered host. Sites not in the group are never queried.

#### Prerequisites

- Datto RMM API credentials (key + secret)
- A filter/dynamic group in Datto RMM containing all proactive service devices
- The `UnifiSiteKeys` site variable set on each proactive site that has UniFi

#### Step 1 — Get Datto RMM API credentials

1. In Datto RMM go to **Setup > Users > API Keys**
2. Click **New API Key** and note the **API Key** and **API Secret Key** — the secret is only shown once
3. Identify your zone from your Datto RMM URL: `https://{zone}.centrastage.net`
   - Valid zones: `pinotage`, `merlot`, `concord`, `vidal`, `zinfandel`, `syrah`

#### Step 2 — Find your filter ID

1. In Datto RMM go to **Manage > Filters**
2. Open your proactive service filter (or create one that targets devices at proactive service sites)
3. The filter ID is in the URL: `…/filters/12345/edit` → ID is `12345`

#### Step 3 — Set the UnifiSiteKeys site variable on each client site

For each proactive client that has UniFi, set a site variable named exactly `UnifiSiteKeys`:

1. In Datto RMM go to **Sites**, open the client site
2. Go to **Variables** and click **New Variable**
3. Name: `UnifiSiteKeys`
4. Value — use one of these formats:

| Scenario | Value format |
|----------|-------------|
| One controller, all networks | `HostID` |
| One controller, specific network | `HostID\|NetworkID` |
| Two controllers | `HostID1,HostID2` |
| Two networks on one controller | `HostID\|NetworkID1,HostID\|NetworkID2` |
| Mixed | `HostID1,HostID2\|NetworkID2` |

The UniFi host ID is the alphanumeric string on the console detail page at [account.ui.com](https://account.ui.com). The network ID is the site/network ID from the UniFi API — run the manual script in a test first to confirm names resolve correctly.

Sites in the proactive group with no `UnifiSiteKeys` variable are silently skipped — not every proactive client needs to have UniFi.

#### Step 4 — Configure the script

Open `Invoke-UniFiDattoMonitor-DattoAPI.ps1` and fill in the top section:

```powershell
$DattoApiUrl    = 'https://zinfandel-api.centrastage.net'   # replace zone name
$DattoApiKey    = 'your-datto-api-key'
$DattoApiSecret = 'your-datto-api-secret'
$DattoFilterId  = 12345                                      # your proactive filter ID
$UnifiApiKey    = 'your-unifi-api-key'
```

To use a Datto global variable for the UniFi key instead of hardcoding it, comment out the `$UnifiApiKey = '...'` line and uncomment:
```powershell
# $UnifiApiKey = $env:CS_UnifiApiKey
```
Then create a global variable named `UnifiApiKey` in Datto RMM under **Setup > Global Variables**.

#### Step 5 — Create a Datto RMM component

1. In Datto RMM go to **Manage > Components > New Component**
2. Set type to **Monitor**
3. Paste the full script contents into the script body
4. Save the component

#### Step 6 — Deploy and schedule

1. Go to **Manage > Policies** and create or edit a policy
2. Add the monitor component
3. Set the schedule — every **15 or 30 minutes** is recommended
4. Target the policy at your central monitoring machine only (the single always-on machine at your office — **not** at all proactive sites)

#### Adding a new proactive client

1. Ensure the client's devices are in your proactive service filter in Datto RMM
2. Set the `UnifiSiteKeys` site variable on their Datto site
3. No script changes or redeployment needed — the monitor picks them up on the next run

---

## Alert Conditions

| Alert | Trigger |
|-------|---------|
| Device Offline | `status = 'offline'` (single device) |
| Multiple Devices Offline | `offlineDevices > 1` — lists device names |
| High WAN Packet Retry (Warning) | `txRetry > TxRetryWarningPct` |
| High WAN Packet Retry (Critical) | `txRetry > TxRetryCriticalPct` |
| WAN Uptime Degraded | `wanUptime < WanUptimeWarningPct` |
| Critical Notifications Present | `criticalNotifications > 0` |

*(Firmware alerts and internet issue detection are available in `Invoke-UniFiAlerts.ps1` only.)*

---

## Duplicate Suppression (Invoke-UniFiAlerts.ps1 only)

Before raising any ticket the script queries Autotask for an existing open ticket matching the same title prefix and company. If one is found, the new ticket is suppressed:

```
[SUPPRESSED] Open ticket already exists (ID: 98765) — NETWORK ALERT — ClientSite: Switch-Core-01 is offline
```

In `-TestMode`, suppressed alerts are still shown in the preview but marked as `SUPPRESSED — WOULD NOT CREATE`.

---

## Console Colour Coding

| Colour | Meaning |
|--------|---------|
| Green | Success / PASS |
| Yellow | Warning / skipped / suppressed |
| Red | Error / FAIL |
| Cyan | Informational |

---

## Ticket Structure (Invoke-UniFiAlerts.ps1)

Each ticket includes:

- **Alert Summary** — plain-English description of the issue
- **Device Details** — name, MAC, IP, model, firmware, site, host ID
- **Network Context** — WAN uptime, TX retry rate, ISP name/ASN, external IP, client counts
- **Detected At** — ISO 8601 timestamp of the script run
- **Recommended Mitigation** — step-by-step actions specific to the alert type
- **Further Information** — link to UniFi documentation

---

## Troubleshooting

**`PropertyNotFoundException` on `$site.name` or similar**
Requires PowerShell 5.1+. This can also appear if `Set-StrictMode` is set externally in your profile — the script sets its own strict mode and does not require anything in your profile.

**`[ERROR] Failed to retrieve UniFi sites`**
Check that `UnifiApiKey` is set correctly and that outbound HTTPS to `api.ui.com` is not blocked. Run `-CheckDeps` to confirm TLS 1.2 is available.

**`DATTO API ERROR: Authentication failed`**
Verify `DattoApiKey` and `DattoApiSecret` are correct and that the API key has not been revoked. Confirm the `$DattoApiUrl` zone matches your Datto RMM tenant URL.

**No sites found in filter**
Confirm the filter ID is correct and that the filter contains at least one device. Check in Datto RMM under Manage > Filters that the filter returns results.

**Sites processing but showing blank names**
The UniFi site may not have a description set. Log in to the UniFi console → Settings → Site and set a Site Name.

**Duplicate tickets being raised**
Ensure `ClosedStatusIds` includes all status IDs your Autotask tenant uses for resolved/closed/cancelled tickets. Retrieve the correct IDs from Autotask: Admin → Picklists → Ticket → Status.

---

## Out of Scope

- Auto-resolution of tickets when a device comes back online
- Built-in scheduling
- UniFi on-premises controller (Network Application) — Cloud API only
- SMS or email alerting outside of Autotask
- Multi-language support
