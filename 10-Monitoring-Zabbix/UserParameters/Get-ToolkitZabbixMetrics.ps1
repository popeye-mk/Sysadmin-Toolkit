<#
.SYNOPSIS
    Emit a compact JSON snapshot of this machine's health, for a Zabbix
    UserParameter to capture as a single item — the bridge between this
    toolkit's health logic and Zabbix/Grafana.

.DESCRIPTION
    Deliberately self-contained (no dependency on _Common or any other section
    — this script gets copied to every monitored endpoint on its own) and
    deliberately quiet: it writes ONE line of JSON to stdout and nothing else,
    because Zabbix's UserParameter captures stdout as the item's raw value —
    any stray Write-Host would corrupt it.

    Called by ONE Zabbix UserParameter (see SysadminToolkit.conf) as the item
    key "toolkit.metrics". Zabbix then uses dependent items with JSONPath
    preprocessing to split the fields back out (see the template XML) — this
    way one PowerShell process launch feeds ~10 Zabbix items instead of ten
    separate launches per poll.

    Every check is wrapped so one failure (missing module, access denied)
    degrades that ONE field to null rather than losing the whole snapshot.
    passwordExpiryCount is null unless the ActiveDirectory module is present
    AND the machine can reach a domain controller — expected on a member
    server/DC, not on a random workstation.

.EXAMPLE
    .\Get-ToolkitZabbixMetrics.ps1
    (run by hand to see the JSON a Zabbix poll would capture)

.NOTES
    No parameters — Zabbix UserParameter calls it with none. Runs fine as the
    Zabbix Agent service account (typically SYSTEM / Local Service) on
    Windows PowerShell 5.1. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

$ErrorActionPreference = 'SilentlyContinue'
$out = [ordered]@{
    timestamp           = (Get-Date).ToString('o')
    hostname            = $env:COMPUTERNAME
    healthScore         = $null
    healthGrade         = $null
    failCount           = $null
    warnCount           = $null
    pendingReboot       = $null
    diskFreePctMin      = $null
    uptimeDays          = $null
    defenderRealTime    = $null
    defenderSigAgeDays  = $null
    bloatwareCount      = $null
    passwordExpiryCount = $null
    toolkitVersion      = $null
    updatesPending      = $null
    updatesSecurity     = $null
    updateScanAgeHours  = $null
    lastPatchDays       = $null
    updatePolicy        = $null
}

# ---- which Sysadmin-Toolkit version is installed here (VERSION at the kit root) ----
# This script lives in <kit>\10-Monitoring-Zabbix\UserParameters\ - the root is two folders up.
try {
    $kitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $vf = Join-Path $kitRoot 'VERSION'
    if (Test-Path $vf) { $out.toolkitVersion = (Get-Content $vf -Raw -ErrorAction Stop).Trim() }
} catch { }

# ---- Windows updates: read the cache written by 22-Windows-Update\Get-UpdateStatus.ps1
#      (a real update scan is far too slow for every poll) ---------------------------
try {
    $uf = Join-Path $kitRoot 'Reports\update-status.json'
    if (Test-Path $uf) {
        $st = Get-Content $uf -Raw -ErrorAction Stop | ConvertFrom-Json
        $waiting = @($st.updates | Where-Object { -not $_.hidden -and -not $_.definition -and -not $_.upgrade })
        $out.updatesPending  = $waiting.Count
        $out.updatesSecurity = @($waiting | Where-Object { $_.security }).Count
        $out.updateScanAgeHours = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$st.scannedAt).ToUniversalTime()).TotalHours, 1)
        if ($st.lastPatchDate) { $out.lastPatchDays = [math]::Round(((Get-Date) - [datetime]$st.lastPatchDate).TotalDays, 0) }
    }
    $out.updatePolicy = 'Default'
    $m = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Sysadmin-Toolkit\WindowsUpdate' -Name Mode -ErrorAction SilentlyContinue
    if ($m -and $m.Mode) { $out.updatePolicy = [string]$m.Mode }
} catch { }

# ---- disk / memory / uptime (always available, no admin needed) -------------
try {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object Size)
    if ($disks.Count) {
        $pcts = $disks | ForEach-Object { [math]::Round($_.FreeSpace / $_.Size * 100, 0) }
        $out.diskFreePctMin = ($pcts | Measure-Object -Minimum).Minimum
    }
} catch { }

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $out.uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
} catch { }

# ---- pending reboot -----------------------------------------------------------
try {
    $pending = $false
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $out.pendingReboot = if ($pending) { 1 } else { 0 }
} catch { }

# ---- defender -------------------------------------------------------------------
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $out.defenderRealTime   = if ($mp.RealTimeProtectionEnabled) { 1 } else { 0 }
    $out.defenderSigAgeDays = [int]$mp.AntivirusSignatureAge
} catch { }

# ---- bloatware count (small, fast subset — not the full curated list) ---------
try {
    $quickList = @('Microsoft.XboxApp','Microsoft.BingNews','Microsoft.MicrosoftSolitaireCollection','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.BingWeather','king.com.*','Spotify*')
    $installed = Get-AppxPackage -ErrorAction Stop
    $count = 0
    foreach ($pat in $quickList) { $count += @($installed | Where-Object { $_.Name -like $pat }).Count }
    $out.bloatwareCount = $count
} catch { }

# ---- lightweight health score (mirrors 07-Reporting-Health\Invoke-HealthCheck.ps1
#      at a smaller scope — this stays fast since it runs on every poll) --------
try {
    $fail = 0; $warn = 0
    if ($null -ne $out.diskFreePctMin) {
        if ($out.diskFreePctMin -lt 8) { $fail++ } elseif ($out.diskFreePctMin -lt 15) { $warn++ }
    }
    if ($null -ne $out.uptimeDays -and $out.uptimeDays -gt 30) { $warn++ }
    if ($out.pendingReboot -eq 1) { $warn++ }
    if ($out.defenderRealTime -eq 0) { $fail++ } elseif ($null -ne $out.defenderSigAgeDays -and $out.defenderSigAgeDays -gt 3) { $warn++ }
    foreach ($svc in @('Dnscache','LanmanServer','LanmanWorkstation','W32Time')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') { $fail++ }
    }
    $out.failCount   = $fail
    $out.warnCount   = $warn
    $out.healthScore = [math]::Max(0, 100 - ($fail * 15) - ($warn * 5))
    $out.healthGrade = if ($out.healthScore -ge 90) { 'Healthy' } elseif ($out.healthScore -ge 70) { 'Attention' } else { 'ActionNeeded' }
} catch { }

# ---- AD password-expiry count (only where RSAT + a reachable DC exist) --------
try {
    if (Get-Module -ListAvailable ActiveDirectory -ErrorAction Stop) {
        Import-Module ActiveDirectory -ErrorAction Stop
        $maxAge = (Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop).MaxPasswordAge
        if ($maxAge -and $maxAge.TotalDays -gt 0) {
            $users = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $false } -Properties 'msDS-UserPasswordExpiryTimeComputed' -ErrorAction Stop
            $now = Get-Date
            $count = 0
            foreach ($u in $users) {
                $exp = $u.'msDS-UserPasswordExpiryTimeComputed'
                if ($exp -and $exp -ne 0) {
                    $days = ([datetime]::FromFileTime([int64]$exp) - $now).TotalDays
                    if ($days -le 14) { $count++ }
                }
            }
            $out.passwordExpiryCount = $count
        }
    }
} catch { }

# ---- emit — single line, JSON only, nothing else on stdout --------------------
$out | ConvertTo-Json -Compress
