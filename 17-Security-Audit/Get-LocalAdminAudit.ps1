<#
.SYNOPSIS
    Who's actually in the local Administrators group, across one or more
    machines — almost always turns up at least one surprise.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Reads the
    local Administrators group (local or remote via PowerShell remoting) and
    flags any member NOT on your expected/allow list — the built-in
    Administrator account and whatever AD group you normally use to grant
    local admin (e.g. a "Workstation-Admins" group) are the usual baseline;
    everything else is worth a look.

.PARAMETER ComputerName
    One or more machines to check. Default: local machine only.
.PARAMETER ExpectedMembers
    Names considered "known good" and never flagged — match loosely (name
    only, domain prefix optional). Default covers the built-in Administrator,
    Domain Admins and Enterprise Admins; pass your own list to match your environment (e.g.
    your delegated workstation-admin group).
.PARAMETER FlaggedOnly
    Only show machines that have at least one unexpected member.

.EXAMPLE
    .\Get-LocalAdminAudit.ps1
.EXAMPLE
    .\Get-LocalAdminAudit.ps1 -ComputerName PC01,PC02,SRV01 -ExpectedMembers 'Administrator','Domain Admins','Workstation-Admins' -FlaggedOnly

.NOTES
    Remote checks use PowerShell remoting (Invoke-Command) — needs WinRM
    enabled on the target and local admin rights there to read the group.
    Read-only. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string[]]$ExpectedMembers = @('Administrator', 'Domain Admins', 'Enterprise Admins'),
    [switch]$FlaggedOnly
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
if (-not $PSBoundParameters.ContainsKey('ExpectedMembers')) { $__v = Get-ToolkitSetting 'Security.ExpectedLocalAdmins'; if ($null -ne $__v) { $ExpectedMembers = $__v; $__cfgUsed += 'Security.ExpectedLocalAdmins' } }
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

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Local Admin Audit" -ForegroundColor White
Write-Host "  =======================================" -ForegroundColor DarkGray

$scanBlock = {
    try { Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource }
    catch {
        # Fallback for older systems / edge cases where Get-LocalGroupMember fails (e.g. an orphaned SID in the group)
        try {
            $group = [ADSI]"WinNT://./Administrators,group"
            $group.Invoke('Members') | ForEach-Object {
                $path = $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
                [pscustomobject]@{ Name = ($path -replace '^WinNT://', '' -replace '/', '\'); ObjectClass = 'Unknown'; PrincipalSource = 'Unknown' }
            }
        } catch { @() }
    }
}

$allResults = New-Object System.Collections.Generic.List[pscustomobject]
$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }

foreach ($target in $targets) {
    Write-Log "Checking $target..." 'STEP'
    try {
        if ($target -in @($env:COMPUTERNAME, 'localhost', '.', '')) {
            $members = & $scanBlock
        } else {
            $members = Invoke-Command -ComputerName $target -ScriptBlock $scanBlock -ErrorAction Stop
        }
        foreach ($m in $members) {
            $shortName = ($m.Name -split '\\')[-1]
            $expected = $ExpectedMembers | Where-Object { $shortName -like $_ -or $m.Name -like $_ }
            $allResults.Add([pscustomobject]@{
                ComputerName = $target
                Member       = $m.Name
                ObjectClass  = $m.ObjectClass
                Source       = $m.PrincipalSource
                Expected     = [bool]$expected
            })
        }
    } catch {
        Write-Log "Could not check ${target}: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $allResults.Count) { Write-Log "No results (no machine reachable, or no members returned)." 'WARN'; return }

$unexpected = @($allResults | Where-Object { -not $_.Expected })
$byMachine = @($allResults | Group-Object ComputerName)

Write-Host ''
foreach ($grp in $byMachine) {
    $flagged = @($grp.Group | Where-Object { -not $_.Expected })
    if ($FlaggedOnly -and -not $flagged.Count) { continue }
    $color = if ($flagged.Count) { 'Red' } else { 'Green' }
    Write-Host ("  {0}:" -f $grp.Name) -ForegroundColor $color
    foreach ($m in $grp.Group) {
        $tag = if ($m.Expected) { '   ' } else { '!! ' }
        Write-Host ("    {0}{1}" -f $tag, $m.Member) -ForegroundColor $(if ($m.Expected) { 'Gray' } else { 'Red' })
    }
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\LocalAdminAudit_{0}.html" -f $stamp)
$reportRows = $allResults
if ($FlaggedOnly) { $reportRows = $allResults | Where-Object { -not $_.Expected } }
$rows = ($reportRows | Sort-Object ComputerName, Member | ForEach-Object {
    $cls = if (-not $_.Expected) { 'flagged' } else { '' }
    "<tr class='$cls'><td>$($_.ComputerName)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Member))</td><td>$($_.ObjectClass)</td><td>$($_.Source)</td><td>$(if ($_.Expected) { 'expected' } else { 'REVIEW' })</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>Local Admin Audit — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left} th{background:#f0f0f0}
.flagged td{background:#fdecea;color:#c62828}</style>
</head><body>
<h1>Local Administrators Audit</h1>
<p>$stamp &nbsp; $($targets.Count) machine(s) checked &nbsp; Unexpected members: $($unexpected.Count)</p>
<table><tr><th>Computer</th><th>Member</th><th>Type</th><th>Source</th><th>Status</th></tr>
$rows
</table>
<p style="color:#6b7280;font-size:12px">"Expected" members matched -ExpectedMembers (default: Administrator, Domain Admins). Pass your own list to match your environment's delegation model.</p>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
if ($unexpected.Count) { Write-Log "$($unexpected.Count) unexpected local admin member(s) across $($byMachine.Count) machine(s) — review the report. Add your own admin group to -ExpectedMembers to stop it being flagged." 'WARN' }
else { Write-Log "No unexpected local admin members found." 'OK' }
