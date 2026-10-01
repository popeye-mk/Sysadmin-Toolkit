<#
.SYNOPSIS
    Install and configure Zabbix Agent 2 on a Windows machine, and wire in this
    toolkit's UserParameter so it starts reporting into Zabbix/Grafana right away.

.DESCRIPTION
    Silent MSI install of Zabbix Agent 2, configured for active checks against
    your Zabbix server (the normal mode — the agent calls out, so you don't
    need to open an inbound firewall hole on every endpoint), with an option to
    also allow passive checks (inbound 10050) if your server needs those.

    With -DeployUserParameters (default on), it also copies SysadminToolkit.conf
    and Get-ToolkitZabbixMetrics.ps1 from this same folder into the agent's
    config include directory, so the "toolkit.metrics" item works immediately
    after install — no separate step.

    Runs standalone (copy this whole 10-Monitoring-Zabbix folder to a machine
    and run it) or via Intune — see Deploy-ScriptViaIntune.ps1 in
    09-Entra-Intune, or package it as a Win32 app if you prefer that route.

.PARAMETER InstallerPath
    Local path to the Zabbix Agent 2 MSI. Get the current one for your OS from
    https://www.zabbix.com/download_agents — version/URLs change, so this
    script does not hardcode a download link.
.PARAMETER ServerIP
    Zabbix server/proxy IP or hostname, for passive checks (Server=).
.PARAMETER ServerActiveIP
    Zabbix server/proxy IP or hostname, for active checks (ServerActive=).
    Usually the same as -ServerIP. This is the one that actually matters for
    the toolkit.metrics item to be picked up.
.PARAMETER Hostname
    Host name as it will appear in Zabbix (default: this machine's name — must
    match the host object you create in Zabbix exactly).
.PARAMETER AllowPassiveChecks
    Also open inbound TCP 10050 for passive checks. Off by default — active
    checks alone cover the toolkit.metrics item.
.PARAMETER DeployUserParameters
    Copy SysadminToolkit.conf + the metrics script into the agent's config dir.
    Default on; pass -DeployUserParameters:$false to install the agent only.

.EXAMPLE
    .\Install-ZabbixAgent.ps1 -InstallerPath C:\Temp\zabbix_agent2-7.0.msi -ServerActiveIP zabbix.contoso.local -WhatIf
.EXAMPLE
    .\Install-ZabbixAgent.ps1 -InstallerPath C:\Temp\zabbix_agent2-7.0.msi -ServerActiveIP zabbix.contoso.local -AllowPassiveChecks -ServerIP zabbix.contoso.local

.NOTES
    Run as Administrator. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$InstallerPath,
    [string]$ServerIP,
    [string]$ServerActiveIP,
    [string]$Hostname = $env:COMPUTERNAME,
    [switch]$AllowPassiveChecks,
    [bool]$DeployUserParameters = $true
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
if (-not $PSBoundParameters.ContainsKey('InstallerPath')) { $__v = Get-ToolkitSetting 'Monitoring.ZabbixInstallerPath' -File; if ($null -ne $__v) { $InstallerPath = $__v; $__cfgUsed += 'Monitoring.ZabbixInstallerPath' } }
if (-not $PSBoundParameters.ContainsKey('ServerIP')) { $__v = Get-ToolkitSetting 'Monitoring.ZabbixServer'; if ($null -ne $__v) { $ServerIP = $__v; $__cfgUsed += 'Monitoring.ZabbixServer' } }
if (-not $PSBoundParameters.ContainsKey('ServerActiveIP')) { $__v = Get-ToolkitSetting 'Monitoring.ZabbixServerActive'; if ($null -ne $__v) { $ServerActiveIP = $__v; $__cfgUsed += 'Monitoring.ZabbixServerActive' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $InstallerPath) { Write-Host "  [ERROR] Missing: -InstallerPath <Zabbix Agent 2 .msi> (or Monitoring.ZabbixInstallerPath in Config)" -ForegroundColor Red; return }
if (-not $ServerActiveIP) { Write-Host "  [ERROR] Missing: -ServerActiveIP <zabbix server> (or Monitoring.ZabbixServerActive in Config)" -ForegroundColor Red; return }


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Install Zabbix Agent" -ForegroundColor White
Write-Host "  ===================================" -ForegroundColor DarkGray

function Test-Admin {
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}
if (-not (Test-Admin)) { Write-Log "Needs Administrator rights." 'ERROR'; return }
if (-not (Test-Path $InstallerPath)) { Write-Log "Installer not found: $InstallerPath" 'ERROR'; return }

if (-not $ServerIP) { $ServerIP = $ServerActiveIP }

Write-Log "Installer      : $InstallerPath" 'INFO'
Write-Log "Hostname       : $Hostname" 'INFO'
Write-Log "ServerActive   : $ServerActiveIP" 'INFO'
Write-Log "Passive checks : $($AllowPassiveChecks.IsPresent)" 'INFO'

# --- silent install ------------------------------------------------------------
$msiArgs = @(
    '/i', "`"$InstallerPath`"",
    '/qn', '/norestart',
    "SERVER=`"$ServerIP`"",
    "SERVERACTIVE=`"$ServerActiveIP`"",
    "HOSTNAME=`"$Hostname`"",
    "ENABLEPATH=1"
)
if ($PSCmdlet.ShouldProcess("Zabbix Agent 2", "Silent install")) {
    Write-Log "Running msiexec..." 'STEP'
    $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) { Write-Log "Install completed." 'OK' }
    elseif ($p.ExitCode -eq 3010) { Write-Log "Install completed — a reboot is recommended (exit 3010)." 'WARN' }
    else { Write-Log "msiexec exited with code $($p.ExitCode) — check the Windows Installer log." 'ERROR'; return }
}

# --- locate the install + config -------------------------------------------------
$agentDir = @(
    "$env:ProgramFiles\Zabbix Agent 2",
    "${env:ProgramFiles(x86)}\Zabbix Agent 2"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $agentDir) { Write-Log "Could not locate the Zabbix Agent 2 install directory — check it installed correctly." 'ERROR'; return }
Write-Log "Install dir    : $agentDir" 'INFO'

$confDir = Join-Path $agentDir 'zabbix_agent2.d'
if (-not (Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }

# --- passive checks firewall ------------------------------------------------------
if ($AllowPassiveChecks -and $PSCmdlet.ShouldProcess("Firewall", "Allow inbound TCP 10050")) {
    try {
        if (-not (Get-NetFirewallRule -DisplayName 'Zabbix Agent (10050)' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'Zabbix Agent (10050)' -Direction Inbound -Protocol TCP -LocalPort 10050 -Action Allow | Out-Null
            Write-Log "Firewall rule added for TCP 10050." 'OK'
        } else { Write-Log "Firewall rule already exists." 'INFO' }
    } catch { Write-Log "Firewall rule failed: $($_.Exception.Message)" 'WARN' }
}

# --- deploy this toolkit's UserParameter ------------------------------------------
if ($DeployUserParameters) {
    $srcConf = Join-Path $PSScriptRoot 'UserParameters\SysadminToolkit.conf'
    $srcPs1  = Join-Path $PSScriptRoot 'UserParameters\Get-ToolkitZabbixMetrics.ps1'
    $dstConf = Join-Path $confDir 'SysadminToolkit.conf'
    $dstDir  = 'C:\Sysadmin-Toolkit\10-Monitoring-Zabbix\UserParameters'

    if ((Test-Path $srcConf) -and (Test-Path $srcPs1)) {
        if ($PSCmdlet.ShouldProcess("UserParameter", "Deploy toolkit.metrics")) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            Copy-Item $srcPs1 -Destination $dstDir -Force
            Copy-Item $srcConf -Destination $dstConf -Force
            Write-Log "Deployed metrics script -> $dstDir" 'OK'
            Write-Log "Deployed UserParameter  -> $dstConf" 'OK'
        }
    } else {
        Write-Log "Could not find SysadminToolkit.conf / Get-ToolkitZabbixMetrics.ps1 next to this script — skipping UserParameter deployment." 'WARN'
    }
}

# --- restart service ---------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("Zabbix Agent 2 service", "Restart")) {
    try {
        Restart-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        Write-Log "Zabbix Agent 2 service restarted." 'OK'
    } catch { Write-Log "Could not restart the service — restart it manually: Restart-Service 'Zabbix Agent 2'" 'WARN' }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Test the item from this machine with:" -ForegroundColor Green
    Write-Host "    & `"$agentDir\zabbix_agent2.exe`" -t toolkit.metrics" -ForegroundColor White
    Write-Host "  Then import the template and create/link the host in Zabbix — see this folder's README." -ForegroundColor White
}
