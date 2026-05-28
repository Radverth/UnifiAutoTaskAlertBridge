# UniFi Autotask Monitor

A PowerShell script for MSPs that queries the **UniFi Cloud API** and automatically raises formatted tickets in **Autotask PSA** for network events requiring attention.

---

## Requirements

- PowerShell 5.1 or higher (compatible with PowerShell 7+)
- A UniFi Cloud API key (obtained from [account.ui.com](https://account.ui.com))
- An Autotask API user with an integration code
- Network access to `api.ui.com` and `webservices{zone}.autotask.net`

---

## Quick Start

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

---

## Configuration

All settings live in the `$Config` hashtable at the top of the script. No values are hardcoded anywhere else. Edit this block only — do not modify the logic below it.

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
| `TxRetryWarningPct` | WAN retry % for Warning ticket | `15.0` |
| `TxRetryCriticalPct` | WAN retry % for Critical ticket | `20.0` |
| `WanUptimeWarningPct` | WAN uptime % below which a ticket is raised | `99.9` |
| `FirmwareExclusions` | Device shortname → versions to suppress firmware alerts for | `@{ 'US24P250' = @('7.2.123') }` |
| `SiteMapping` | UniFi site name → Autotask company name | `@{ 'clientsite1' = 'Acme Corp' }` |

### Finding Your Site Names

The script resolves the human-readable site name by calling `GET /v1/hosts/{id}` for each site's `hostId` and reading the `hostName` field. This is the name shown in the UniFi console (e.g. `Client Site Name`) rather than the internal `meta.name` slug (e.g. `default`).

Run `-TestMode` to see the resolved name for each site — it is logged as:
```
[INFO] Host '1C0B8B...' → 'Client Site Name'
[INFO] Processing site: 'Client Site Name'
```

Use these resolved names (lowercased) as the keys in `SiteMapping`.

### Site Mapping

Map your UniFi host names (lowercase) to exact Autotask company names:

```powershell
SiteMapping = @{
    'affinity it head office' = 'Affinity IT'
    'acme corporation'        = 'Acme Corporation'
    'retail store ltd'        = 'Retail Client Ltd'
}
```

If a site is not in the mapping, the script falls back to `DefaultAccountName` and logs a warning.

### Closed Status IDs

Populate `ClosedStatusIds` from your Autotask tenant's ticket status picklist. These are used for duplicate suppression — tickets in these statuses are considered resolved and will not block new alert tickets.

```powershell
ClosedStatusIds = @(5, 9, 10)   # Complete, Closed, Cancelled
```

---

## Execution Modes

### Normal Mode (default)

Queries all UniFi sites and devices, evaluates alert conditions, and creates tickets in Autotask. Duplicate suppression prevents re-raising tickets that are already open.

```powershell
.\Invoke-UniFiAlerts.ps1
```

### Test Mode (`-TestMode`)

Queries UniFi as normal but makes **no writes to Autotask**. Prints a full colour-coded preview of every ticket that would be created, including duplicate suppression results. Safe to run at any time.

```powershell
.\Invoke-UniFiAlerts.ps1 -TestMode
```

Test mode can also be enabled via the `$Config` block — useful when running from a platform that cannot pass switch parameters (e.g. Datto RMM):

```powershell
TestMode = $true
```

The `-TestMode` switch and the config variable can be used interchangeably; either will activate test mode.

### CheckDeps Mode (`-CheckDeps`)

Runs a pre-flight checklist and exits. No API calls are made. Use this to validate your environment before the first run.

```powershell
.\Invoke-UniFiAlerts.ps1 -CheckDeps
```

---

## Alert Conditions

| Alert | Priority | Trigger |
|-------|----------|---------|
| Device Offline ★ | Critical | `status = 'offline'` |
| Firmware Update Available ★ | High | `firmwareStatus ≠ 'upToDate'` |
| High WAN Packet Retry (Warning) | Medium | `txRetry > TxRetryWarningPct` |
| High WAN Packet Retry (Critical) | Critical | `txRetry > TxRetryCriticalPct` |
| WAN Uptime Degraded | High | `wanUptime < WanUptimeWarningPct` |
| Critical Notifications Present | High | `criticalNotifications > 0` |
| Internet Issues Detected | High | `internetIssues` array non-empty |
| Multiple Devices Offline | Critical | `offlineDevices > 1` |
| No Gateway Device | Critical | `gatewayDevices = 0` |

★ = Hard requirement, always evaluated.

---

## Duplicate Suppression

Before raising any ticket the script queries Autotask for an existing open ticket matching the same title prefix and company. If one is found, the new ticket is suppressed and the existing ticket ID is logged:

```
[SUPPRESSED] Open ticket already exists (ID: 98765) — NETWORK ALERT — ClientSite: Switch-Core-01 is offline
```

In `-TestMode`, suppressed alerts are still shown in the preview but marked as `SUPPRESSED — WOULD NOT CREATE`.

---

## Scheduling

This script has no built-in scheduler. Use **Windows Task Scheduler** to run it on a regular interval (e.g. every 15 minutes):

1. Open Task Scheduler → Create Basic Task
2. Set trigger to your desired interval
3. Action: Start a program
   - Program: `powershell.exe`
   - Arguments: `-NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-UniFiAlerts.ps1"`

---

## Console Colour Coding

| Colour | Meaning |
|--------|---------|
| Green | Success / PASS |
| Yellow | Warning / skipped / suppressed |
| Red | Error / FAIL |
| Cyan | Informational |

---

## Ticket Structure

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
The script requires PowerShell 5.1+. If you see this on an older build, upgrade PowerShell. This error can also appear if `Set-StrictMode` is set externally in your profile — the script sets its own strict mode internally and does not require anything in your profile.

**`[ERROR] Failed to retrieve UniFi sites`**
Check that `UnifiApiKey` is set correctly and that outbound HTTPS to `api.ui.com` is not blocked by a firewall. Run `-CheckDeps` to confirm TLS 1.2 is available.

**Sites processing but showing blank names**
Your UniFi site may not have a description set. Log in to the UniFi console → Settings → Site → set a Site Name. The script will fall back to the internal slug if no description is present.

**`[ERROR] Failed to retrieve devices for host '...'`**
This is normal for console-only hosts that have no adopted devices. The script continues to the next site. If it affects sites that do have devices, check that the `hostId` returned by the sites API is being passed correctly — run `-TestMode` and check the `[INFO] Processing site` lines.

**Duplicate tickets being raised**
Ensure `ClosedStatusIds` includes all status IDs your Autotask tenant uses for resolved/closed/cancelled tickets. Retrieve the correct IDs from Autotask: Admin → Picklists → Ticket → Status.

**No alerts triggered despite known issues**
Run `-TestMode` to see what the script is evaluating. Check that `SiteMapping` entries match the exact site slug (lowercase). If a site falls back to `DefaultAccountName`, confirm that company exists in Autotask with an exact name match.

---

## Out of Scope

The following are not implemented in this version:

- Auto-resolution of tickets when a device comes back online
- Built-in scheduling
- UniFi on-premises controller (Network Application) — Cloud API only
- SMS or email alerting outside of Autotask
- Multi-language support
