<#
.SYNOPSIS
    One-shot network diagnostics for a workstation — everything you check when a
    "no internet / slow / can't reach the server" ticket comes in.

.DESCRIPTION
    Read-only. Gathers, in order:
      - Active adapters, IPv4/mask/gateway, DNS servers, DHCP vs static.
      - Default gateway ping + latency.
      - DNS resolution test (a name you pass, default a public host).
      - Internet reachability (ping + optional HTTP to a known endpoint).
      - Reachability of hosts you care about via -TargetHosts (DC, file server,
        printer, etc.).
      - Public IP (best-effort).
    Prints a clean summary and writes an HTML + text report.

.PARAMETER TargetHosts
    Extra hosts to test (ping + common ports). e.g. DC01,FS01,192.168.1.10
.PARAMETER TestName
    A DNS name to resolve for the DNS test (default 'www.microsoft.com').
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Get-NetworkDiagnostics.ps1
.EXAMPLE
    .\Get-NetworkDiagnostics.ps1 -TargetHosts DC01,FS01,PRINTER-HR

.NOTES
    Read-only. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding()]
param(
    [string[]]$TargetHosts,
    [string]$TestName = 'www.microsoft.com',
    [string]$OutputPath,
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
if (-not $PSBoundParameters.ContainsKey('TargetHosts')) { $__v = Get-ToolkitSetting 'Network.TargetHosts'; if ($null -ne $__v) { $TargetHosts = $__v; $__cfgUsed += 'Network.TargetHosts' } }
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
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
Write-Banner "Network Diagnostics"
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

$report = New-Object System.Collections.Generic.List[object]
function Add-Line([string]$Area, [string]$Item, [string]$Value, [string]$State = 'info') {
    $report.Add([pscustomobject]@{ Area = $Area; Item = $Item; Value = $Value; State = $State })
}

# --- adapters ----------------------------------------------------------------
Write-Log "Reading adapter configuration..." 'STEP'
$cfgs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True'
foreach ($c in $cfgs) {
    $ipv4 = ($c.IPAddress | Where-Object { $_ -notmatch ':' }) -join ', '
    $gw   = ($c.DefaultIPGateway -join ', ')
    $dns  = ($c.DNSServerSearchOrder -join ', ')
    $mode = if ($c.DHCPEnabled) { "DHCP (server $($c.DHCPServer))" } else { 'Static' }
    Add-Line 'Adapter' $c.Description "IPv4 $ipv4 | GW $gw | DNS $dns | $mode"
    Write-Log "  $($c.Description): $ipv4 (gw $gw, $mode)" 'INFO'
}
$primaryGw = ($cfgs.DefaultIPGateway | Where-Object { $_ -and $_ -notmatch ':' } | Select-Object -First 1)

# --- gateway -----------------------------------------------------------------
if ($primaryGw) {
    Write-Log "Pinging gateway $primaryGw..." 'STEP'
    $g = Test-Connection -ComputerName $primaryGw -Count 2 -ErrorAction SilentlyContinue
    if ($g) {
        $avg = [math]::Round((($g | Measure-Object -Property ResponseTime -Average).Average), 0)
        Add-Line 'Gateway' $primaryGw "reachable, ~${avg}ms" 'ok'
        Write-Log "  gateway OK (~${avg}ms)" 'OK'
    } else { Add-Line 'Gateway' $primaryGw 'NOT reachable' 'fail'; Write-Log "  gateway UNREACHABLE" 'ERROR' }
}

# --- DNS ---------------------------------------------------------------------
Write-Log "Resolving $TestName..." 'STEP'
try {
    $res = Resolve-DnsName -Name $TestName -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
    Add-Line 'DNS' $TestName "resolves to $($res.IPAddress)" 'ok'
    Write-Log "  DNS OK -> $($res.IPAddress)" 'OK'
} catch { Add-Line 'DNS' $TestName 'resolution FAILED' 'fail'; Write-Log "  DNS FAILED" 'ERROR' }

# --- internet ----------------------------------------------------------------
Write-Log "Testing internet..." 'STEP'
$netOk = Test-Connection -ComputerName '1.1.1.1' -Count 2 -Quiet -ErrorAction SilentlyContinue
Add-Line 'Internet' 'ping 1.1.1.1' $(if ($netOk) { 'reachable' } else { 'NOT reachable' }) $(if ($netOk) { 'ok' } else { 'fail' })
try {
    $http = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    $captive = ($http.Content.Trim() -ne 'Microsoft Connect Test')
    Add-Line 'Internet' 'HTTP connect test' $(if ($captive) { 'captive portal / proxy suspected' } else { 'clean' }) $(if ($captive) { 'warn' } else { 'ok' })
    Write-Log "  HTTP connect test: $(if ($captive) { 'captive/proxy?' } else { 'clean' })" $(if ($captive) { 'WARN' } else { 'OK' })
} catch { Add-Line 'Internet' 'HTTP connect test' 'no HTTP response' 'warn' }

# --- public IP ---------------------------------------------------------------
try {
    $pub = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8 -ErrorAction Stop)
    Add-Line 'Internet' 'Public IP' $pub 'info'
    Write-Log "  public IP: $pub" 'INFO'
} catch { Add-Line 'Internet' 'Public IP' 'unknown' 'info' }

# --- targets -----------------------------------------------------------------
if ($TargetHosts) {
    $commonPorts = @{ 'RDP' = 3389; 'SMB' = 445; 'HTTP' = 80; 'HTTPS' = 443; 'DNS' = 53 }
    foreach ($h in $TargetHosts) {
        Write-Log "Testing $h..." 'STEP'
        $ping = Test-Connection -ComputerName $h -Count 2 -Quiet -ErrorAction SilentlyContinue
        Add-Line 'Target' "$h (ping)" $(if ($ping) { 'reachable' } else { 'NOT reachable' }) $(if ($ping) { 'ok' } else { 'fail' })
        foreach ($p in $commonPorts.GetEnumerator()) {
            $open = Test-NetConnection -ComputerName $h -Port $p.Value -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($open.TcpTestSucceeded) { Add-Line 'Target' "$h : $($p.Key)/$($p.Value)" 'open' 'ok' }
        }
    }
}

# --- summary + report --------------------------------------------------------
$report | Format-Table -AutoSize | Out-Host
$css = @"
<style>body{font-family:Segoe UI,Arial;margin:24px}h1{font-size:19px}h2{color:#0b62c4;font-size:14px;border-bottom:2px solid #e6eef7;padding-bottom:3px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}th{background:#f5f8fc}
.ok{color:#15803d}.fail{color:#b91c1c;font-weight:600}.warn{color:#b45309}</style>
"@
$rowsHtml = ($report | ForEach-Object { "<tr><td>$($_.Area)</td><td>$($_.Item)</td><td class='$($_.State)'>$($_.Value)</td></tr>" }) -join "`n"
$html = @"
<!doctype html><html><head><meta charset='utf-8'>$css<title>Network diag — $env:COMPUTERNAME</title></head><body>
<h1>Network diagnostics — $env:COMPUTERNAME</h1><p>$(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>
<table><tr><th>Area</th><th>Item</th><th>Value</th></tr>$rowsHtml</table></body></html>
"@
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$out = Join-Path $OutputPath "NetDiag_${env:COMPUTERNAME}_$stamp.html"
$html | Set-Content -Path $out -Encoding UTF8
Write-Log "Report: $out" 'OK'
try { if ([Environment]::UserInteractive) { Start-Process $out } } catch { }
