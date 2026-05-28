# UniFi → AutoTask Alert Bridge

A PowerShell script that runs as a **Datto RMM Component Job**. It polls a UniFi Cloud Controller for active alerts, identifies the matching AutoTask company by parsing the account number prefix from the site name, looks up the primary contact, and creates a structured service ticket — automatically, every 15 minutes.

---

## How it works

```
Datto RMM Scheduler (every 15 min)
        │
        ▼
Invoke-UniFiAlerts.ps1
        │
        ├─ GET  /api/self/sites                    list all sites (API key auth)
        ├─ GET  /api/s/{site_id}/stat/alarm        fetch unarchived alerts
        │
        ├─ Parse account prefix from site name
        │       "AFF001_A1 Taxis"  →  "AFF001"
        │
        ├─ POST /v1.0/Companies/query              find company in AutoTask
        ├─ POST /v1.0/Contacts/query               get primary contact
        ├─ POST /v1.0/Tickets                      create ticket
        │
        └─ JSON dedup log                          prevent duplicate tickets
```

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Datto RMM | Account with Component Editor access |
| UniFi Network Application | Version **8.1 or later** (for API key support) |
| UniFi API key | Generated in the controller UI — no 2FA required |
| AutoTask API user | Integration user with permission to read companies/contacts and create tickets |
| Persistent folder | e.g. `C:\ProgramData\DattoRMM\UniFiAlerts\` on the target device |

> **One controller, all sites.** Because all UniFi sites are managed from a single cloud controller, all configuration is set as **Job Variables** on the one scheduled job — not per-site. You only configure this once.

---

## Setup

### 1 — Generate a UniFi API key

API keys bypass 2FA and do not expire with password changes.

1. Go to **account.ui.com**
2. Click your profile (top-right) → **API Keys**
3. Click **Generate API Key**
4. Give it a descriptive name (e.g. `Datto RMM Alert Bridge`)
5. Copy the key — you will not be able to see it again

The key needs read access to sites and network alarms. The script uses the official UniFi Cloud API at `api.ui.com` — no direct access to individual console IPs is required.

---

### 2 — Create the Component in Datto RMM

1. Go to **Components → New Component**
2. Name: `UniFi Alert to AutoTask Ticket`
3. Category: `Monitoring`
4. Platform: `Windows`
5. Component Type: `PowerShell`
6. Paste the full contents of `Invoke-UniFiAlerts.ps1` into the script editor
7. **Save** the component

---

### 3 — Create the Scheduled Job

1. Go to **Jobs → New Job**
2. Job Type: `Component Job`
3. Name: `UniFi Alert Polling`
4. Component: `UniFi Alert to AutoTask Ticket`
5. Target: always-on device that can reach the UniFi controller (Windows Server, NUC, or any device with the Datto RMM agent)
6. Schedule: **Recurring — every 15 minutes**

---

### 4 — Set Job Variables

All configuration lives on the job itself. In the job editor, go to the **Variables** tab and add each entry below.

> **Security note:** Mark the `UNIFI_API_KEY` and `AT_API_KEY` fields as the **Password** type so they are encrypted at rest and masked in job logs.

| Variable | Example value | Notes |
|---|---|---|
| `UNIFI_BASE_URL` | `https://api.ui.com` | UniFi Cloud API base URL — do not change unless self-hosting. |
| `UNIFI_API_KEY` | `••••••••` | **Mark as password.** Generated in step 1 at account.ui.com. |
| `UNIFI_SITE_FILTER` | *(leave blank)* | Optional — comma-separated site display names to restrict polling. Blank = all sites. |
| `AT_BASE_URL` | `https://webservices2.autotask.net/ATServicesRest` | Check your zone — see note below. |
| `AT_INTEGRATION_CODE` | `DattoRMM-UniFiAlertBridge` | Unique identifier for this integration — Admin → Resources / Users (HR) → API Tracking Identifier |
| `AT_USERNAME` | `api-integration@yourdomain.com` | AutoTask API user email |
| `AT_API_KEY` | `••••••••` | **Mark as password.** AutoTask API key — Admin → Resources / Users (HR) → [API User] → API Access |
| `AT_QUEUE_ID` | `29682933` | Admin → Service Desk → Queues |
| `AT_SOURCE_ID` | `4` | Admin → Service Desk → Ticket Sources |
| `AT_PRIORITY_ID` | `1` | Admin → Service Desk → Priority |
| `AT_CLOSED_STATUS_ID` | `5` | **Optional.** Enables two-way sync — see section below. Admin → Service Desk → Ticket Statuses. |
| `ALERT_MAX_AGE_HOURS` | `24` | **Optional.** Alerts older than this many hours are skipped. Prevents a backlog of stale alerts creating tickets on first run. Default: 24. |
| `DEDUP_LOG_PATH` | `C:\ProgramData\DattoRMM\UniFiAlerts\dedup.json` | Must be a persistent path; folder is created automatically |

> **AutoTask zone:** your zone appears in the AutoTask URL — `webservices1`, `webservices2`, etc. Using the wrong zone causes silent API failures.

> **Account number field:** By default the script searches AutoTask's `AccountNumber` field for the site prefix (e.g. `AFF001`). If your instance stores this in a User Defined Field instead, update the filter in `Find-AutoTaskCompany` inside `#region AUTOTASK-LOOKUP`.

**Save and enable the job.**

---

### 5 — Verify the first run

| Check | Where |
|---|---|
| Job exit code 0 | Jobs → Job History |
| Log output | Click the job result → view stdout |
| Ticket created | AutoTask → company ticket queue |
| Dedup log created | RDP to target → confirm `dedup.json` at `DEDUP_LOG_PATH` |
| No duplicates on second run | Wait for next scheduled run |

---

## Two-way sync — closing tickets archives alerts

When `AT_CLOSED_STATUS_ID` is set, each polling run checks every open dedup log entry against AutoTask before processing new alerts. If the ticket has reached the configured closed status, the corresponding UniFi alert is archived via the controller API so it disappears from future polls.

### How it works

```
Each polling run (before new-alert processing):
  for each entry in dedup.json:
    GET /v1.0/Tickets/{id}          check ticket status in AutoTask
    if status == AT_CLOSED_STATUS_ID:
      POST /api/s/{siteId}/cmd/evtmgr  archive the alert in UniFi
      remove entry from dedup.json
```

The dedup log stores the UniFi site ID alongside every ticket ID so the archive call can be made without re-fetching site data.

### Enabling it

Add `AT_CLOSED_STATUS_ID` as a Job Variable (see the variables table above). Set it to the numeric ID of your "Complete" or equivalent status.

To find the right ID: Admin → Service Desk → Ticket Statuses. The most common value is `5` (Complete), but this varies per AutoTask instance.

### Behaviour table

| Scenario | What happens |
|---|---|
| Ticket closed, alert still in UniFi | Alert archived; dedup entry removed |
| Ticket closed, alert already manually archived | Archive call treated as success; dedup entry removed |
| Ticket closed, alert not found in UniFi (404) | Treated as already archived; dedup entry removed |
| Archive call fails (network/controller error) | Warning logged; dedup entry kept; retried next run |
| Ticket deleted from AutoTask (404) | Warning logged; dedup entry removed without archiving |
| Ticket still open | No action; checked again next run |
| Entry from before this update (no siteId stored) | Ticket closure noted; dedup entry removed; manual archive note logged |
| `AT_CLOSED_STATUS_ID` not set | Sync step skipped entirely |

> **Note on latency:** the sync runs every 15 minutes (or whatever your job schedule is). Closing a ticket in AutoTask won't archive the UniFi alert instantly — it will be picked up on the next scheduled run.

> **Archiving vs resolving:** archiving a UniFi alert removes it from the active alerts view in the controller. It does not delete it — it moves to the alert history. This is the same action a technician would take manually when the issue is resolved.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed successfully (some alerts may have been skipped — see stdout) |
| `1` | Fatal startup failure — missing variable, or API key rejected |

---

## Test mode

Run this **before enabling the live scheduler** to verify connectivity and inspect the raw alert payload without creating any AutoTask tickets.

### In Datto RMM

Create a one-off Component Job run using the same component. In the **Script Arguments** field add:

```
# Dump first alert from any site
-TestMode

# Dump first alert from a specific site
-TestMode -TestSite "AFF001_A1 Taxis"
```

The full alert JSON appears in the job stdout log:

```
=== TEST MODE - RAW UNIFI ALERT (no ticket created) ===

{
  "_id": "64a1f3c2b5e4d20001a3f812",
  "key": "EVT_AP_Disconnected",
  "datetime": "2024-01-15T09:23:41Z",
  "site_name": "AFF001_A1 Taxis",
  "ap": "aa:bb:cc:dd:ee:ff",
  "ap_name": "AP-Reception",
  ...
}

Account prefix parsed: AFF001
```

Use this to confirm:
- `site_name` contains the expected `PREFIX_Description` format
- Field names match what the script expects (`ap_name`, `sw_name`, etc.)
- The account prefix extracts correctly before any tickets are created

---

## Ticket format

### Title

```
[UniFi] AP Disconnected – AP-Reception (AFF001 / A1 Taxis)
```

Plain English alert type — no raw event codes in the title.

### Description sections

| Section | Content |
|---|---|
| **ALERT SUMMARY** | Client, site, device, MAC, alert type, subsystem, UTC & local time |
| **WHAT HAPPENED** | Plain English mapped from the UniFi event code |
| **NEXT STEPS** | Numbered action list including remote reboot via UniFi Cloud Controller with primary contact scheduling language |
| **PRIMARY CONTACT** | Name, phone, email from AutoTask — or a note to assign manually |
| **RAW ALERT DATA** | Alert ID, raw event code, full JSON for reference |

---

## Alert code mapping

The script maps UniFi event key codes to plain English. The full map is in `#region ALERT-MAP`. Codes not in the map fall back to `Unknown event: {raw code}`.

| Event code | Plain English |
|---|---|
| `EVT_AP_Disconnected` | Access point disconnected from the UniFi controller |
| `EVT_AP_Connected` | Access point reconnected to the UniFi controller |
| `EVT_AP_Restarted` | Access point restarted |
| `EVT_SW_Disconnected` | Network switch disconnected from the UniFi controller |
| `EVT_SW_Connected` | Network switch reconnected to the UniFi controller |
| `EVT_GW_Disconnected` | Gateway / router disconnected from the UniFi controller |
| `EVT_GW_Connected` | Gateway / router reconnected to the UniFi controller |
| `EVT_GW_WANTransitioned` | WAN connection changed state (failover or recovery) |
| `EVT_GW_VPNDown` | VPN tunnel went down |
| `EVT_GW_VPNUp` | VPN tunnel came back up |
| `EVT_LTE_Disconnected` | LTE failover link disconnected |
| `EVT_LTE_Connected` | LTE failover link reconnected |
| `EVT_CLIENT_Roam` | Wireless client roamed between access points |
| `EVT_CLIENT_Blocked` | Wireless client was blocked |

To add a new code, add an entry to `$Script:AlertMap` and `$titleMap` inside `#region ALERT-MAP`.

---

## Edge cases

| Scenario | Behaviour |
|---|---|
| API key rejected | Exit 1 — clear error in stdout |
| Site name has no underscore | Warning logged, site skipped |
| Account prefix not found in AutoTask | Warning logged, alert skipped — no orphan ticket |
| AutoTask 429 rate limit | Exponential backoff, up to 3 retries |
| Alert older than `ALERT_MAX_AGE_HOURS` | Skipped silently (count logged per site) |
| Alert already in dedup log | Skipped silently |
| Dedup log missing or corrupt | Recreated empty, processing continues |
| Alert has no device name | MAC address used as fallback in ticket title |
| No primary contact in AutoTask | `ContactID` omitted from ticket; manual assignment note in description |
| Unknown UniFi event code | Fallback description `Unknown event: {raw code}` in WHAT HAPPENED |
| Ticket creation fails | Error logged with response body; dedup entry NOT written (retries next run) |
| AT_CLOSED_STATUS_ID not set | Sync step skipped; alerts remain unarchived until manually cleared |
| AutoTask ticket status check fails | Warning logged; entry kept in dedup log; retried next run |
| UniFi archive call fails | Warning logged; entry kept in dedup log; retried next run |
| Ticket deleted from AutoTask | Warning logged; dedup entry removed; alert not archived in UniFi |

---

## Running the Pester tests

Requires [Pester 5](https://pester.dev/docs/introduction/installation):

```powershell
Install-Module Pester -Force -SkipPublisherCheck
Import-Module Pester

# Run all tests
Invoke-Pester ./Tests/ -Output Detailed

# Run individual test files
Invoke-Pester ./Tests/AccountParse.Tests.ps1   -Output Detailed
Invoke-Pester ./Tests/AlertMap.Tests.ps1       -Output Detailed
Invoke-Pester ./Tests/DedupLog.Tests.ps1       -Output Detailed
Invoke-Pester ./Tests/TicketBody.Tests.ps1     -Output Detailed
Invoke-Pester ./Tests/PrimaryContact.Tests.ps1 -Output Detailed
```

---

## File structure

```
UnifiAutoTaskAlertBridge/
├── Invoke-UniFiAlerts.ps1      Main script — paste into Datto RMM component
├── .env.sample                 Environment variable reference (copy → .env for local testing)
├── README.md                   This file
└── Tests/
    ├── AccountParse.Tests.ps1  Get-AccountPrefix edge cases
    ├── AlertMap.Tests.ps1      Event code → plain English mapping
    ├── DedupLog.Tests.ps1      Dedup log read/write/purge
    ├── TicketBody.Tests.ps1    Ticket title/description formatting
    └── PrimaryContact.Tests.ps1 Primary contact lookup and null handling
```

---

## Future extensions (out of scope for v1)

- **Severity mapping** — map UniFi alert subsystem values to AutoTask priority IDs dynamically
- **Alert archiving** — archive the UniFi alert after successful ticket creation
- **Two-way sync** — ✅ implemented (see `AT_CLOSED_STATUS_ID`)
- **Teams webhook** — post newly created ticket summaries to a Microsoft Teams channel
- **Email fallback** — if company not found in AutoTask, email the alert to a catch-all queue
- **Config file mode** — replace env vars with a JSON config for non-Datto deployments
