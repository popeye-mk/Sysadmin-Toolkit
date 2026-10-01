<#
.SYNOPSIS
    Windows Firewall profile status + enabled inbound allow rules + what's
    actually listening — rolled into one report.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. For each
    target machine (local or remote):
      - Firewall profile state (Domain/Private/Public — on or off).
      - Every enabled inbound Allow rule, with the port(s)/program it opens.
      - What's actually listening right now (Get-NetTCPConnection -Listen),
        with the owning process name — the "is this port open because of a
        rule, or because something's just listening anyway" cross-check.

.PARAMETER ComputerName
    One or more machines to check. Default: local machine only.
.PARAMETER FlagPorts
    Port numbers worth calling out specifically if found open/listening
    (default: a short list of commonly-risky ones — RDP 3389, SMB 445,
    WinRM 5985/5986, Telnet 23). Purely a highlight in the report; every
    rule/listener is still shown either way.

.EXAMPLE
    .\Get-FirewallAuditReport.ps1
.EXAMPLE
    .\Get-FirewallAuditReport.ps1 -ComputerName SRV01,SRV02 -FlagPorts 3389,445,1433

.NOTES
    Remote checks use PowerShell remoting (Invoke-Command) — needs WinRM
    enabled on the target. Read-only. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [int[]]$FlagPorts = @(23, 445, 3389, 5985, 5986)
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
if (-not $PSBoundParameters.ContainsKey('FlagPorts')) { $__v = Get-ToolkitSetting 'Security.FlagPorts'; if ($null -ne $__v) { $FlagPorts = $__v; $__cfgUsed += 'Security.FlagPorts' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Reports')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}

$scanBlock = {
    $profiles = Get-NetFirewallProfile | Select-Object Name, Enabled

    $rules = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
        ForEach-Object {
            $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name        = $_.DisplayName
                Profile     = ($_.Profile -join ',')
                Protocol    = $portFilter.Protocol
                LocalPort   = $portFilter.LocalPort
            }
        }

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [pscustomobject]@{ LocalPort = $_.LocalPort; Process = if ($proc) { $proc.ProcessName } else { "pid $($_.OwningProcess)" } }
    } | Sort-Object LocalPort -Unique

    [pscustomobject]@{ Profiles = $profiles; Rules = $rules; Listeners = $listeners }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Firewall Audit Report" -ForegroundColor White
Write-Host "  ===========================================" -ForegroundColor DarkGray

$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }
$allData = @{}
foreach ($target in $targets) {
    Write-Log "Checking $target..." 'STEP'
    try {
        if ($target -in @($env:COMPUTERNAME, 'localhost', '.', '')) { $allData[$target] = & $scanBlock }
        else { $allData[$target] = Invoke-Command -ComputerName $target -ScriptBlock $scanBlock -ErrorAction Stop }
    } catch {
        Write-Log "Could not check ${target}: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $allData.Count) { Write-Log "No machine reachable." 'WARN'; return }

$flaggedListeners = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($target in $allData.Keys) {
    $data = $allData[$target]
    $offProfiles = @($data.Profiles | Where-Object { -not $_.Enabled })
    if ($offProfiles.Count) { Write-Log "  ${target}: firewall OFF for profile(s): $(($offProfiles.Name) -join ', ')" 'WARN' }
    foreach ($l in $data.Listeners) {
        if ($FlagPorts -contains $l.LocalPort) {
            $flaggedListeners.Add([pscustomobject]@{ ComputerName = $target; Port = $l.LocalPort; Process = $l.Process })
        }
    }
}

if ($flaggedListeners.Count) {
    Write-Host ''
    Write-Host "  Flagged ports listening:" -ForegroundColor Yellow
    $flaggedListeners | Sort-Object ComputerName, Port | ForEach-Object { Write-Host ("    {0}  port {1}  ({2})" -f $_.ComputerName, $_.Port, $_.Process) -ForegroundColor Yellow }
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\FirewallAudit_{0}.html" -f $stamp)

$sections = foreach ($target in $allData.Keys) {
    $data = $allData[$target]
    $profileRows = ($data.Profiles | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Enabled)</td></tr>" }) -join "`n"
    $ruleRows = ($data.Rules | ForEach-Object { "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.Profile)</td><td>$($_.Protocol)</td><td>$($_.LocalPort -join ', ')</td></tr>" }) -join "`n"
    $listenerRows = ($data.Listeners | ForEach-Object {
        $cls = if ($FlagPorts -contains $_.LocalPort) { 'flagged' } else { '' }
        "<tr class='$cls'><td>$($_.LocalPort)</td><td>$($_.Process)</td></tr>"
    }) -join "`n"
    @"
<h2>$target</h2>
<h3>Firewall profiles</h3><table><tr><th>Profile</th><th>Enabled</th></tr>$profileRows</table>
<h3>Inbound allow rules ($($data.Rules.Count))</h3><table><tr><th>Rule</th><th>Profile(s)</th><th>Protocol</th><th>Port(s)</th></tr>$ruleRows</table>
<h3>Listening ports ($($data.Listeners.Count))</h3><table><tr><th>Port</th><th>Process</th></tr>$listenerRows</table>
"@
}

$html = @"
<html><head><title>Firewall Audit — $stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%;margin-bottom:1.5em} td,th{border:1px solid #ccc;padding:5px 9px;text-align:left;font-size:.85em}
th{background:#f0f0f0} h2{border-top:2px solid #ccc;padding-top:1em;margin-top:2em} .flagged td{background:#fff8e1;color:#8a6d00}
</style></head><body>
<h1>Firewall Audit Report</h1>
<p>$stamp &nbsp; $($allData.Count) machine(s) checked &nbsp; Flagged ports listening: $($flaggedListeners.Count)</p>
$($sections -join "`n")
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
