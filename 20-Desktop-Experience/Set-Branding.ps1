<#
.SYNOPSIS
    Company wallpaper + lock screen for every user on the machine, and the
    "Support" info in Settings > System > About (helpdesk phone/hours/URL).
    Backed up, reversible.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit.

    Images are copied to a local folder first (default
    C:\ProgramData\Sysadmin-Toolkit\Branding) so the wallpaper still shows
    when the network share they came from is unreachable.

    Wallpaper and lock screen are applied through the PersonalizationCSP
    registry keys — the same mechanism Intune uses — which works on Windows
    10/11 **Pro** as well as Enterprise/Education (the classic "Force a
    specific lock screen" Group Policy is Enterprise/Education only). Note
    that this method ENFORCES the images: users can't change them while it's
    set. That's usually what a company wants; -Rollback removes it again.

    OEM support info shows up in Settings > System > About and in the old
    System control panel: manufacturer/model text, support phone, hours,
    URL, and an optional logo (120x120 .bmp).

.PARAMETER WallpaperPath
    Image file (.jpg/.png/.bmp), local or UNC.
.PARAMETER LockScreenPath
    Image file for the lock screen. Omit to leave the lock screen alone.
.PARAMETER LocalCopyFolder
    Where to keep the local copies. Default C:\ProgramData\Sysadmin-Toolkit\Branding.
.PARAMETER Manufacturer
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER Model
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER SupportPhone
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER SupportHours
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER SupportURL
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER LogoPath
    OEM info fields. Any you leave out are left unchanged.
.PARAMETER Rollback
    Restore the previous registry state (newest backup set), remove the CSP
    enforcement values, and exit. Copied images are left in place.

.EXAMPLE
    .\Set-Branding.ps1 -WallpaperPath \\fs01\IT\branding\wallpaper.jpg -LockScreenPath \\fs01\IT\branding\lock.jpg -WhatIf
.EXAMPLE
    .\Set-Branding.ps1 -WallpaperPath C:\Branding\wallpaper.jpg -Manufacturer "Contoso IT" -SupportPhone "03 123 45 67" -SupportHours "Mon-Fri 08:00-17:00" -SupportURL "https://helpdesk.contoso.local"
.EXAMPLE
    .\Set-Branding.ps1 -Rollback

.NOTES
    Run as Administrator (machine-wide keys). Users see the change at next
    logon (lock screen) / immediately after Explorer refresh (wallpaper).
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$WallpaperPath,
    [string]$LockScreenPath,
    [string]$LocalCopyFolder = 'C:\ProgramData\Sysadmin-Toolkit\Branding',
    [string]$Manufacturer,
    [string]$Model,
    [string]$SupportPhone,
    [string]$SupportHours,
    [string]$SupportURL,
    [string]$LogoPath,
    [switch]$Rollback
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
if (-not $PSBoundParameters.ContainsKey('WallpaperPath')) { $__v = Get-ToolkitSetting 'Branding.Wallpaper' -File; if ($null -ne $__v) { $WallpaperPath = $__v; $__cfgUsed += 'Branding.Wallpaper' } }
if (-not $PSBoundParameters.ContainsKey('LockScreenPath')) { $__v = Get-ToolkitSetting 'Branding.LockScreen' -File; if ($null -ne $__v) { $LockScreenPath = $__v; $__cfgUsed += 'Branding.LockScreen' } }
if (-not $PSBoundParameters.ContainsKey('LogoPath')) { $__v = Get-ToolkitSetting 'Branding.Logo' -File; if ($null -ne $__v) { $LogoPath = $__v; $__cfgUsed += 'Branding.Logo' } }
if (-not $PSBoundParameters.ContainsKey('Manufacturer')) { $__v = Get-ToolkitSetting 'Company.Name'; if ($null -ne $__v) { $Manufacturer = $__v; $__cfgUsed += 'Company.Name' } }
if (-not $PSBoundParameters.ContainsKey('SupportPhone')) { $__v = Get-ToolkitSetting 'Company.SupportPhone'; if ($null -ne $__v) { $SupportPhone = $__v; $__cfgUsed += 'Company.SupportPhone' } }
if (-not $PSBoundParameters.ContainsKey('SupportHours')) { $__v = Get-ToolkitSetting 'Company.SupportHours'; if ($null -ne $__v) { $SupportHours = $__v; $__cfgUsed += 'Company.SupportHours' } }
if (-not $PSBoundParameters.ContainsKey('SupportURL')) { $__v = Get-ToolkitSetting 'Company.SupportURL'; if ($null -ne $__v) { $SupportURL = $__v; $__cfgUsed += 'Company.SupportURL' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Backups')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}
function Test-Admin {
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}
$script:BackupStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
function Backup-RegistryKey {
    param([Parameter(Mandatory)][string]$Path, [string]$Label = 'key')
    if (-not (Test-Path -LiteralPath "Registry::$Path")) { return $null }
    $tag = (($Path -split '\\' | Select-Object -Last 2) -join '_') -replace '[^\w\-]', '_'
    $out = Join-Path (Get-ToolkitRoot) ("Backups\{0}_{1}_{2}.reg" -f ($Label -replace '[^\w\-]', '_'), $tag, $script:BackupStamp)
    $rc = (Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $Path), ('"{0}"' -f $out), '/y') -Wait -PassThru -WindowStyle Hidden).ExitCode
    if ($rc -eq 0) { Write-Log "Backed up $Path" 'OK'; return $out }
    Write-Log "Could not back up $Path (reg.exe exit $rc)" 'WARN'; return $null
}
function Restore-RegistryBackupSet {
    param([Parameter(Mandatory)][string]$Label)
    $dir = Join-Path (Get-ToolkitRoot) 'Backups'
    $regs = Get-ChildItem $dir -Filter "${Label}_*.reg" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $regs) { Write-Log "No $Label backups found in $dir." 'WARN'; return $false }
    $newest = $regs | Select-Object -First 1
    $stamp = if ($newest.Name -match '_(\d{4}-\d{2}-\d{2}_\d{6})\.reg$') { $Matches[1] } else { '' }
    $set = @($regs | Where-Object { $_.Name -like "*_$stamp.reg" })
    if ($PSCmdlet.ShouldProcess("backup set $stamp ($($set.Count) file(s))", "Re-import")) {
        foreach ($r in $set) { Start-Process -FilePath reg.exe -ArgumentList @('import', ('"{0}"' -f $r.FullName)) -Wait -WindowStyle Hidden | Out-Null }
        Write-Log "Restored $($set.Count) key(s) from backup set $stamp" 'OK'
    }
    return $true
}
function Set-RegValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value,
          [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'Binary')][string]$Type = 'DWord')
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value ($Type)")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log "Set $Path\$Name = $Value" 'OK'
    }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Branding" -ForegroundColor White
Write-Host "  ============================" -ForegroundColor DarkGray

if (-not (Test-Admin)) { Write-Log "Needs Administrator rights (machine-wide keys)." 'ERROR'; return }

$label = 'Branding'
$csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
$oem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'

if ($Rollback) {
    Restore-RegistryBackupSet -Label $label | Out-Null
    # a .reg import can't delete values that didn't exist before -> remove the CSP enforcement explicitly
    if ((Test-Path $csp) -and $PSCmdlet.ShouldProcess($csp, "Remove wallpaper/lock-screen enforcement values")) {
        foreach ($v in 'DesktopImagePath', 'DesktopImageUrl', 'DesktopImageStatus', 'LockScreenImagePath', 'LockScreenImageUrl', 'LockScreenImageStatus') {
            Remove-ItemProperty -Path $csp -Name $v -ErrorAction SilentlyContinue
        }
        Write-Log "Enforcement removed — users can set their own wallpaper/lock screen again." 'OK'
    }
    if (-not $WhatIfPreference) { & RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters 2>$null }
    return
}

if (-not $WallpaperPath -and -not $LockScreenPath -and -not ($Manufacturer -or $Model -or $SupportPhone -or $SupportHours -or $SupportURL -or $LogoPath)) {
    Write-Log "Nothing to do — give -WallpaperPath / -LockScreenPath and/or OEM info fields." 'WARN'; return
}

Write-Log "Backing up registry keys..." 'STEP'
foreach ($k in @('HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation')) {
    Backup-RegistryKey -Path $k -Label $label | Out-Null
}

function Copy-Local {
    param([string]$Source, [string]$NewName)
    if (-not (Test-Path $Source)) { Write-Log "Not found: $Source" 'ERROR'; return $null }
    if (-not (Test-Path $LocalCopyFolder)) { New-Item -ItemType Directory -Path $LocalCopyFolder -Force | Out-Null }
    $dest = Join-Path $LocalCopyFolder ($NewName + [IO.Path]::GetExtension($Source))
    if ($PSCmdlet.ShouldProcess($dest, "Copy $Source")) { Copy-Item $Source $dest -Force }
    return $dest
}

# --- wallpaper ---------------------------------------------------------------------
if ($WallpaperPath) {
    Write-Log "Wallpaper..." 'STEP'
    $local = Copy-Local -Source $WallpaperPath -NewName 'wallpaper'
    if ($local) {
        Set-RegValue -Path $csp -Name 'DesktopImagePath'   -Value $local -Type String
        Set-RegValue -Path $csp -Name 'DesktopImageUrl'    -Value $local -Type String
        Set-RegValue -Path $csp -Name 'DesktopImageStatus' -Value 1
    }
}

# --- lock screen -------------------------------------------------------------------
if ($LockScreenPath) {
    Write-Log "Lock screen..." 'STEP'
    $local = Copy-Local -Source $LockScreenPath -NewName 'lockscreen'
    if ($local) {
        Set-RegValue -Path $csp -Name 'LockScreenImagePath'   -Value $local -Type String
        Set-RegValue -Path $csp -Name 'LockScreenImageUrl'    -Value $local -Type String
        Set-RegValue -Path $csp -Name 'LockScreenImageStatus' -Value 1
    }
}

# --- OEM / support info ------------------------------------------------------------
if ($Manufacturer -or $Model -or $SupportPhone -or $SupportHours -or $SupportURL -or $LogoPath) {
    Write-Log "Support info (Settings > System > About)..." 'STEP'
    if ($Manufacturer) { Set-RegValue -Path $oem -Name 'Manufacturer' -Value $Manufacturer -Type String }
    if ($Model)        { Set-RegValue -Path $oem -Name 'Model'        -Value $Model        -Type String }
    if ($SupportPhone) { Set-RegValue -Path $oem -Name 'SupportPhone' -Value $SupportPhone -Type String }
    if ($SupportHours) { Set-RegValue -Path $oem -Name 'SupportHours' -Value $SupportHours -Type String }
    if ($SupportURL)   { Set-RegValue -Path $oem -Name 'SupportURL'   -Value $SupportURL   -Type String }
    if ($LogoPath) {
        if ($LogoPath -notmatch '\.bmp$') { Write-Log "Logo must be a .bmp (ideally 120x120) — skipped." 'WARN' }
        else { $local = Copy-Local -Source $LogoPath -NewName 'oemlogo'; if ($local) { Set-RegValue -Path $oem -Name 'Logo' -Value $local -Type String } }
    }
}

if (-not $WhatIfPreference) {
    & RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters 2>$null
    Write-Host ''
    Write-Host "  Done. Wallpaper applies on refresh/next logon; lock screen at next lock/logon." -ForegroundColor Green
    Write-Host "  Users can't override enforced images. Undo with:  .\Set-Branding.ps1 -Rollback" -ForegroundColor White
}
