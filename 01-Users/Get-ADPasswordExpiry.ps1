<#
.SYNOPSIS
    Report AD accounts whose passwords are expiring soon (or already expired).

.DESCRIPTION
    Lists enabled users, computes days until their password expires, and flags
    anyone inside a warning window. Writes a sorted HTML report and a CSV, and
    prints a short console summary. Read-only — safe to run any time, ideal as a
    scheduled weekly job so nobody gets locked out on a Monday.

    Accounts with "password never expires" are listed separately so you can
    spot ones that shouldn't have it.

.PARAMETER Days
    Warning window in days (default 14). Anyone expiring within this many days
    is flagged.
.PARAMETER SearchBase
    Optional OU DN to limit the scope.
.PARAMETER OutputPath
    Report folder. Default: the toolkit Reports folder.

.EXAMPLE
    .\Get-ADPasswordExpiry.ps1
.EXAMPLE
    .\Get-ADPasswordExpiry.ps1 -Days 7 -SearchBase 'OU=Staff,DC=contoso,DC=local'

.NOTES
    Needs the AD module (RSAT). Read-only. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding()]
param(
    [int]$Days = 14,
    [string]$SearchBase,
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
if (-not $PSBoundParameters.ContainsKey('Days')) { $__v = Get-ToolkitSetting 'ActiveDirectory.PasswordExpiryWarnDays'; if ($null -ne $__v) { $Days = $__v; $__cfgUsed += 'ActiveDirectory.PasswordExpiryWarnDays' } }
if (-not $PSBoundParameters.ContainsKey('SearchBase')) { $__v = Get-ToolkitSetting 'ActiveDirectory.SearchBase'; if ($null -ne $__v) { $SearchBase = $__v; $__cfgUsed += 'ActiveDirectory.SearchBase' } }
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
Write-Banner "AD Password Expiry Report"

if (-not (Get-Module -ListAvailable ActiveDirectory)) { Write-Log "AD module not found (install RSAT)." 'ERROR'; return }
Import-Module ActiveDirectory -ErrorAction Stop
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

$maxAge = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge
Write-Log "Domain max password age: $($maxAge.Days) days. Warning window: $Days days." 'INFO'

$params = @{
    Filter     = { Enabled -eq $true }
    Properties  = 'PasswordLastSet', 'PasswordNeverExpires', 'msDS-UserPasswordExpiryTimeComputed', 'DisplayName', 'mail'
}
if ($SearchBase) { $params.SearchBase = $SearchBase }

$users = Get-ADUser @params
$now   = Get-Date
$rows  = New-Object System.Collections.Generic.List[object]
$never = New-Object System.Collections.Generic.List[object]

foreach ($u in $users) {
    if ($u.PasswordNeverExpires) {
        $never.Add([pscustomobject]@{ Name=$u.DisplayName; Login=$u.SamAccountName; Mail=$u.mail })
        continue
    }
    $exp = $u.'msDS-UserPasswordExpiryTimeComputed'
    if ($null -eq $exp -or $exp -eq 0) { continue }
    $expDate = [datetime]::FromFileTime([int64]$exp)
    $daysLeft = [math]::Round(($expDate - $now).TotalDays, 0)
    $rows.Add([pscustomobject]@{
        Name       = $u.DisplayName
        Login      = $u.SamAccountName
        Mail       = $u.mail
        Expires    = $expDate.ToString('yyyy-MM-dd')
        DaysLeft   = $daysLeft
        Status     = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -le $Days) { 'Expiring soon' } else { 'OK' }
    })
}

$flagged = $rows | Where-Object { $_.Status -ne 'OK' } | Sort-Object DaysLeft
Write-Log "$($flagged.Count) account(s) expired or expiring within $Days days. $($never.Count) never expire." 'STEP'
$flagged | Select-Object Name, Login, Expires, DaysLeft, Status | Format-Table -AutoSize | Out-Host

# --- HTML --------------------------------------------------------------------
$css = @"
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;color:#0b62c4;border-bottom:2px solid #e6eef7;padding-bottom:4px}
 .sub{color:#6b7280;font-size:12px;margin-bottom:8px}
 table{border-collapse:collapse;width:100%;font-size:13px} th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}
 th{background:#f5f8fc} tr:nth-child(even) td{background:#fafcff}
 .exp{color:#b91c1c;font-weight:600} .soon{color:#b45309;font-weight:600}
</style>
"@
$body = ($flagged | ForEach-Object {
    $cls = if ($_.Status -eq 'EXPIRED') { 'exp' } else { 'soon' }
    "<tr><td>$($_.Name)</td><td>$($_.Login)</td><td>$($_.Mail)</td><td>$($_.Expires)</td><td class='$cls'>$($_.DaysLeft)</td><td class='$cls'>$($_.Status)</td></tr>"
}) -join "`n"
$neverBody = ($never | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Login)</td><td>$($_.Mail)</td></tr>" }) -join "`n"

$html = @"
<!doctype html><html><head><meta charset='utf-8'>$css<title>Password expiry — $(Get-Date -Format yyyy-MM-dd)</title></head><body>
<h1>AD password expiry</h1>
<div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') · warning window $Days days · domain max age $($maxAge.Days) days</div>
<h2>Expired / expiring soon ($($flagged.Count))</h2>
<table><tr><th>Name</th><th>Login</th><th>Mail</th><th>Expires</th><th>Days left</th><th>Status</th></tr>$body</table>
<h2>Password never expires ($($never.Count))</h2>
<table><tr><th>Name</th><th>Login</th><th>Mail</th></tr>$neverBody</table>
</body></html>
"@

$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "PasswordExpiry_$stamp.html"
$csvOut  = Join-Path $OutputPath "PasswordExpiry_$stamp.csv"
$html | Set-Content -Path $htmlOut -Encoding UTF8
$rows | Sort-Object DaysLeft | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Log "HTML: $htmlOut" 'OK'
Write-Log "CSV : $csvOut" 'OK'
try { if ([Environment]::UserInteractive) { Start-Process $htmlOut } } catch { }
