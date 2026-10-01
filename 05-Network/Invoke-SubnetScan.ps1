<#
.SYNOPSIS
    Sweep a subnet for live hosts, resolve their names, grab MAC addresses, and
    optionally probe common ports — a quick "what's on this network" map.

.DESCRIPTION
    Pings every address in a range in parallel-ish batches, then for responders
    reads the ARP cache for the MAC and does a reverse DNS lookup. Optionally
    checks a small set of common TCP ports so you can spot servers, printers and
    RDP hosts. Read-only. Writes a CSV + HTML you can keep as an inventory.

    Scope it to a network you are authorised to scan.

.PARAMETER Subnet
    First three octets, e.g. '192.168.1'. Combined with -Start/-End.
    (For /24 networks — the common case. For odd ranges, adjust -Start/-End.)
.PARAMETER Start
    Last-octet range to scan (default 1..254).
.PARAMETER End
    Last-octet range to scan (default 1..254).
.PARAMETER Ports
    Switch: also probe common ports (22,80,443,445,3389,631,8080).
.PARAMETER TimeoutMs
    Ping timeout per host in ms (default 300).
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Invoke-SubnetScan.ps1 -Subnet 192.168.1
.EXAMPLE
    .\Invoke-SubnetScan.ps1 -Subnet 10.0.0 -Start 1 -End 100 -Ports

.NOTES
    Read-only. Runs best on Windows PowerShell 5.1+ (uses runspace jobs for
    speed). Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding()]
param(
    [string]$Subnet,
    [int]$Start = 1,
    [int]$End = 254,
    [switch]$Ports,
    [int]$TimeoutMs = 300,
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
if (-not $PSBoundParameters.ContainsKey('Subnet')) { $__v = Get-ToolkitSetting 'Network.Subnet'; if ($null -ne $__v) { $Subnet = $__v; $__cfgUsed += 'Network.Subnet' } }
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $Subnet) { Write-Host "  [ERROR] Missing: -Subnet <e.g. 192.168.1.0/24> (or Network.Subnet in Config)" -ForegroundColor Red; return }


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
Write-Banner "Subnet Scan"
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

$targets = $Start..$End | ForEach-Object { "$Subnet.$_" }
Write-Log "Sweeping $($targets.Count) addresses ($Subnet.$Start - $Subnet.$End)..." 'STEP'

# fast async ping
$alive = New-Object System.Collections.Generic.List[string]
$tasks = foreach ($ip in $targets) {
    $p = New-Object System.Net.NetworkInformation.Ping
    [pscustomobject]@{ IP = $ip; Task = $p.SendPingAsync($ip, $TimeoutMs); Ping = $p }
}
foreach ($t in $tasks) {
    try { if ($t.Task.Result.Status -eq 'Success') { $alive.Add($t.IP) } } catch { }
    finally { $t.Ping.Dispose() }
}
Write-Log "$($alive.Count) host(s) responding." 'OK'

# refresh ARP so MACs are populated
$arp = @{}
(& arp.exe -a) 2>$null | ForEach-Object {
    if ($_ -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F-]{17})') { $arp[$matches[1]] = $matches[2] }
}

$commonPorts = 22, 80, 443, 445, 3389, 631, 8080
$results = New-Object System.Collections.Generic.List[object]
foreach ($ip in ($alive | Sort-Object { [version]($_ -replace '^\d+\.\d+\.\d+\.', '0.0.0.') })) {
    $name = try { ([System.Net.Dns]::GetHostEntry($ip)).HostName } catch { '' }
    $mac  = $arp[$ip]
    $openPorts = ''
    if ($Ports) {
        $found = foreach ($pt in $commonPorts) {
            $c = New-Object System.Net.Sockets.TcpClient
            try { if ($c.ConnectAsync($ip, $pt).Wait(300)) { $pt } } catch { } finally { $c.Dispose() }
        }
        $openPorts = ($found | Where-Object { $_ }) -join ', '
    }
    $results.Add([pscustomobject]@{ IP = $ip; Hostname = $name; MAC = $mac; OpenPorts = $openPorts })
    Write-Log ("  {0,-15} {1,-30} {2}" -f $ip, $name, $mac) 'INFO'
}

$results | Format-Table -AutoSize | Out-Host
$css = "<style>body{font-family:Segoe UI,Arial;margin:24px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}th{background:#f5f8fc}</style>"
$rowsHtml = ($results | ForEach-Object { "<tr><td>$($_.IP)</td><td>$($_.Hostname)</td><td>$($_.MAC)</td><td>$($_.OpenPorts)</td></tr>" }) -join "`n"
$html = "<!doctype html><html><head><meta charset='utf-8'>$css<title>Subnet scan $Subnet</title></head><body><h1>Subnet scan $Subnet.$Start-$End</h1><p>$(Get-Date -Format 'yyyy-MM-dd HH:mm') — $($results.Count) hosts</p><table><tr><th>IP</th><th>Hostname</th><th>MAC</th><th>Open ports</th></tr>$rowsHtml</table></body></html>"
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$safeSubnet = $Subnet -replace '\.', '-'
$csv  = Join-Path $OutputPath "SubnetScan_${safeSubnet}_$stamp.csv"
$out  = Join-Path $OutputPath "SubnetScan_${safeSubnet}_$stamp.html"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$html | Set-Content -Path $out -Encoding UTF8
Write-Log "CSV : $csv" 'OK'
Write-Log "HTML: $out" 'OK'
try { if ([Environment]::UserInteractive) { Start-Process $out } } catch { }
