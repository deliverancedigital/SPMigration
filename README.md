# SharePoint Migration Tool (SPMT)

## Secure Credential Storage, Scheduled Runs, and Monitoring

This README documents the **approved, supportable way** to run SPMT migrations on a schedule using:

* A **cloud-only Entra ID service account**
* **Encrypted credential storage** (DPAPI via `Export-Clixml`)
* A **hardened PowerShell runner** with exit codes and monitoring
* **Windows Task Scheduler** for unattended incremental syncs

This approach follows Microsoft best practices and avoids insecure patterns (plaintext passwords, bi-directional sync, OneDrive hacks).

---

## Contents

1. Overview & Assumptions
2. Prerequisites
3. Create the Entra ID Service Account
4. Conditional Access (Required for Unattended Runs)
5. Secure Credential Storage (DPAPI)
6. Script Layout
7. Running the Script Manually
8. Scheduling with Task Scheduler
9. Exit Codes & Monitoring
10. Operations Notes & Gotchas
11. Decommissioning

---

## 1. Overview & Assumptions

**Scenario**

* Source: Windows file share (SMB)
* Target: **One SharePoint Online site + one document library**
* Tooling: **SharePoint Migration Tool (SPMT)** via **PowerShell cmdlets**
* Permissions: **Not migrated**; rebuilt natively in SharePoint
* Overlap: **One-way incremental sync** (file share → SharePoint)

**Key design choices**

* SPMT does *not* support app-only auth → use a service account
* Credentials must be stored **encrypted** and **non-interactively**
* Incremental behavior comes from **re-running the same migration task**

---

## 2. Prerequisites

### On the migration server

* Windows Server or Windows 10/11 (supported by SPMT)
* PowerShell 5.1
* SharePoint Migration Tool installed
* Network access to:

  * Source file share
  * Microsoft 365 / SharePoint Online

### PowerShell module

Verify the SPMT module is available:

```powershell
Import-Module Microsoft.SharePoint.MigrationTool.PowerShell
Get-Command -Module Microsoft.SharePoint.MigrationTool.PowerShell
```

---

## 3. Create the Entra ID Service Account

Create a **cloud-only** account in Entra ID:

Example:

```
spmt-migration@tenant.onmicrosoft.com
```

Assign:

* **Temporary** Site Collection Admin on the target site
* (Optional) M365 license if tenant policy requires it

**Do not** use a human admin account.

---

## 4. Conditional Access (Required)

SPMT PowerShell requires user credentials. For unattended runs:

Create a **targeted Conditional Access policy**:

* **Users**: the SPMT service account only
* **Cloud apps**: SharePoint Online
* **Conditions**:

  * Trusted IP(s) **or** specific migration VM
* **Grant**:

  * Allow access
  * **Exclude MFA** for this policy

> Do not disable MFA tenant-wide. Scope it narrowly.

---

## 5. Secure Credential Storage (DPAPI)

Credentials are stored **encrypted** using Windows DPAPI.

### Important rules

* Must be created **on the migration server**
* Must be created **by the same Windows account** that runs the scheduled task
* The file **cannot be decrypted elsewhere**

### Create the credential file (one-time)

Run PowerShell **as the scheduled-task user**:

```powershell
$cred = Get-Credential
$cred | Export-Clixml "C:\SPMT\spmt-cred.xml"
```

This file:

* Contains **no plaintext password**
* Is safe to leave on disk on that server

---

## 6. Script Layout

Recommended directory structure:

```
C:\SPMT\
│
├── Run-Spmt.ps1        # Hardened runner script
├── spmt-cred.xml       # Encrypted credential (DPAPI)
├── spmt.lock           # Created at runtime
└── Logs\               # JSON, text, transcript logs
```

The runner script:

* Performs preflight checks
* Loads encrypted credentials
* Registers the SPMT session
* Adds/reuses the migration task
* Starts migration
* Emits **deterministic exit codes**

---

## 7. Running the Script Manually (Validation)

Before scheduling, run once interactively to validate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SPMT\Run-Spmt.ps1 `
  -SourcePath "\\FS01\Share" `
  -SiteUrl "https://tenant.sharepoint.com/sites/Site" `
  -TargetList "Documents" `
  -TargetSubfolder "Migrated" `
  -CredPath "C:\SPMT\spmt-cred.xml" `
  -WorkDir "C:\SPMT" `
  -WriteEventLog
```

Confirm:

* Files appear in SharePoint
* Logs are written
* Exit code is `0`

---

## 8. Scheduling with Task Scheduler

### Task settings

* **Run whether user is logged on or not**
* **Run with highest privileges**
* **Run as**: the same Windows account used to create `spmt-cred.xml`

### Action

**Program:**

```
powershell.exe
```

**Arguments:**

```powershell
-NoProfile -ExecutionPolicy Bypass -File C:\SPMT\Run-Spmt.ps1 `
  -SourcePath "\\FS01\Share" `
  -SiteUrl "https://tenant.sharepoint.com/sites/Site" `
  -TargetList "Documents" `
  -TargetSubfolder "Migrated" `
  -CredPath "C:\SPMT\spmt-cred.xml" `
  -WorkDir "C:\SPMT" `
  -WriteEventLog
```

### Schedule

* Nightly during overlap (e.g., 2:00 AM)
* Disable once cutover completes

---

## 9. Exit Codes & Monitoring

The script uses **explicit exit codes**:

| Code | Meaning                                          |
| ---- | ------------------------------------------------ |
| 0    | Success                                          |
| 10   | Preflight failure (module, source, cred missing) |
| 20   | Authentication / registration failure            |
| 30   | Task configuration failure                       |
| 40   | Migration execution failure                      |
| 50   | Already running (lock file)                      |
| 99   | Unexpected failure                               |

### Monitoring options

**Task Scheduler**

* Alert on non-zero exit code

**Windows Event Log** (recommended)

* Source: `SPMT-Migration`
* Event ID:

  * `1000` = success
  * `10–99` = categorized failure

**Logs**

* `Logs\spmt-<runId>.jsonl` (machine-readable)
* `Logs\spmt-<runId>.log`
* Transcript for deep debugging

---

## 10. Operations Notes & Gotchas

* Incremental sync = rerunning the same job
* Deletions on the file share are **not removed** from SharePoint
* Do **not** allow users to edit in SharePoint during overlap
* Do **not** attempt bi-directional sync
* File count, not GB, is the primary runtime driver

---

## 11. Decommissioning (Post-Cutover)

After final sync and user validation:

* Disable the scheduled task
* Remove Site Collection Admin from service account
* Rotate or delete the service account
* Archive or remove the file share
* Retain logs for audit if required

---

## Summary

This setup provides:

* Secure, unattended authentication
* Microsoft-supported migration behavior
* Clear monitoring and failure signals
* Minimal security exceptions

It is intentionally conservative and operationally safe for real environments.
