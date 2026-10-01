<#
.SYNOPSIS
    Register Scheduled Tasks for every recurring report script the kit has —
    in one pass, instead of setting each one up by hand.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit other than
    the target scripts it's registering (and it checks each one individually;
    missing ones are skipped with a warning, not a hard failure, so this runs
    fine whether you have 1 of these scripts deployed or all 4).

    Registers, each as its own independent Scheduled Task running as SYSTEM
    (no one needs to be logged in):

      - 07-Reporting-Health\Invoke-HealthCheck.ps1        — daily
      - 01-Users\Get-ADPasswordExpiry.ps1                 — weekly
      - 07-Reporting-Health\Get-CertExpiryReport.ps1      — weekly
      - 12-AD-Health\Test-ADHealth.ps1                    — daily

    Zabbix's toolkit.metrics item is intentionally NOT included here — that
    one is already scheduled by the Zabbix agent's own polling interval
    (see 10-Monitoring-Zabbix), not Task Scheduler, so adding it here would
    just run it twice for no reason.

    Each task is registered with plain defaults (no e-mail/webhook wiring) —
    if you want Invoke-HealthCheck.ps1's task e-mailing a report specifically,
    07-Reporting-Health\Install-HealthCheckTask.ps1 (which this script leaves
    alone if you've already run it — same task name, so re-running either one
    just updates the same task) still does that. This script is for "just get
    everything running on a sane schedule," not per-script customization.

.PARAMETER HealthCheckTime
    Time of day (HH:mm) for the two daily tasks. Default 08:00 / 07:00.
.PARAMETER ADHealthTime
    Time of day (HH:mm) for the two daily tasks. Default 08:00 / 07:00.
.PARAMETER PasswordExpiryDay
    Day of week for the two weekly tasks. Default Monday / Monday.
.PARAMETER CertExpiryDay
    Day of week for the two weekly tasks. Default Monday / Monday.
.PARAMETER PasswordExpiryTime
    Time of day (HH:mm) for the two weekly tasks. Default 08:15 / 08:30.
.PARAMETER CertExpiryTime
    Time of day (HH:mm) for the two weekly tasks. Default 08:15 / 08:30.
.PARAMETER Remove
    Unregister all four tasks (whichever of them exist) and exit.

.EXAMPLE
    .\Install-AllScheduledTasks.ps1 -WhatIf
.EXAMPLE
    .\Install-AllScheduledTasks.ps1
.EXAMPLE
    .\Install-AllScheduledTasks.ps1 -Remove

.NOTES
    Run as Administrator. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^\d{2}:\d{2}$')][string]$HealthCheckTime = '08:00',
    [ValidatePattern('^\d{2}:\d{2}$')][string]$ADHealthTime = '07:00',
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$PasswordExpiryDay = 'Monday',
    [ValidatePattern('^\d{2}:\d{2}$')][string]$PasswordExpiryTime = '08:15',
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$CertExpiryDay = 'Monday',
    [ValidatePattern('^\d{2}:\d{2}$')][string]$CertExpiryTime = '08:30',
    [switch]$Remove
)

# --- Config folder (optional) -------------------------------------------------------
# Values you don't pass on the command line are taken from Config\toolkit-settings.json
# when the kit's Config folder is present. Explicit parameters always win; without a
# Config folder this script behaves exactly as its help describes. (Inline on purpose:
# the script must keep working when copied out of the kit on its own.)
function Get-ToolkitSetting {
    param([string]$Key, [switch]$File)
    if (-not $script:__cfg) {
        $script:__cfg = @{ Loaded = $true; Data = $null; Dir = $null }
        $cands = @()
        if ($env:SYSADMIN_TOOLKIT_CONFIG) { $cands += $env:SYSADMIN_TOOLKIT_CONFIG }
        if ($PSScriptRoot) {
            $parent = Split-Path $PSScriptRoot -Parent
            if ($parent) { $cands += (Join-Path $parent 'Config') }
            $cands += (Join-Path $PSScriptRoot 'Config')
        }
        $cands += 'C:\Sysadmin-Toolkit\Config'
        foreach ($d in $cands) {
            $f = $null
            try { $f = Join-Path $d 'toolkit-settings.json' -ErrorAction Stop } catch { continue }
            if ($f -and (Test-Path -LiteralPath $f -ErrorAction SilentlyContinue)) {
                try { $script:__cfg.Data = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; $script:__cfg.Dir = $d; break }
                catch { Write-Host "  [Config] $f is not valid JSON - ignored ($($_.Exception.Message))" -ForegroundColor Yellow }
            }
        }
    }
    if (-not $script:__cfg.Data) { return $null }
    $node = $script:__cfg.Data
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $part)) { return $null }
        $node = $node.$part
    }
    if ($null -eq $node) { return $null }
    if ($node -is [string]) {
        $node = [Environment]::ExpandEnvironmentVariables($node.Trim())
        if ($node -eq '') { return $null }
        if ($File) {
            if ($node -notmatch '^([A-Za-z]:|\\\\|https?:)') { $node = Join-Path $script:__cfg.Dir $node }
            if (-not (Test-Path -LiteralPath $node)) { return $null }
        }
        return $node
    }
    if ($node -is [System.Array]) { if ($node.Count -eq 0) { return $null }; return @($node) }
    return $node
}
$__cfgUsed = @()
if (-not $PSBoundParameters.ContainsKey('HealthCheckTime')) { $__v = Get-ToolkitSetting 'Schedules.HealthCheckTime'; if ($null -ne $__v) { $HealthCheckTime = $__v; $__cfgUsed += 'Schedules.HealthCheckTime' } }
if (-not $PSBoundParameters.ContainsKey('ADHealthTime')) { $__v = Get-ToolkitSetting 'Schedules.ADHealthTime'; if ($null -ne $__v) { $ADHealthTime = $__v; $__cfgUsed += 'Schedules.ADHealthTime' } }
if (-not $PSBoundParameters.ContainsKey('PasswordExpiryDay')) { $__v = Get-ToolkitSetting 'Schedules.PasswordExpiryDay'; if ($null -ne $__v) { $PasswordExpiryDay = $__v; $__cfgUsed += 'Schedules.PasswordExpiryDay' } }
if (-not $PSBoundParameters.ContainsKey('PasswordExpiryTime')) { $__v = Get-ToolkitSetting 'Schedules.PasswordExpiryTime'; if ($null -ne $__v) { $PasswordExpiryTime = $__v; $__cfgUsed += 'Schedules.PasswordExpiryTime' } }
if (-not $PSBoundParameters.ContainsKey('CertExpiryDay')) { $__v = Get-ToolkitSetting 'Schedules.CertExpiryDay'; if ($null -ne $__v) { $CertExpiryDay = $__v; $__cfgUsed += 'Schedules.CertExpiryDay' } }
if (-not $PSBoundParameters.ContainsKey('CertExpiryTime')) { $__v = Get-ToolkitSetting 'Schedules.CertExpiryTime'; if ($null -ne $__v) { $CertExpiryTime = $__v; $__cfgUsed += 'Schedules.CertExpiryTime' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Test-Admin {
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Install All Scheduled Tasks" -ForegroundColor White
Write-Host "  =================================================" -ForegroundColor DarkGray

if (-not (Test-Admin)) { Write-Log "Needs Administrator rights." 'ERROR'; return }

$jobs = @(
    [pscustomobject]@{ TaskName = 'Sysadmin-Toolkit Health Check';         RelPath = '07-Reporting-Health\Invoke-HealthCheck.ps1';   Trigger = { New-ScheduledTaskTrigger -Daily -At $HealthCheckTime } }
    [pscustomobject]@{ TaskName = 'Sysadmin-Toolkit Password Expiry';      RelPath = '01-Users\Get-ADPasswordExpiry.ps1';            Trigger = { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $PasswordExpiryDay -At $PasswordExpiryTime } }
    [pscustomobject]@{ TaskName = 'Sysadmin-Toolkit Cert Expiry';          RelPath = '07-Reporting-Health\Get-CertExpiryReport.ps1'; Trigger = { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $CertExpiryDay -At $CertExpiryTime } }
    [pscustomobject]@{ TaskName = 'Sysadmin-Toolkit AD Health';            RelPath = '12-AD-Health\Test-ADHealth.ps1';               Trigger = { New-ScheduledTaskTrigger -Daily -At $ADHealthTime } }
)

if ($Remove) {
    foreach ($job in $jobs) {
        if (Get-ScheduledTask -TaskName $job.TaskName -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess($job.TaskName, "Unregister scheduled task")) {
                Unregister-ScheduledTask -TaskName $job.TaskName -Confirm:$false
                Write-Log "Removed '$($job.TaskName)'." 'OK'
            }
        } else { Write-Log "'$($job.TaskName)' not found — nothing to remove." 'INFO' }
    }
    return
}

$registered = 0
$skipped = 0
foreach ($job in $jobs) {
    $script = Join-Path $PSScriptRoot $job.RelPath
    if (-not (Test-Path $script)) {
        Write-Log "$($job.RelPath) not found — skipping '$($job.TaskName)'." 'WARN'
        $skipped++
        continue
    }

    $argLine   = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger   = & $job.Trigger
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    if ($PSCmdlet.ShouldProcess($job.TaskName, "Register scheduled task for $($job.RelPath)")) {
        Register-ScheduledTask -TaskName $job.TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Registered '$($job.TaskName)' -> $($job.RelPath)" 'OK'
        $registered++
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. $registered task(s) registered, $skipped skipped (script not found)." -ForegroundColor Green
    if ($registered) { Write-Host "  List them: Get-ScheduledTask | Where-Object TaskName -like 'Sysadmin-Toolkit*'" -ForegroundColor White }
    Write-Host "  Remove them all: .\Install-AllScheduledTasks.ps1 -Remove" -ForegroundColor White
}
