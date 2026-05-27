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
        ├─ POST /api/login                         UniFi auth (cookie-based)
        ├─ GET  /api/self/sites                    list all sites
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
| UniFi Cloud Controller | Reachable from the target device's network |
| AutoTask API user | Integration user with permission to read companies/contacts and create tickets |
| Persistent folder | e.g. `C:\ProgramData\DattoRMM\UniFiAlerts\` on the target device |

---

## Quick start

### 1 — Create the Component in Datto RMM

1. Go to **Components → New Component**
2. Name: `UniFi Alert to AutoTask Ticket`
3. Category: `Monitoring`
4. Platform: `Windows`
5. Component Type: `PowerShell`
6. Paste the full contents of `Invoke-UniFiAlerts.ps1` into the script editor
7. **Save** the component

### 2 — Set Site Variables

Navigate to **Sites → [Your Site] → Variables** and add each variable below.

> **Security note:** Datto RMM Site Variables are encrypted at rest. Mark password/secret fields as the **Password** type in Datto RMM so they are masked in logs and the UI.

| Variable | Example value | Notes |
|---|---|---|
| `UNIFI_BASE_URL` | `https://192.168.1.1:8443` | No trailing slash. For UniFi OS (UDM/Pro) omit the port. |
| `UNIFI_USERNAME` | `admin` | Cloud Controller local admin username |
| `UNIFI_PASSWORD` | `••••••••` | **Mark as password** |
| `UNIFI_SITE_FILTER` | *(leave blank)* | Optional comma-separated site names to restrict polling. Blank = all sites. |
| `AT_BASE_URL` | `https://webservices2.autotask.net/ATServicesRest` | Check your zone — log in to AutoTask and look at the URL |
| `AT_USERNAME` | `api-integration@yourdomain.com` | AutoTask API integration user email |
| `AT_SECRET` | `••••••••` | **Mark as password** |
| `AT_QUEUE_ID` | `29682933` | Admin → Service Desk → Queues |
| `AT_SOURCE_ID` | `4` | Admin → Service Desk → Ticket Sources |
| `AT_PRIORITY_ID` | `1` | Admin → Service Desk → Priority |
| `DEDUP_LOG_PATH` | `C:\ProgramData\DattoRMM\UniFiAlerts\dedup.json` | Must be a persistent path; folder is created automatically |

> **AutoTask zone:** your zone appears in the AutoTask URL — `webservices1`, `webservices2`, etc. Using the wrong zone causes silent API failures.

> **Account number field:** By default the script searches AutoTask's `AccountNumber` field for the site prefix. If your instance stores this in a User Defined Field, update the filter in `Find-AutoTaskCompany` inside `#region AUTOTASK-LOOKUP`.

### 3 — Create the Scheduled Job

1. Go to **Jobs → New Job**
2. Job Type: `Component Job`
3. Name: `UniFi Alert Polling – [Site Name]`
4. Component: `UniFi Alert to AutoTask Ticket`
5. Target: always-on device at the site (Windows Server, NUC, or any device with the Datto RMM agent that can reach the UniFi controller)
6. Schedule: **Recurring — every 15 minutes**
7. Enable and save

### 4 — Verify the first run

| Check | Where |
|---|---|
| Job exit code 0 | Jobs → Job History |
| Log output | Click the job result → view stdout |
| Ticket created | AutoTask → company ticket queue |
| Dedup log created | RDP to target → confirm `dedup.json` at `DEDUP_LOG_PATH` |
| No duplicates on second run | Wait for next scheduled run |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed successfully (some alerts may have been skipped — see stdout) |
| `1` | Fatal startup failure — missing env var or UniFi auth failed |

---

## Test mode

Run this before the live scheduler to verify connectivity and inspect the raw alert payload without creating any AutoTask tickets.

### In Datto RMM

Create a one-off Component Job using the same component, then add script arguments in the job editor:

```
# Dump first alert from any site
-TestMode

# Dump first alert from a specific site
-TestMode -TestSite "AFF001_A1 Taxis"
```

The full alert JSON will appear in the job stdout log:

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
- The account prefix extracts correctly

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

## Multi-site rollout

Repeat the **Site Variables** step for each client site (each will have a different `UNIFI_BASE_URL`, username, and password), then create a separate scheduled job targeting an always-on device at each site. The script itself is identical across all sites.

**Tip:** If `AT_BASE_URL`, `AT_USERNAME`, `AT_SECRET`, `AT_QUEUE_ID`, `AT_SOURCE_ID`, and `AT_PRIORITY_ID` are the same across all sites, set them at the **Account** level in Datto RMM rather than per-site. Only the UniFi variables need to vary.

---

## Edge cases

| Scenario | Behaviour |
|---|---|
| UniFi login fails | Exit 1 — clear error in stdout |
| Site name has no underscore | Warning logged, site skipped |
| Account prefix not found in AutoTask | Warning logged, alert skipped — no orphan ticket |
| AutoTask 429 rate limit | Exponential backoff, up to 3 retries |
| Alert already in dedup log | Skipped silently |
| Dedup log missing or corrupt | Recreated empty, processing continues |
| Alert has no device name | MAC address used as fallback in ticket title |
| No primary contact in AutoTask | `ContactID` omitted from ticket; manual assignment note in description |
| Unknown UniFi event code | Fallback description `Unknown event: {raw code}` in WHAT HAPPENED |
| Ticket creation fails | Error logged with response body; dedup entry NOT written (retries next run) |

---

## Running the Pester tests

Requires [Pester 5](https://pester.dev/docs/introduction/installation):

```powershell
Install-Module Pester -Force -SkipPublisherCheck
Import-Module Pester

# Run all tests
Invoke-Pester ./Tests/ -Output Detailed

# Run individual test files
Invoke-Pester ./Tests/AccountParse.Tests.ps1  -Output Detailed
Invoke-Pester ./Tests/AlertMap.Tests.ps1      -Output Detailed
Invoke-Pester ./Tests/DedupLog.Tests.ps1      -Output Detailed
Invoke-Pester ./Tests/TicketBody.Tests.ps1    -Output Detailed
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
- **Two-way sync** — check resolved AutoTask tickets and archive the corresponding UniFi alert
- **Teams webhook** — post newly created ticket summaries to a Microsoft Teams channel
- **Email fallback** — if company not found in AutoTask, email the alert to a catch-all queue
- **Config file mode** — replace env vars with a JSON config for non-Datto deployments
