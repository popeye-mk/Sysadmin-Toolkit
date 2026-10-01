<#
.SYNOPSIS
    Fleet-wide Intune device compliance report — the cloud counterpart to
    07-Reporting-Health's per-PC health check, but for every enrolled device at
    once, from the management plane rather than logged in locally.

.DESCRIPTION
    Pulls every Intune-managed device via Graph and reports: compliance state,
    OS + version, last check-in (flagging stale devices), encryption status,
    management agent, and owner. Read-only. Writes an HTML + CSV report, same
    style as the rest of the kit, so it drops straight into your existing
    reporting habits (and is a natural fit to also push into Zabbix/Grafana —
    see 10-Monitoring-Zabbix).

.PARAMETER StaleDays
    Flag devices that haven't checked in within this many days (default 14).
.PARAMETER NonCompliantOnly
    Only list devices that are not compliant.
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Get-IntuneDeviceCompliance.ps1
.EXAMPLE
    .\Get-IntuneDeviceCompliance.ps1 -NonCompliantOnly -StaleDays 7

.NOTES
    Requires Microsoft.Graph.DeviceManagement and a role with device-read rights
    (Intune Administrator, or a custom role with DeviceManagementManagedDevices.Read.All).
    Read-only. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 14,
    [switch]$NonCompliantOnly,
    [string]$OutputPath
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
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- toolkit helpers (standalone-safe) -------------------------------------
# Uses _GraphCommon.psm1 when it sits next to this script (inside the kit).
# Copied out on its own, this script self-provides the same helpers.
$__graph = Join-Path $PSScriptRoot '_GraphCommon.psm1'
if (Test-Path $__graph) {
    Import-Module $__graph -Force
} else {
    function Get-ToolkitRoot { param([string]$Path = 'C:\Sysadmin-Toolkit')
        try { foreach ($s in @('','Reports','Backups','Logs')) { $p = if ($s) { Join-Path $Path $s } else { $Path }; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } } } catch { }
        return $Path }
    function Write-Log { param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
        $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
        Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
        try { $lf = Join-Path (Get-ToolkitRoot) ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')); Add-Content -Path $lf -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { } }
    function Write-Banner { param([Parameter(Mandatory)][string]$Title) Write-Host ''; Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White; Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray }
    function Connect-ToolkitGraph { [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Scopes,[string]$TenantId)
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'; return $false }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext
        $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru | Where-Object { $Scopes -contains $_ }))
        if ($ctx -and $haveAll) { Write-Log "Reusing existing Graph connection ($($ctx.Account))." 'INFO'; return $true }
        Write-Log "Connecting to Microsoft Graph (scopes: $($Scopes -join ', '))..." 'STEP'
        try { $p = @{ Scopes = $Scopes; NoWelcome = $true }; if ($TenantId) { $p.TenantId = $TenantId }; Connect-MgGraph @p -ErrorAction Stop; Write-Log "Connected as $((Get-MgContext).Account)." 'OK'; return $true }
        catch { Write-Log "Graph connection failed: $($_.Exception.Message)" 'ERROR'; return $false } }
    function Test-GraphScope { param([Parameter(Mandatory)][string]$Scope) $ctx = Get-MgContext; if (-not $ctx) { return $false }; return ($ctx.Scopes -contains $Scope) }
}
Write-Banner "Intune Device Compliance"

$scopes = @('DeviceManagementManagedDevices.Read.All')
if (-not (Connect-ToolkitGraph -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

Write-Log "Fetching managed devices..." 'STEP'
$devices = @(Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop)
Write-Log "$($devices.Count) device(s) returned." 'INFO'

$now = Get-Date
$rows = foreach ($d in $devices) {
    $lastSync = $d.LastSyncDateTime
    $staleDaysAgo = if ($lastSync) { [math]::Round(($now - $lastSync).TotalDays, 1) } else { $null }
    [pscustomobject]@{
        DeviceName    = $d.DeviceName
        Owner         = $d.UserPrincipalName
        OS            = "$($d.OperatingSystem) $($d.OsVersion)"
        Compliance    = $d.ComplianceState
        Encrypted     = $d.IsEncrypted
        ManagementAgent = $d.ManagementAgent
        LastSync      = if ($lastSync) { $lastSync.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        DaysSinceSync = $staleDaysAgo
        Stale         = ($null -eq $staleDaysAgo) -or ($staleDaysAgo -gt $StaleDays)
        SerialNumber  = $d.SerialNumber
        Model         = $d.Model
    }
}

if ($NonCompliantOnly) { $rows = $rows | Where-Object { $_.Compliance -ne 'compliant' } }

$compliant    = @($rows | Where-Object Compliance -eq 'compliant').Count
$noncompliant = @($rows | Where-Object Compliance -eq 'noncompliant').Count
$stale        = @($rows | Where-Object Stale).Count

$rows | Sort-Object Compliance, DeviceName | Format-Table DeviceName, Owner, OS, Compliance, Encrypted, LastSync, Stale -AutoSize | Out-Host
Write-Host ''
Write-Host "  Compliant: $compliant   Non-compliant: $noncompliant   Stale (>$StaleDays d): $stale   Total: $($rows.Count)" -ForegroundColor $(if ($noncompliant -eq 0 -and $stale -eq 0) { 'Green' } else { 'Yellow' })
Write-Log "Compliance summary — compliant=$compliant noncompliant=$noncompliant stale=$stale total=$($rows.Count)" 'STEP'

# --- HTML ------------------------------------------------------------------
$css = @"
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327}h1{font-size:20px;margin:0 0 4px}
.sub{color:#6b7280;font-size:12px;margin-bottom:8px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}
th{background:#f5f8fc}tr:nth-child(even) td{background:#fafcff}
.compliant{color:#15803d;font-weight:600}.noncompliant{color:#b91c1c;font-weight:600}.stale{color:#b45309;font-weight:600}
</style>
"@
$rowsHtml = ($rows | Sort-Object Compliance, DeviceName | ForEach-Object {
    $cCls = if ($_.Compliance -eq 'compliant') { 'compliant' } elseif ($_.Compliance -eq 'noncompliant') { 'noncompliant' } else { '' }
    $sCls = if ($_.Stale) { 'stale' } else { '' }
    "<tr><td>$($_.DeviceName)</td><td>$($_.Owner)</td><td>$($_.OS)</td><td class='$cCls'>$($_.Compliance)</td><td>$($_.Encrypted)</td><td>$($_.LastSync)</td><td class='$sCls'>$(if ($_.Stale) { 'STALE' } else { '' })</td></tr>"
}) -join "`n"
$html = @"
<!doctype html><html><head><meta charset='utf-8'>$css<title>Intune compliance</title></head><body>
<h1>Intune device compliance</h1>
<div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') · compliant $compliant · non-compliant $noncompliant · stale (>$StaleDays d) $stale · total $($rows.Count)</div>
<table><tr><th>Device</th><th>Owner</th><th>OS</th><th>Compliance</th><th>Encrypted</th><th>Last sync</th><th></th></tr>$rowsHtml</table>
</body></html>
"@
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "IntuneCompliance_$stamp.html"
$csvOut  = Join-Path $OutputPath "IntuneCompliance_$stamp.csv"
$html | Set-Content -Path $htmlOut -Encoding UTF8
$rows | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Log "HTML: $htmlOut" 'OK'
Write-Log "CSV : $csvOut" 'OK'
try { if ([Environment]::UserInteractive) { Start-Process $htmlOut } } catch { }
