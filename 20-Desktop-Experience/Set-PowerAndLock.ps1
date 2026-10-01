<#
.SYNOPSIS
    Work-PC power and lock behaviour: screen off / sleep timers, lock the
    screen after N minutes, lid and power-button actions, Fast Startup and
    hibernation. Backed up, reversible.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Before
    changing anything it exports the active power scheme to a .pow file and
    the relevant registry keys to .reg (one set per run); -Rollback re-imports
    both. Everything honours -WhatIf.

    Why these defaults:
      - Lock after 10 minutes idle: the single most common security-baseline
        requirement, and the one most often forgotten on new PCs.
      - Fast Startup OFF: "reboot" then behaves like a real reboot, so
        "have you tried turning it off and on again" actually works, and
        GPO/updates that need a full shutdown apply.
      - Hibernation OFF on desktops (frees hiberfil.sys); leave it on laptops.

.PARAMETER Plan
    Balanced or HighPerformance (default: leave as is).
.PARAMETER ScreenOffMinutesAC
    Turn off display after N minutes on mains / battery (0 = never).
.PARAMETER ScreenOffMinutesDC
    Turn off display after N minutes on mains / battery (0 = never).
.PARAMETER SleepMinutesAC
    Sleep after N minutes on mains / battery (0 = never).
.PARAMETER SleepMinutesDC
    Sleep after N minutes on mains / battery (0 = never).
.PARAMETER LockAfterMinutes
    Require sign-in after N idle minutes (screen-saver lock, all editions).
    0 = don't change.
.PARAMETER LidAction
    DoNothing, Sleep, Hibernate, ShutDown. Default: leave as is.
.PARAMETER PowerButtonAction
    DoNothing, Sleep, Hibernate, ShutDown. Default: leave as is.
.PARAMETER DisableFastStartup
    Turn Fast Startup off (a "reboot" then really reboots). Recommended on work PCs.
.PARAMETER EnableFastStartup
    Turn Fast Startup back on.
.PARAMETER DisableHibernate
    Turn hibernation off and free hiberfil.sys (desktops).
.PARAMETER EnableHibernate
    Turn hibernation on (laptops).
.PARAMETER Workstation
    Sensible desktop preset: Balanced, screen off 15 min, no sleep on AC,
    lock after 10 min, Fast Startup off, hibernate off.
.PARAMETER Laptop
    Sensible laptop preset: Balanced, screen off 10/5 min, sleep 30/15 min,
    lock after 10 min, lid = Sleep, Fast Startup off, hibernate kept.
.PARAMETER Rollback
    Restore the newest backup (power scheme + registry) and exit.

.EXAMPLE
    .\Set-PowerAndLock.ps1 -Workstation -WhatIf
.EXAMPLE
    .\Set-PowerAndLock.ps1 -Laptop
.EXAMPLE
    .\Set-PowerAndLock.ps1 -LockAfterMinutes 5 -ScreenOffMinutesAC 10
.EXAMPLE
    .\Set-PowerAndLock.ps1 -Rollback

.NOTES
    Run as Administrator (powercfg changes are machine-wide; the lock timer
    is per-user and applies to the user running it — or push it by GPO for
    everyone). Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Balanced', 'HighPerformance', 'Skip')][string]$Plan = 'Skip',
    [int]$ScreenOffMinutesAC = -1,
    [int]$ScreenOffMinutesDC = -1,
    [int]$SleepMinutesAC = -1,
    [int]$SleepMinutesDC = -1,
    [int]$LockAfterMinutes = 0,
    [ValidateSet('DoNothing', 'Sleep', 'Hibernate', 'ShutDown', 'Skip')][string]$LidAction = 'Skip',
    [ValidateSet('DoNothing', 'Sleep', 'Hibernate', 'ShutDown', 'Skip')][string]$PowerButtonAction = 'Skip',
    [switch]$DisableFastStartup,
    [switch]$EnableFastStartup,
    [switch]$DisableHibernate,
    [switch]$EnableHibernate,
    [switch]$Workstation,
    [switch]$Laptop,
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
if (-not $PSBoundParameters.ContainsKey('Plan')) { $__v = Get-ToolkitSetting 'Power.Plan'; if ($null -ne $__v) { $Plan = $__v; $__cfgUsed += 'Power.Plan' } }
if (-not $PSBoundParameters.ContainsKey('ScreenOffMinutesAC')) { $__v = Get-ToolkitSetting 'Power.ScreenOffMinutesAC'; if ($null -ne $__v) { $ScreenOffMinutesAC = $__v; $__cfgUsed += 'Power.ScreenOffMinutesAC' } }
if (-not $PSBoundParameters.ContainsKey('ScreenOffMinutesDC')) { $__v = Get-ToolkitSetting 'Power.ScreenOffMinutesDC'; if ($null -ne $__v) { $ScreenOffMinutesDC = $__v; $__cfgUsed += 'Power.ScreenOffMinutesDC' } }
if (-not $PSBoundParameters.ContainsKey('SleepMinutesAC')) { $__v = Get-ToolkitSetting 'Power.SleepMinutesAC'; if ($null -ne $__v) { $SleepMinutesAC = $__v; $__cfgUsed += 'Power.SleepMinutesAC' } }
if (-not $PSBoundParameters.ContainsKey('SleepMinutesDC')) { $__v = Get-ToolkitSetting 'Power.SleepMinutesDC'; if ($null -ne $__v) { $SleepMinutesDC = $__v; $__cfgUsed += 'Power.SleepMinutesDC' } }
if (-not $PSBoundParameters.ContainsKey('LockAfterMinutes')) { $__v = Get-ToolkitSetting 'Power.LockAfterMinutes'; if ($null -ne $__v) { $LockAfterMinutes = $__v; $__cfgUsed += 'Power.LockAfterMinutes' } }
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
Write-Host "  Sysadmin-Toolkit :: Power & Lock" -ForegroundColor White
Write-Host "  ================================" -ForegroundColor DarkGray

if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) { Write-Log "powercfg.exe not found — this needs Windows." 'ERROR'; return }
if (-not (Test-Admin)) { Write-Log "Needs Administrator rights (power settings are machine-wide)." 'ERROR'; return }

$label = 'PowerAndLock'
$backupDir = Join-Path (Get-ToolkitRoot) 'Backups'
$activeGuid = if ((& powercfg.exe /getactivescheme) -match '([0-9a-f\-]{36})') { $Matches[1] } else { $null }

# --- rollback ------------------------------------------------------------------------
if ($Rollback) {
    $pow = Get-ChildItem $backupDir -Filter 'PowerAndLock_scheme_*.pow' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($pow) {
        $stamp = if ($pow.Name -match '_(\d{4}-\d{2}-\d{2}_\d{6})\.pow$') { $Matches[1] } else { '' }
        if ($PSCmdlet.ShouldProcess($pow.Name, "Re-import power scheme and make it active")) {
            $newGuid = [guid]::NewGuid().ToString()
            & powercfg.exe /import $pow.FullName $newGuid | Out-Null
            & powercfg.exe /setactive $newGuid | Out-Null
            Write-Log "Power scheme restored from $($pow.Name) (as a new scheme, now active)." 'OK'
        }
        $regs = Get-ChildItem $backupDir -Filter "${label}_*_$stamp.reg" -ErrorAction SilentlyContinue
        foreach ($r in $regs) { if ($PSCmdlet.ShouldProcess($r.Name, "Re-import")) { Start-Process -FilePath reg.exe -ArgumentList @('import', ('"{0}"' -f $r.FullName)) -Wait -WindowStyle Hidden | Out-Null } }
        if ($regs) { Write-Log "Restored $(@($regs).Count) registry key(s)." 'OK' }
    } else { Write-Log "No PowerAndLock backup found in $backupDir." 'WARN' }
    return
}

# --- presets -------------------------------------------------------------------------
if ($Workstation) {
    if ($Plan -eq 'Skip') { $Plan = 'Balanced' }
    if ($ScreenOffMinutesAC -lt 0) { $ScreenOffMinutesAC = 15 }
    if ($SleepMinutesAC -lt 0) { $SleepMinutesAC = 0 }
    if ($LockAfterMinutes -eq 0) { $LockAfterMinutes = 10 }
    $DisableFastStartup = $true; $DisableHibernate = $true
}
if ($Laptop) {
    if ($Plan -eq 'Skip') { $Plan = 'Balanced' }
    if ($ScreenOffMinutesAC -lt 0) { $ScreenOffMinutesAC = 10 }
    if ($ScreenOffMinutesDC -lt 0) { $ScreenOffMinutesDC = 5 }
    if ($SleepMinutesAC -lt 0) { $SleepMinutesAC = 30 }
    if ($SleepMinutesDC -lt 0) { $SleepMinutesDC = 15 }
    if ($LockAfterMinutes -eq 0) { $LockAfterMinutes = 10 }
    if ($LidAction -eq 'Skip') { $LidAction = 'Sleep' }
    $DisableFastStartup = $true
}
$anything = ($Plan -ne 'Skip') -or ($ScreenOffMinutesAC -ge 0) -or ($ScreenOffMinutesDC -ge 0) -or ($SleepMinutesAC -ge 0) -or ($SleepMinutesDC -ge 0) -or
            ($LockAfterMinutes -gt 0) -or ($LidAction -ne 'Skip') -or ($PowerButtonAction -ne 'Skip') -or $DisableFastStartup -or $EnableFastStartup -or $DisableHibernate -or $EnableHibernate
if (-not $anything) { Write-Log "Nothing selected — use -Workstation, -Laptop, or individual parameters." 'WARN'; return }

# --- backup ----------------------------------------------------------------------------
Write-Log "Backing up active power scheme + registry keys..." 'STEP'
if ($activeGuid) {
    $powOut = Join-Path $backupDir "PowerAndLock_scheme_$script:BackupStamp.pow"
    if ($PSCmdlet.ShouldProcess($powOut, "Export active power scheme")) { & powercfg.exe /export $powOut $activeGuid | Out-Null; Write-Log "Scheme exported: $powOut" 'OK' }
}
foreach ($k in @('HKCU\Control Panel\Desktop', 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power')) { Backup-RegistryKey -Path $k -Label $label | Out-Null }

# --- plan ------------------------------------------------------------------------------
if ($Plan -ne 'Skip') {
    $guid = @{ Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'; HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }[$Plan]
    if ($PSCmdlet.ShouldProcess("power plan", "Set active: $Plan")) {
        & powercfg.exe /setactive $guid 2>$null
        if ($LASTEXITCODE -ne 0 -and $Plan -eq 'HighPerformance') { & powercfg.exe -duplicatescheme $guid | Out-Null; & powercfg.exe /setactive $guid | Out-Null }   # hidden on some laptops
        Write-Log "Power plan: $Plan" 'OK'
    }
}

# --- timers (minutes; powercfg wants minutes for these aliases) -------------------------------
function Set-Timer { param([string]$What, [string]$Sub, [string]$Setting, [int]$AC, [int]$DC)
    if ($AC -ge 0 -and $PSCmdlet.ShouldProcess($What, "AC -> $AC min")) { & powercfg.exe /change $Setting-ac $AC | Out-Null; Write-Log "$What on AC: $AC min" 'OK' }
    if ($DC -ge 0 -and $PSCmdlet.ShouldProcess($What, "DC -> $DC min")) { & powercfg.exe /change $Setting-dc $DC | Out-Null; Write-Log "$What on battery: $DC min" 'OK' }
}
Set-Timer -What 'Screen off' -Sub 'SUB_VIDEO' -Setting 'monitor-timeout' -AC $ScreenOffMinutesAC -DC $ScreenOffMinutesDC
Set-Timer -What 'Sleep'      -Sub 'SUB_SLEEP' -Setting 'standby-timeout' -AC $SleepMinutesAC      -DC $SleepMinutesDC

# --- lid / power button ----------------------------------------------------------------------
$actionIdx = @{ DoNothing = 0; Sleep = 1; Hibernate = 2; ShutDown = 3 }
if ($LidAction -ne 'Skip' -and $PSCmdlet.ShouldProcess("lid close", $LidAction)) {
    foreach ($src in 'setacvalueindex', 'setdcvalueindex') { & powercfg.exe /$src SCHEME_CURRENT SUB_BUTTONS LIDACTION $actionIdx[$LidAction] | Out-Null }
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null; Write-Log "Lid close: $LidAction" 'OK'
}
if ($PowerButtonAction -ne 'Skip' -and $PSCmdlet.ShouldProcess("power button", $PowerButtonAction)) {
    foreach ($src in 'setacvalueindex', 'setdcvalueindex') { & powercfg.exe /$src SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION $actionIdx[$PowerButtonAction] | Out-Null }
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null; Write-Log "Power button: $PowerButtonAction" 'OK'
}

# --- lock after idle (screen-saver lock: works on every edition, no GPO needed) -----------------
if ($LockAfterMinutes -gt 0) {
    $desk = 'HKCU:\Control Panel\Desktop'
    Set-RegValue -Path $desk -Name 'ScreenSaveActive'   -Value '1' -Type String
    Set-RegValue -Path $desk -Name 'ScreenSaverIsSecure' -Value '1' -Type String
    Set-RegValue -Path $desk -Name 'ScreenSaveTimeOut'  -Value ([string]($LockAfterMinutes * 60)) -Type String
    if (-not (Get-ItemProperty $desk -Name 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue)) {
        Set-RegValue -Path $desk -Name 'SCRNSAVE.EXE' -Value "$env:SystemRoot\System32\scrnsave.scr" -Type String   # blank screen saver, just to carry the lock
    }
    Write-Log "Lock after $LockAfterMinutes min idle (this user)." 'OK'
}

# --- fast startup / hibernate -----------------------------------------------------------------
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
if ($DisableFastStartup) { Set-RegValue -Path $powerKey -Name 'HiberbootEnabled' -Value 0 }
if ($EnableFastStartup)  { Set-RegValue -Path $powerKey -Name 'HiberbootEnabled' -Value 1 }
if ($DisableHibernate -and $PSCmdlet.ShouldProcess("hibernation", "Off (removes hiberfil.sys; also disables Fast Startup)")) { & powercfg.exe /hibernate off; Write-Log "Hibernation off." 'OK' }
if ($EnableHibernate  -and $PSCmdlet.ShouldProcess("hibernation", "On")) { & powercfg.exe /hibernate on; Write-Log "Hibernation on." 'OK' }

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Undo with:  .\Set-PowerAndLock.ps1 -Rollback" -ForegroundColor Green
}
