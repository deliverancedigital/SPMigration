#requires -Version 5.1
#requires -Modules Microsoft.SharePoint.MigrationTool.PowerShell

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourcePath,     # \\FS01\Share
  [Parameter(Mandatory=$true)][string]$SiteUrl,        # https://tenant.sharepoint.com/sites/Site
  [Parameter(Mandatory=$true)][string]$TargetList,     # Documents (library display name)
  [string]$TargetSubfolder = "",                       # optional: "Migrated"
  [string]$CredPath = "C:\SPMT\spmt-cred.xml",

  [string]$WorkDir = "C:\SPMT",
  [int]$MaxSeconds = 0,                                # 0 = no timeout; otherwise kill after N seconds

  # Event Log (recommended)
  [switch]$WriteEventLog,
  [string]$EventSource = "SPMT-Migration",
  [string]$EventLogName = "Application"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- Exit codes ----------
$EXIT_OK              = 0
$EXIT_PREFLIGHT_FAIL  = 10
$EXIT_AUTH_FAIL       = 20
$EXIT_TASK_FAIL       = 30
$EXIT_RUN_FAIL        = 40
$EXIT_ALREADY_RUNNING = 50
$EXIT_UNKNOWN_FAIL    = 99

# ---------- Paths ----------
$null = New-Item -ItemType Directory -Force -Path $WorkDir
$logDir   = Join-Path $WorkDir "Logs"
$null = New-Item -ItemType Directory -Force -Path $logDir

$runId = (Get-Date).ToString("yyyyMMdd-HHmmss")
$txtLog = Join-Path $logDir "spmt-$runId.log"
$jsonLog = Join-Path $logDir "spmt-$runId.jsonl"
$transcriptPath = Join-Path $logDir "spmt-$runId.transcript.txt"
$lockPath = Join-Path $WorkDir "spmt.lock"

function Write-JsonLog {
  param(
    [Parameter(Mandatory=$true)][ValidateSet("INFO","WARN","ERROR")][string]$Level,
    [Parameter(Mandatory=$true)][string]$Message,
    [hashtable]$Data
  )

  $obj = [ordered]@{
    ts      = (Get-Date).ToString("s")
    level   = $Level
    msg     = $Message
    runId   = $runId
    source  = $SourcePath
    target  = "$SiteUrl/$TargetList/$TargetSubfolder"
  }
  if ($Data) { $obj.data = $Data }

  ($obj | ConvertTo-Json -Compress) | Out-File -FilePath $jsonLog -Append -Encoding UTF8
  "[$($obj.ts)] [$Level] $Message" | Out-File -FilePath $txtLog -Append -Encoding UTF8
}

function Write-Event {
  param(
    [Parameter(Mandatory=$true)][int]$Id,
    [Parameter(Mandatory=$true)][System.Diagnostics.EventLogEntryType]$Type,
    [Parameter(Mandatory=$true)][string]$Message
  )
  if (-not $WriteEventLog) { return }

  try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
      # Requires admin the first time. If you can't create sources, set up once manually.
      New-EventLog -LogName $EventLogName -Source $EventSource
    }
    Write-EventLog -LogName $EventLogName -Source $EventSource -EventId $Id -EntryType $Type -Message $Message
  } catch {
    # Don't fail the run because event logging isn't configured.
    Write-JsonLog -Level "WARN" -Message "Event log write failed (continuing)" -Data @{ error = $_.Exception.Message }
  }
}

function Fail-AndExit {
  param(
    [Parameter(Mandatory=$true)][int]$Code,
    [Parameter(Mandatory=$true)][string]$Reason,
    [System.Exception]$Exception
  )

  $data = @{}
  if ($Exception) {
    $data.error = $Exception.Message
    $data.type  = $Exception.GetType().FullName
  }

  Write-JsonLog -Level "ERROR" -Message $Reason -Data $data
  Write-Event -Id $Code -Type ([System.Diagnostics.EventLogEntryType]::Error) -Message "$Reason`n$($data.error)"

  try { Stop-Transcript | Out-Null } catch {}
  try { if (Test-Path $lockPath) { Remove-Item -Force $lockPath } } catch {}

  exit $Code
}

# ---------- Lock to prevent overlapping runs ----------
if (Test-Path $lockPath) {
  Write-JsonLog -Level "ERROR" -Message "Lock file exists; previous run still active or crashed" -Data @{ lock = $lockPath }
  Write-Event -Id $EXIT_ALREADY_RUNNING -Type ([System.Diagnostics.EventLogEntryType]::Warning) -Message "SPMT run blocked (lock exists): $lockPath"
  exit $EXIT_ALREADY_RUNNING
}

try {
  "runId=$runId`nts=$((Get-Date).ToString("s"))" | Out-File -FilePath $lockPath -Encoding UTF8 -Force
} catch {
  Fail-AndExit -Code $EXIT_UNKNOWN_FAIL -Reason "Unable to create lock file" -Exception $_.Exception
}

Start-Transcript -Path $transcriptPath -Force | Out-Null
Write-JsonLog -Level "INFO" -Message "SPMT scheduled run starting" -Data @{ workDir = $WorkDir; maxSeconds = $MaxSeconds }

# ---------- Optional timeout watchdog ----------
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
function Check-Timeout {
  if ($MaxSeconds -le 0) { return }
  if ($stopwatch.Elapsed.TotalSeconds -gt $MaxSeconds) {
    Fail-AndExit -Code $EXIT_RUN_FAIL -Reason "Migration exceeded MaxSeconds timeout" -Exception $null
  }
}

try {
  # ---------- Preflight ----------
  Check-Timeout

  if (-not (Test-Path -LiteralPath $CredPath)) {
    throw [System.IO.FileNotFoundException]::new("Credential file not found: $CredPath")
  }

  # Make sure the source is reachable
  if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw [System.IO.IOException]::new("SourcePath not reachable: $SourcePath")
  }

  # Module presence
  Import-Module Microsoft.SharePoint.MigrationTool.PowerShell -ErrorAction Stop

  Write-JsonLog -Level "INFO" -Message "Preflight OK" -Data @{ credPath = $CredPath }

} catch {
  Fail-AndExit -Code $EXIT_PREFLIGHT_FAIL -Reason "Preflight failed" -Exception $_.Exception
}

# ---------- Load creds ----------
$cred = $null
try {
  Check-Timeout
  $cred = Import-Clixml -LiteralPath $CredPath
  if (-not $cred -or -not $cred.UserName) {
    throw [System.Exception]::new("Credential file loaded but is empty/invalid.")
  }
  Write-JsonLog -Level "INFO" -Message "Credential loaded" -Data @{ user = $cred.UserName }
} catch {
  Fail-AndExit -Code $EXIT_AUTH_FAIL -Reason "Failed to load credential" -Exception $_.Exception
}

# ---------- Register migration session ----------
try {
  Check-Timeout
  Register-SPMTMigration -SPOCredential $cred
  Write-JsonLog -Level "INFO" -Message "Register-SPMTMigration OK" -Data @{}
} catch {
  Fail-AndExit -Code $EXIT_AUTH_FAIL -Reason "Register-SPMTMigration failed (auth/tenant/policy)" -Exception $_.Exception
}

# ---------- Add task ----------
try {
  Check-Timeout

  # Add-SPMTTask supports file share source -> SharePoint target. Parameter names can vary by version.
  # If your cmdlet version uses different parameter names, run:
  #   Get-Command Add-SPMTTask -Syntax
  # and adjust accordingly.

  if ([string]::IsNullOrWhiteSpace($TargetSubfolder)) {
    Add-SPMTTask -FileShareSource $SourcePath -TargetSiteUrl $SiteUrl -TargetList $TargetList | Out-Null
  } else {
    Add-SPMTTask -FileShareSource $SourcePath -TargetSiteUrl $SiteUrl -TargetList $TargetList -TargetListRelativePath $TargetSubfolder | Out-Null
  }

  Write-JsonLog -Level "INFO" -Message "Add-SPMTTask OK" -Data @{ targetSubfolder = $TargetSubfolder }
} catch {
  Fail-AndExit -Code $EXIT_TASK_FAIL -Reason "Add-SPMTTask failed" -Exception $_.Exception
}

# ---------- Start migration ----------
try {
  Check-Timeout
  Write-JsonLog -Level "INFO" -Message "Starting migration" -Data @{}

  Start-SPMTMigration

  Write-JsonLog -Level "INFO" -Message "Start-SPMTMigration completed (no exception)" -Data @{}
  Write-Event -Id 1000 -Type ([System.Diagnostics.EventLogEntryType]::Information) -Message "SPMT run completed OK. runId=$runId"

} catch {
  Fail-AndExit -Code $EXIT_RUN_FAIL -Reason "Start-SPMTMigration failed" -Exception $_.Exception
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
  try { if (Test-Path $lockPath) { Remove-Item -Force $lockPath } } catch {}
}

exit $EXIT_OK
