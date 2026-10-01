<#
.SYNOPSIS
    Register (or remove) a Scheduled Task that runs the daily health check
    automatically as SYSTEM.

.DESCRIPTION
    Creates a task 'Sysadmin-Toolkit Health Check' that runs
    Invoke-HealthCheck.ps1 every day at the time you choose, under the SYSTEM
    account (so it doesn't need anyone logged in) with the highest privileges.
    Any -EmailTo / -SmtpServer you pass here are baked into the task's argument
    list so the report is mailed on each run.

    -Remove deletes the task.

.PARAMETER At
    Time of day to run, 'HH:mm' (default '08:00').
.PARAMETER EmailTo
    Passed straight through to the health-check script for e-mailed reports.
.PARAMETER EmailFrom
    Passed straight through to the health-check script for e-mailed reports.
.PARAMETER SmtpServer
    Passed straight through to the health-check script for e-mailed reports.
.PARAMETER SmtpPort
    Passed straight through to the health-check script for e-mailed reports.
.PARAMETER Remove
    Delete the scheduled task and exit.

.EXAMPLE
    .\Install-HealthCheckTask.ps1 -At 07:30 -WhatIf
.EXAMPLE
    .\Install-HealthCheckTask.ps1 -At 08:00 -EmailTo it@firm.be -SmtpServer smtp.firm.be
.EXAMPLE
    .\Install-HealthCheckTask.ps1 -Remove

.NOTES
    Run as Administrator. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^\d{2}:\d{2}$')][string]$At = '08:00',
    [string]$EmailTo,
    [string]$EmailFrom,
    [string]$SmtpServer,
    [int]$SmtpPort = 25,
    [switch]$Remove,
    [switch]$Force
)

$script:__ntForce = $false
if ($Force -or $env:SYSADMIN_TOOLKIT_FORCE -eq '1') { $ConfirmPreference = 'None'; $script:__ntForce = $true }

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
if (-not $PSBoundParameters.ContainsKey('EmailTo')) { $__v = Get-ToolkitSetting 'Alerting.EmailTo'; if ($null -ne $__v) { $EmailTo = $__v; $__cfgUsed += 'Alerting.EmailTo' } }
if (-not $PSBoundParameters.ContainsKey('EmailFrom')) { $__v = Get-ToolkitSetting 'Alerting.EmailFrom'; if ($null -ne $__v) { $EmailFrom = $__v; $__cfgUsed += 'Alerting.EmailFrom' } }
if (-not $PSBoundParameters.ContainsKey('SmtpServer')) { $__v = Get-ToolkitSetting 'Alerting.SmtpServer'; if ($null -ne $__v) { $SmtpServer = $__v; $__cfgUsed += 'Alerting.SmtpServer' } }
if (-not $PSBoundParameters.ContainsKey('SmtpPort')) { $__v = Get-ToolkitSetting 'Alerting.SmtpPort'; if ($null -ne $__v) { $SmtpPort = $__v; $__cfgUsed += 'Alerting.SmtpPort' } }
if (-not $PSBoundParameters.ContainsKey('At')) { $__v = Get-ToolkitSetting 'Schedules.HealthCheckTime'; if ($null -ne $__v) { $At = $__v; $__cfgUsed += 'Schedules.HealthCheckTime' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- toolkit helpers (standalone-safe) -------------------------------------
# Uses the shared _Common module when run inside the kit. If this script is
# copied out on its own, it self-provides the same helpers so it still runs.
$__common = Join-Path $PSScriptRoot '..\_Common\SysadminToolkit.Common.psm1'
if (Test-Path $__common) {
    Import-Module $__common -Force
} else {
    function Get-ToolkitRoot { param([string]$Path = 'C:\Sysadmin-Toolkit')
        try { foreach ($s in @('','Reports','Backups','Logs')) { $p = if ($s) { Join-Path $Path $s } else { $Path }; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } } } catch { }
        return $Path }
    function Write-Log { param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
        $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
        Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
        try { $lf = Join-Path (Get-ToolkitRoot) ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')); Add-Content -Path $lf -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { } }
    function Write-Banner { param([Parameter(Mandatory)][string]$Title) Write-Host ''; Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White; Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray }
    function Test-Admin { try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } }
    function Assert-Admin { if (Test-Admin) { return $true } Write-Log 'This tool needs Administrator rights. Right-click PowerShell and Run as administrator.' 'ERROR'; return $false }
    function Confirm-Action { param([Parameter(Mandatory)][string]$Question) if ($script:__ntForce) { return $true } if (-not [Environment]::UserInteractive -or $null -eq $Host.UI.RawUI) { return $false } (Read-Host "$Question [y/N]") -match '^(y|yes)$' }
    function New-StrongPassword { param([int]$Length=16)
        $U='ABCDEFGHJKLMNPQRSTUVWXYZ'; $L='abcdefghijkmnpqrstuvwxyz'; $D='23456789'; $S='!@#$%^&*-_=+?'; $all=($U+$L+$D+$S).ToCharArray()
        $ch=@($U[(Get-Random -Maximum $U.Length)],$L[(Get-Random -Maximum $L.Length)],$D[(Get-Random -Maximum $D.Length)],$S[(Get-Random -Maximum $S.Length)])
        for ($i=$ch.Count; $i -lt $Length; $i++){ $ch += $all[(Get-Random -Maximum $all.Length)] }
        -join ($ch | Sort-Object { Get-Random }) }
    function Get-OSInfo { $o=Get-CimInstance Win32_OperatingSystem; $b=[int]$o.BuildNumber
        $t = if ($o.Caption -match 'Server') { 'Server' } elseif ($b -ge 22000) { 'Win11' } elseif ($b -ge 10240) { 'Win10' } else { 'Older' }
        [pscustomobject]@{ Caption=$o.Caption; Version=$o.Version; Build=$b; Tag=$t } }
    function Backup-RegistryKey { param([Parameter(Mandatory)][string]$Path,[string]$Label='key')
        $tag=(($Path -split '\\' | Select-Object -Last 2) -join '_') -replace '[^\w\-]','_'; $o=Join-Path (Get-ToolkitRoot) ("Backups\{0}_{1}_{2}.reg" -f ($Label -replace '[^\w\-]','_'),$tag,(Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        if (-not (Test-Path -LiteralPath "Registry::$Path")) { return $null }
        $rc = (Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $Path), ('"{0}"' -f $o), '/y') -Wait -PassThru -WindowStyle Hidden).ExitCode; if ($rc -eq 0) { Write-Log "Backed up $Path -> $o" 'OK'; return $o }; return $null }
    function Set-RegValue { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Value,[ValidateSet('DWord','String','ExpandString','QWord','Binary')][string]$Type='DWord')
        if ($PSCmdlet.ShouldProcess("$Path\$Name","Set to $Value ($Type)")) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null; Write-Log "Set $Path\$Name = $Value" 'OK' } }
}
# ---------------------------------------------------------------------------
Write-Banner "Install Health Check Task"
if (-not (Assert-Admin)) { return }

$taskName = 'Sysadmin-Toolkit Health Check'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($taskName, "Unregister scheduled task")) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Log "Removed task '$taskName'." 'OK'
        }
    } else { Write-Log "Task '$taskName' not found." 'INFO' }
    return
}

$script = Join-Path $PSScriptRoot 'Invoke-HealthCheck.ps1'
if (-not (Test-Path $script)) { Write-Log "Can't find Invoke-HealthCheck.ps1 next to this script." 'ERROR'; return }

# build the argument list
$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
if ($EmailTo)    { $argLine += " -EmailTo `"$EmailTo`"" }
if ($EmailFrom)  { $argLine += " -EmailFrom `"$EmailFrom`"" }
if ($SmtpServer) { $argLine += " -SmtpServer `"$SmtpServer`" -SmtpPort $SmtpPort" }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$trigger   = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

if ($PSCmdlet.ShouldProcess($taskName, "Register daily at $At as SYSTEM")) {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Registered '$taskName' — runs daily at $At as SYSTEM." 'OK'
    Write-Host ''
    Write-Host "  Test it now with:  Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
    Write-Host "  Remove it with:    .\Install-HealthCheckTask.ps1 -Remove" -ForegroundColor White
}
