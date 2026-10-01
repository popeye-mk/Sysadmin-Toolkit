<#
.SYNOPSIS
    Onboard a new Active Directory user — the full joiner flow in one command.

.DESCRIPTION
    Creates an AD account, sets a strong temporary password (forced change at
    first logon), adds the user to groups, optionally copies the group
    membership of a "template" colleague, sets common attributes (title,
    department, office, manager), and can create/attach a home drive.

    Read the -WhatIf output first — it prints exactly what it will do without
    touching AD. Requires the ActiveDirectory module (RSAT) and rights to
    create users in the target OU.

.PARAMETER GivenName
    First name.
.PARAMETER Surname
    Last name.
.PARAMETER SamAccountName
    Login name. If omitted, built as first initial + surname, lower-case.
.PARAMETER OU
    Distinguished name of the target OU, e.g. 'OU=Staff,DC=contoso,DC=local'.
.PARAMETER UpnSuffix
    UPN domain, e.g. 'contoso.com'. Defaults to the current AD DNS root.
.PARAMETER Groups
    Groups to add the user to.
.PARAMETER CopyFrom
    SamAccountName of an existing user whose group memberships to copy.
.PARAMETER Title
    Optional directory attributes. Manager takes a SamAccountName.
.PARAMETER Department
    Optional directory attributes. Manager takes a SamAccountName.
.PARAMETER Office
    Optional directory attributes. Manager takes a SamAccountName.
.PARAMETER Manager
    Optional directory attributes. Manager takes a SamAccountName.
.PARAMETER HomeDrivePath
    UNC root for a home folder, e.g. '\\FS01\Home'. A subfolder named after the
    user is created and set as the home directory (drive letter H:).

.EXAMPLE
    .\New-ADUserOnboard.ps1 -GivenName Jan -Surname Peeters -OU 'OU=Staff,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    .\New-ADUserOnboard.ps1 -GivenName Jan -Surname Peeters -OU 'OU=Staff,DC=contoso,DC=local' `
        -CopyFrom mvanden -Department IT -Title "Support Engineer" -HomeDrivePath \\FS01\Home

.NOTES
    Run as Administrator on a machine with RSAT / the AD module.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [string]$SamAccountName,
    [string]$OU,
    [string]$UpnSuffix,
    [string[]]$Groups,
    [string]$CopyFrom,
    [string]$Title,
    [string]$Department,
    [string]$Office,
    [string]$Manager,
    [string]$HomeDrivePath,
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
if (-not $PSBoundParameters.ContainsKey('OU')) { $__v = Get-ToolkitSetting 'ActiveDirectory.NewUserOU'; if ($null -ne $__v) { $OU = $__v; $__cfgUsed += 'ActiveDirectory.NewUserOU' } }
if (-not $PSBoundParameters.ContainsKey('UpnSuffix')) { $__v = Get-ToolkitSetting 'ActiveDirectory.UpnSuffix'; if ($null -ne $__v) { $UpnSuffix = $__v; $__cfgUsed += 'ActiveDirectory.UpnSuffix' } }
if (-not $PSBoundParameters.ContainsKey('Groups')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DefaultGroups'; if ($null -ne $__v) { $Groups = $__v; $__cfgUsed += 'ActiveDirectory.DefaultGroups' } }
if (-not $PSBoundParameters.ContainsKey('HomeDrivePath')) { $__v = Get-ToolkitSetting 'ActiveDirectory.HomeDriveRoot'; if ($null -ne $__v) { $HomeDrivePath = $__v; $__cfgUsed += 'ActiveDirectory.HomeDriveRoot' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $OU) { Write-Host "  [ERROR] Missing: -OU <distinguished name> (or ActiveDirectory.NewUserOU in Config)" -ForegroundColor Red; return }


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
Write-Banner "New AD User Onboard"

if (-not (Assert-Admin)) { return }
if (-not (Get-Module -ListAvailable ActiveDirectory)) {
    Write-Log "ActiveDirectory module not found. Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" 'ERROR'
    return
}
Import-Module ActiveDirectory -ErrorAction Stop

# --- derive names ------------------------------------------------------------
if (-not $SamAccountName) {
    $SamAccountName = ("{0}{1}" -f $GivenName.Substring(0, 1), $Surname).ToLower() -replace '[^a-z0-9]', ''
}
if (-not $UpnSuffix) {
    try { $UpnSuffix = (Get-ADDomain).DNSRoot } catch { Write-Log "Could not read domain DNS root; pass -UpnSuffix." 'ERROR'; return }
}
$displayName = "$GivenName $Surname"
$upn         = "$SamAccountName@$UpnSuffix"

if (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue) {
    Write-Log "An account '$SamAccountName' already exists. Choose a different -SamAccountName." 'ERROR'
    return
}

$tempPw = New-StrongPassword -Length 16
$secPw  = ConvertTo-SecureString $tempPw -AsPlainText -Force

Write-Log "User        : $displayName ($SamAccountName)" 'INFO'
Write-Log "UPN         : $upn" 'INFO'
Write-Log "Target OU   : $OU" 'INFO'
if ($CopyFrom) { Write-Log "Copy groups : from $CopyFrom" 'INFO' }

# --- create ------------------------------------------------------------------
$newParams = @{
    Name                  = $displayName
    GivenName             = $GivenName
    Surname               = $Surname
    SamAccountName        = $SamAccountName
    UserPrincipalName     = $upn
    DisplayName           = $displayName
    Path                  = $OU
    AccountPassword       = $secPw
    Enabled               = $true
    ChangePasswordAtLogon = $true
}
if ($Title)      { $newParams.Title      = $Title }
if ($Department) { $newParams.Department = $Department }
if ($Office)     { $newParams.Office     = $Office }

if ($PSCmdlet.ShouldProcess($displayName, "Create AD user in $OU")) {
    try {
        New-ADUser @newParams -ErrorAction Stop
        Write-Log "Account created." 'OK'
    } catch {
        Write-Log "Create failed: $($_.Exception.Message)" 'ERROR'
        return
    }
}

# --- manager -----------------------------------------------------------------
if ($Manager -and $PSCmdlet.ShouldProcess($SamAccountName, "Set manager to $Manager")) {
    try { Set-ADUser -Identity $SamAccountName -Manager $Manager -ErrorAction Stop; Write-Log "Manager set." 'OK' }
    catch { Write-Log "Could not set manager: $($_.Exception.Message)" 'WARN' }
}

# --- groups (explicit + copied) ---------------------------------------------
$allGroups = [System.Collections.Generic.HashSet[string]]::new()
if ($Groups) { $Groups | ForEach-Object { [void]$allGroups.Add($_) } }
if ($CopyFrom) {
    try {
        (Get-ADPrincipalGroupMembership -Identity $CopyFrom | Where-Object Name -ne 'Domain Users').Name |
            ForEach-Object { [void]$allGroups.Add($_) }
    } catch { Write-Log "Could not read groups from ${CopyFrom}: $($_.Exception.Message)" 'WARN' }
}
foreach ($g in $allGroups) {
    if ($PSCmdlet.ShouldProcess($SamAccountName, "Add to group $g")) {
        try { Add-ADGroupMember -Identity $g -Members $SamAccountName -ErrorAction Stop; Write-Log "Added to $g" 'OK' }
        catch { Write-Log "Group '$g' failed: $($_.Exception.Message)" 'WARN' }
    }
}

# --- home drive --------------------------------------------------------------
if ($HomeDrivePath) {
    $homeDir = Join-Path $HomeDrivePath $SamAccountName
    if ($PSCmdlet.ShouldProcess($homeDir, "Create home folder + set H:")) {
        try {
            if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir -Force | Out-Null }
            Set-ADUser -Identity $SamAccountName -HomeDrive 'H:' -HomeDirectory $homeDir -ErrorAction Stop
            Write-Log "Home drive H: -> $homeDir" 'OK'
        } catch { Write-Log "Home drive setup failed: $($_.Exception.Message)" 'WARN' }
    }
}

# --- summary -----------------------------------------------------------------
if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Onboarding complete." -ForegroundColor Green
    Write-Host "  Login    : $SamAccountName" -ForegroundColor White
    Write-Host "  UPN      : $upn" -ForegroundColor White
    Write-Host "  Temp pw  : $tempPw" -ForegroundColor Yellow
    Write-Host "  (User must change it at first logon. Share it securely, not by e-mail.)" -ForegroundColor DarkYellow
    Write-Log "Onboarded $SamAccountName" 'OK'
}
