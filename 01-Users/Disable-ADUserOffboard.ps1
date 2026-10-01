<#
.SYNOPSIS
    Offboard an AD user — the leaver flow, safely (disable, never delete).

.DESCRIPTION
    Best-practice departure handling:
      1. Disables the account.
      2. Resets the password to a random value (kills any live session token use).
      3. Records every group it removes into a text file first, then strips the
         user from all groups except 'Domain Users'.
      4. Moves the account to a "Disabled Users" OU if you supply one.
      5. Stamps the description with who/when.
      6. Optionally hides the mailbox from the address book (on-prem Exchange).

    The removed-groups file is your restore path if someone comes back or if a
    manager says "wait, they need access again". Nothing is deleted.

.PARAMETER SamAccountName
    The leaver's login name.
.PARAMETER DisabledOU
    Optional DN to move the account into, e.g. 'OU=Disabled,DC=contoso,DC=local'.
.PARAMETER Reason
    Free text stamped into the description (default 'Offboarded').
.PARAMETER HideFromGAL
    Switch: set msExchHideFromAddressLists (needs the attribute / Exchange).

.EXAMPLE
    .\Disable-ADUserOffboard.ps1 -SamAccountName jpeeters -WhatIf
.EXAMPLE
    .\Disable-ADUserOffboard.ps1 -SamAccountName jpeeters -DisabledOU 'OU=Disabled,DC=contoso,DC=local' -Reason "Left 2026-09-30"

.NOTES
    Run as Administrator with the AD module. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SamAccountName,
    [string]$DisabledOU,
    [string]$Reason = 'Offboarded',
    [switch]$HideFromGAL,
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
if (-not $PSBoundParameters.ContainsKey('DisabledOU')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DisabledOU'; if ($null -ne $__v) { $DisabledOU = $__v; $__cfgUsed += 'ActiveDirectory.DisabledOU' } }
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
Write-Banner "AD User Offboard"

if (-not (Assert-Admin)) { return }
if (-not (Get-Module -ListAvailable ActiveDirectory)) {
    Write-Log "ActiveDirectory module not found (install RSAT)." 'ERROR'; return
}
Import-Module ActiveDirectory -ErrorAction Stop

$user = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -Properties MemberOf, Description -ErrorAction SilentlyContinue
if (-not $user) { Write-Log "No account '$SamAccountName' found." 'ERROR'; return }

Write-Log "Offboarding: $($user.Name) ($SamAccountName)" 'STEP'

# --- 1. record group memberships before touching anything --------------------
$root   = Get-ToolkitRoot
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$grpLog = Join-Path $root ("Backups\Groups_{0}_{1}.txt" -f $SamAccountName, $stamp)
$groups = @($user.MemberOf)
if ($groups.Count) {
    if ($PSCmdlet.ShouldProcess($grpLog, "Save current group list")) {
        $groups | Out-File -FilePath $grpLog -Encoding UTF8
        Write-Log "Saved $($groups.Count) group memberships -> $grpLog" 'OK'
    }
} else { Write-Log "User has no extra group memberships." 'INFO' }

# --- 2. disable --------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($SamAccountName, "Disable account")) {
    Disable-ADAccount -Identity $SamAccountName
    Write-Log "Account disabled." 'OK'
}

# --- 3. randomize password ---------------------------------------------------
if ($PSCmdlet.ShouldProcess($SamAccountName, "Reset password to random")) {
    $sec = ConvertTo-SecureString (New-StrongPassword -Length 24) -AsPlainText -Force
    Set-ADAccountPassword -Identity $SamAccountName -NewPassword $sec -Reset
    Write-Log "Password reset to random (not recorded)." 'OK'
}

# --- 4. strip groups ---------------------------------------------------------
foreach ($g in $groups) {
    $gname = ($g -split ',')[0] -replace '^CN='
    if ($gname -eq 'Domain Users') { continue }
    if ($PSCmdlet.ShouldProcess($SamAccountName, "Remove from $gname")) {
        try { Remove-ADGroupMember -Identity $g -Members $SamAccountName -Confirm:$false -ErrorAction Stop; Write-Log "Removed from $gname" 'OK' }
        catch { Write-Log "Could not remove from ${gname}: $($_.Exception.Message)" 'WARN' }
    }
}

# --- 5. stamp description ----------------------------------------------------
$note = "$Reason by $env:USERNAME on $(Get-Date -Format 'yyyy-MM-dd')"
if ($PSCmdlet.ShouldProcess($SamAccountName, "Set description")) {
    Set-ADUser -Identity $SamAccountName -Description $note
    Write-Log "Description: $note" 'OK'
}

# --- 6. hide from GAL --------------------------------------------------------
if ($HideFromGAL -and $PSCmdlet.ShouldProcess($SamAccountName, "Hide from address book")) {
    try { Set-ADUser -Identity $SamAccountName -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop; Write-Log "Hidden from GAL." 'OK' }
    catch { Write-Log "Could not set GAL flag (attribute/Exchange missing): $($_.Exception.Message)" 'WARN' }
}

# --- 7. move OU --------------------------------------------------------------
if ($DisabledOU -and $PSCmdlet.ShouldProcess($SamAccountName, "Move to $DisabledOU")) {
    try { Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU -ErrorAction Stop; Write-Log "Moved to $DisabledOU" 'OK' }
    catch { Write-Log "Move failed: $($_.Exception.Message)" 'WARN' }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Offboarding complete for $SamAccountName." -ForegroundColor Green
    Write-Host "  Group list saved to: $grpLog" -ForegroundColor White
    Write-Log "Offboarded $SamAccountName" 'OK'
}
