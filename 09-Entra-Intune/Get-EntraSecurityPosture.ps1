<#
.SYNOPSIS
    Snapshot of Conditional Access policies and who currently holds
    privileged Entra roles — the kind of thing worth reviewing regularly,
    not just at audit time.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Two
    independent halves in one report:
      1. Every Conditional Access policy and its state (enabled /
         disabled / report-only) — a disabled or report-only policy you
         forgot about is the same as no policy at all.
      2. Current holders of a curated list of high-privilege Entra roles
         (Global Administrator, Privileged Role Administrator, Security
         Administrator, User Administrator, Exchange Administrator,
         SharePoint Administrator, Application Administrator, Cloud
         Application Administrator) — the accounts that, if compromised,
         cause the worst day.

.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.
.PARAMETER AdditionalRoles
    Extra role display names to include beyond the built-in high-privilege
    list (exact Entra role display name, e.g. 'Intune Administrator').

.EXAMPLE
    .\Get-EntraSecurityPosture.ps1
.EXAMPLE
    .\Get-EntraSecurityPosture.ps1 -AdditionalRoles 'Intune Administrator','Compliance Administrator'

.NOTES
    Requires Microsoft.Graph.Identity.SignIns (Conditional Access) and
    Microsoft.Graph.Identity.DirectoryManagement (roles), with Policy.Read.All
    and RoleManagement.Read.Directory. This reports STANDING (permanent) role
    assignments via the classic directory role API — it does NOT show
    time-bound Privileged Identity Management (PIM) eligible/active
    assignments, which need a different, P2-licensed API
    (roleManagementPolicyAssignments / PIM). If your tenant uses PIM for
    these roles, treat a "no standing holders" result here as a good sign
    (least privilege), not as "nobody has this role" — check PIM directly for
    the full picture. Read-only. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string[]]$AdditionalRoles
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
function Connect-ToolkitGraphStandalone {
    param([string[]]$Scopes)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'
        return $false
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru -ErrorAction SilentlyContinue | Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) { return $true }
    try { Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null; return $true }
    catch { Write-Log "Graph connect failed: $($_.Exception.Message)" 'ERROR'; return $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Entra Security Posture" -ForegroundColor White
Write-Host "  ============================================" -ForegroundColor DarkGray

$scopes = @('Policy.Read.All', 'RoleManagement.Read.Directory', 'Directory.Read.All')
if (-not (Connect-ToolkitGraphStandalone -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

# --- 1. Conditional Access policies ------------------------------------------------
Write-Log "Fetching Conditional Access policies..." 'STEP'
$caRows = @()
try {
    $policies = @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop)
    $caRows = $policies | ForEach-Object {
        [pscustomobject]@{ Name = $_.DisplayName; State = $_.State; Created = $_.CreatedDateTime; Modified = $_.ModifiedDateTime }
    }
    Write-Log "$($caRows.Count) Conditional Access policy(ies)." 'INFO'
} catch {
    Write-Log "Could not fetch Conditional Access policies: $($_.Exception.Message)" 'WARN'
}
$caDisabled = @($caRows | Where-Object { $_.State -ne 'enabled' })

# --- 2. privileged role holders ------------------------------------------------------
$highPrivRoles = @(
    'Global Administrator', 'Privileged Role Administrator', 'Security Administrator',
    'User Administrator', 'Exchange Administrator', 'SharePoint Administrator',
    'Application Administrator', 'Cloud Application Administrator'
)
if ($AdditionalRoles) { $highPrivRoles = @($highPrivRoles + $AdditionalRoles | Select-Object -Unique) }

Write-Log "Fetching privileged role assignments (standing/permanent only — see .NOTES re: PIM)..." 'STEP'
$roleRows = New-Object System.Collections.Generic.List[pscustomobject]
try {
    $allRoles = @(Get-MgDirectoryRole -All -ErrorAction Stop)
    foreach ($roleName in $highPrivRoles) {
        $role = $allRoles | Where-Object { $_.DisplayName -eq $roleName }
        if (-not $role) { Write-Log "  '$roleName' — not activated in this tenant (or role template not yet instantiated), skipping." 'INFO'; continue }
        try {
            $members = @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop)
            if (-not $members.Count) {
                $roleRows.Add([pscustomobject]@{ Role = $roleName; Member = '(none)'; Type = '' })
            } else {
                foreach ($m in $members) {
                    $display = $m.AdditionalProperties.displayName
                    if (-not $display) { $display = $m.AdditionalProperties.appDisplayName }
                    if (-not $display) { $display = $m.Id }
                    $type = $m.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', ''
                    $roleRows.Add([pscustomobject]@{ Role = $roleName; Member = $display; Type = $type })
                }
            }
        } catch { Write-Log "  Could not fetch members of '$roleName': $($_.Exception.Message)" 'WARN' }
    }
} catch {
    Write-Log "Could not fetch directory roles: $($_.Exception.Message)" 'WARN'
}

$totalMembers = @($roleRows | Where-Object { $_.Member -ne '(none)' }).Count

Write-Host ''
Write-Host "  Conditional Access: $($caRows.Count) polic(y/ies), $($caDisabled.Count) not enabled" -ForegroundColor $(if ($caDisabled.Count) { 'Yellow' } else { 'Green' })
Write-Host "  Privileged roles: $totalMembers standing assignment(s) across $($highPrivRoles.Count) role(s) checked" -ForegroundColor White

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\EntraSecurityPosture_{0}.html" -f $stamp)
$caTable = ($caRows | Sort-Object @{e={$_.State -ne 'enabled'}} -Descending | ForEach-Object {
    $cls = if ($_.State -ne 'enabled') { 'flagged' } else { '' }
    "<tr class='$cls'><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.State)</td><td>$($_.Modified)</td></tr>"
}) -join "`n"
$roleTable = ($roleRows | Sort-Object Role, Member | ForEach-Object {
    "<tr><td>$($_.Role)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Member))</td><td>$($_.Type)</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>Entra Security Posture — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%;margin-bottom:2em} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:.9em}
th{background:#f0f0f0} .flagged td{background:#fff8e1;color:#8a6d00}</style>
</head><body>
<h1>Entra Security Posture</h1>
<p>$stamp</p>

<h2>Conditional Access policies</h2>
<table><tr><th>Name</th><th>State</th><th>Last modified</th></tr>
$caTable
</table>

<h2>Privileged role holders (standing assignments)</h2>
<p style="color:#6b7280;font-size:12px">Does not include PIM eligible/time-bound assignments — see script .NOTES.</p>
<table><tr><th>Role</th><th>Member</th><th>Type</th></tr>
$roleTable
</table>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
