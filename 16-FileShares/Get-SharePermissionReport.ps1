<#
.SYNOPSIS
    Who has access to what on your file shares — share-level + NTFS
    permissions, plus orphaned SIDs nobody cleaned up.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Enumerates
    SMB shares (local or remote), reads both the share-level permissions
    (Get-SmbShareAccess) and the NTFS ACL of each share's underlying folder
    (Get-Acl), and flags any permission entry that's an orphaned SID — a
    leftover grant for a deleted account nobody removed. Read-only.

.PARAMETER ComputerName
    File server to check (default: local machine). Remote uses CIM/WinRM.
.PARAMETER IncludeAdminShares
    Also include the built-in admin shares (C$, ADMIN$, IPC$, print$).
    Off by default — you almost never want those in a permission review.
.PARAMETER ShareName
    Check specific share(s) only, instead of every share on the server.

.EXAMPLE
    .\Get-SharePermissionReport.ps1
.EXAMPLE
    .\Get-SharePermissionReport.ps1 -ComputerName FS01 -ShareName Finance,HR

.NOTES
    Needs read rights on the share definitions and the underlying NTFS ACLs.
    Remote checks need WinRM/CIM reachability to the target. Read-only.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$IncludeAdminShares,
    [string[]]$ShareName
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
if (-not $PSBoundParameters.ContainsKey('ComputerName')) { $__v = Get-ToolkitSetting 'Shares.FileServer'; if ($null -ne $__v) { $ComputerName = $__v; $__cfgUsed += 'Shares.FileServer' } }
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
function Test-OrphanedSid {
    param([string]$IdentityReference)
    # An unresolved account shows up AS its SID string (S-1-5-21-...-1234), because
    # Windows couldn't translate it to a name — that's the signature of an orphan.
    return $IdentityReference -match '^S-1-5-21-\d+-\d+-\d+-\d+$'
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Share Permission Report" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor DarkGray

$localNames = @($env:COMPUTERNAME, 'localhost', '.', '')
$isRemote = $ComputerName -notin $localNames

try {
    $shareParams = @{ ErrorAction = 'Stop' }
    if ($isRemote) { $shareParams.CimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop }
    $shares = @(Get-SmbShare @shareParams)
} catch {
    Write-Log "Could not enumerate shares on ${ComputerName}: $($_.Exception.Message)" 'ERROR'; return
}

if (-not $IncludeAdminShares) { $shares = $shares | Where-Object { $_.Name -notmatch '\$$' -and $_.Name -ne 'print$' } }
if ($ShareName) { $shares = $shares | Where-Object { $_.Name -in $ShareName } }
if (-not $shares.Count) { Write-Log "No shares matched." 'WARN'; return }

Write-Log "Checking $($shares.Count) share(s) on $ComputerName..." 'STEP'

$shareRows = New-Object System.Collections.Generic.List[pscustomobject]
$ntfsRows  = New-Object System.Collections.Generic.List[pscustomobject]
$orphanCount = 0

foreach ($share in $shares) {
    Write-Log "  $($share.Name) -> $($share.Path)" 'INFO'

    # --- share-level permissions ---
    try {
        $accessParams = @{ Name = $share.Name; ErrorAction = 'Stop' }
        if ($isRemote) { $accessParams.CimSession = $shareParams.CimSession }
        $access = @(Get-SmbShareAccess @accessParams)
        foreach ($a in $access) {
            $orphan = Test-OrphanedSid -IdentityReference $a.AccountName
            if ($orphan) { $orphanCount++ }
            $shareRows.Add([pscustomobject]@{ Share = $share.Name; Path = $share.Path; Account = $a.AccountName; Right = $a.AccessRight; Type = $a.AccessControlType; Orphaned = $orphan })
        }
    } catch { Write-Log "  Could not read share permissions for $($share.Name): $($_.Exception.Message)" 'WARN' }

    # --- NTFS permissions on the underlying folder ---
    $path = if ($isRemote) { "\\$ComputerName\$($share.Name)" } else { $share.Path }
    try {
        $acl = Get-Acl -Path $path -ErrorAction Stop
        foreach ($ace in $acl.Access) {
            $orphan = Test-OrphanedSid -IdentityReference $ace.IdentityReference.Value
            if ($orphan) { $orphanCount++ }
            $ntfsRows.Add([pscustomobject]@{ Share = $share.Name; Account = $ace.IdentityReference.Value; Rights = $ace.FileSystemRights; Type = $ace.AccessControlType; Inherited = $ace.IsInherited; Orphaned = $orphan })
        }
    } catch { Write-Log "  Could not read NTFS ACL for $($share.Name) ($path): $($_.Exception.Message)" 'WARN' }
}

if ($isRemote -and $shareParams.CimSession) { Remove-CimSession -CimSession $shareParams.CimSession -ErrorAction SilentlyContinue }

Write-Host ''
if ($orphanCount) { Write-Log "$orphanCount orphaned SID(s) found across share + NTFS permissions — see report." 'WARN' }
else { Write-Log "No orphaned SIDs found." 'OK' }

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\SharePermissions_{0}.html" -f $stamp)

$shareTable = ($shareRows | ForEach-Object {
    $cls = if ($_.Orphaned) { 'orphan' } else { '' }
    "<tr class='$cls'><td>$($_.Share)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Path))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Account))</td><td>$($_.Right)</td><td>$($_.Type)</td></tr>"
}) -join "`n"
$ntfsTable = ($ntfsRows | ForEach-Object {
    $cls = if ($_.Orphaned) { 'orphan' } else { '' }
    "<tr class='$cls'><td>$($_.Share)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Account))</td><td>$($_.Rights)</td><td>$($_.Type)</td><td>$($_.Inherited)</td></tr>"
}) -join "`n"

$html = @"
<html><head><title>Share Permission Report — $ComputerName — $stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%;margin-bottom:2em} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:.9em}
th{background:#f0f0f0} .orphan td{background:#fdecea;color:#c62828}
</style></head><body>
<h1>Share Permission Report — $ComputerName</h1>
<p>$stamp &nbsp; $($shares.Count) share(s) checked &nbsp; Orphaned SIDs: $orphanCount</p>

<h2>Share-level permissions</h2>
<table><tr><th>Share</th><th>Path</th><th>Account</th><th>Right</th><th>Type</th></tr>
$shareTable
</table>

<h2>NTFS permissions</h2>
<table><tr><th>Share</th><th>Account</th><th>Rights</th><th>Type</th><th>Inherited</th></tr>
$ntfsTable
</table>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
