<#
.SYNOPSIS
    Make a PC look and feel like a proper work PC — theme, desktop icons,
    icon size, Explorer view, Quick Access pins, tips/ads off. Per-user,
    backed up, reversible.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Every
    registry key it touches is exported to a .reg first (one file per key,
    one set per run), and -Rollback re-imports the newest complete set.
    Everything honours -WhatIf.

    Pick what you want with switches, or -All for the sensible work-PC
    default. Taskbar layout (alignment, search box, widgets) is deliberately
    NOT here — that's already in 02-Windows11\Set-Win11Baseline.ps1 and
    03-Windows10\Set-Win10Baseline.ps1; run those alongside.

.PARAMETER Theme
    Dark, Light, or Skip (default Skip = leave as is). Sets both app and
    system theme.
.PARAMETER DesktopIcons
    Show the classic desktop icons: This PC, user folder, Network, Recycle
    Bin (Control Panel too with -IncludeControlPanel).
.PARAMETER IncludeControlPanel
    With -DesktopIcons: also show the Control Panel icon on the desktop.
.PARAMETER IconSize
    Desktop icon size: Small, Medium (default Windows), Large.
.PARAMETER ExplorerView
    File extensions shown, hidden files shown, Explorer opens to This PC,
    compact view (Win11), no OneDrive/sync-provider ads in Explorer.
.PARAMETER QuickAccessPins
    Folder paths (local or UNC) to pin to Quick Access — e.g. the department
    share. Skipped silently if a path isn't reachable right now.
.PARAMETER DisableTips
    Turn off Windows tips, welcome experience, Start suggestions, and
    "Get even more out of Windows" nags.
.PARAMETER All
    = -Theme Dark -DesktopIcons -ExplorerView -DisableTips (icon size and
    Quick Access left as they are).
.PARAMETER NoExplorerRestart
    Don't restart Explorer at the end (changes then show after next logon).
.PARAMETER Rollback
    Restore the newest backup set and exit.

.EXAMPLE
    .\Set-DesktopExperience.ps1 -All -WhatIf
.EXAMPLE
    .\Set-DesktopExperience.ps1 -Theme Dark -DesktopIcons -ExplorerView -QuickAccessPins '\\fs01\Shared','\\fs01\Projects'
.EXAMPLE
    .\Set-DesktopExperience.ps1 -Rollback

.NOTES
    Runs as the user whose desktop you're setting up (no admin needed).
    Backups: C:\Sysadmin-Toolkit\Backups\DesktopExperience_<key>_<stamp>.reg.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Dark', 'Light', 'Skip')][string]$Theme = 'Skip',
    [switch]$DesktopIcons,
    [switch]$IncludeControlPanel,
    [ValidateSet('Small', 'Medium', 'Large', 'Skip')][string]$IconSize = 'Skip',
    [switch]$ExplorerView,
    [string[]]$QuickAccessPins,
    [switch]$DisableTips,
    [switch]$All,
    [switch]$NoExplorerRestart,
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
if (-not $PSBoundParameters.ContainsKey('Theme')) { $__v = Get-ToolkitSetting 'Desktop.Theme'; if ($null -ne $__v) { $Theme = $__v; $__cfgUsed += 'Desktop.Theme' } }
if (-not $PSBoundParameters.ContainsKey('IconSize')) { $__v = Get-ToolkitSetting 'Desktop.IconSize'; if ($null -ne $__v) { $IconSize = $__v; $__cfgUsed += 'Desktop.IconSize' } }
if (-not $PSBoundParameters.ContainsKey('QuickAccessPins')) { $__v = Get-ToolkitSetting 'Shares.QuickAccessPins'; if ($null -ne $__v) { $QuickAccessPins = $__v; $__cfgUsed += 'Shares.QuickAccessPins' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- standalone-safe helpers ---------------------------------------------------
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
$script:BackupStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
function Backup-RegistryKey {
    # one file per key, all files of one run share a stamp -> Restore-RegistryBackupSet restores the whole run
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
Write-Host "  Sysadmin-Toolkit :: Desktop Experience" -ForegroundColor White
Write-Host "  =======================================" -ForegroundColor DarkGray

$label = 'DesktopExperience'
if ($Rollback) {
    if (Restore-RegistryBackupSet -Label $label) {
        if (-not $NoExplorerRestart -and -not $WhatIfPreference) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Write-Log "Explorer restarted. Rollback done." 'OK' }
    }
    return
}

if ($Theme -eq 'Skip' -and -not $DesktopIcons -and $IconSize -eq 'Skip' -and -not $ExplorerView -and -not $QuickAccessPins -and -not $DisableTips) {
    if ([Environment]::UserInteractive -and $null -ne $Host.UI.RawUI) {
        Write-Host ''
        Write-Host "  Nothing selected. The default work-PC set (-All) is:" -ForegroundColor White
        Write-Host "    dark theme, classic desktop icons, Explorer view (extensions/hidden/This PC/compact), tips & suggestions off" -ForegroundColor Gray
        $ans = Read-Host "  Apply the default set now? [y/N]"
        if ($ans -match '^(y|yes)$') { $All = $true } else { Write-Log "Nothing applied. Run with -All, or pick switches (see the comment block at the top)." 'INFO'; return }
    } else {
        Write-Log "Nothing selected. Use -All, or pick switches (see the comment block at the top)." 'WARN'; return
    }
}

if ($All) { if ($Theme -eq 'Skip') { $Theme = 'Dark' }; $DesktopIcons = $true; $ExplorerView = $true; $DisableTips = $true }

$adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$hide = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$bags = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
$cdm  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

# --- backup first ----------------------------------------------------------------
Write-Log "Backing up registry keys..." 'STEP'
foreach ($k in @(
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons',
    'HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
)) { Backup-RegistryKey -Path $k -Label $label | Out-Null }

# --- theme -------------------------------------------------------------------------
if ($Theme -ne 'Skip') {
    Write-Log "Theme: $Theme" 'STEP'
    $light = if ($Theme -eq 'Light') { 1 } else { 0 }
    Set-RegValue -Path $pers -Name 'AppsUseLightTheme'   -Value $light
    Set-RegValue -Path $pers -Name 'SystemUsesLightTheme' -Value $light
}

# --- desktop icons ---------------------------------------------------------------
if ($DesktopIcons) {
    Write-Log "Desktop icons: This PC, user folder, Network, Recycle Bin$(if ($IncludeControlPanel) { ', Control Panel' })" 'STEP'
    $icons = @{
        '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' = 'This PC'
        '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' = 'User folder'
        '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' = 'Network'
        '{645FF040-5081-101B-9F08-00AA002F954E}' = 'Recycle Bin'
    }
    if ($IncludeControlPanel) { $icons['{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'] = 'Control Panel' }
    foreach ($g in $icons.Keys) { Set-RegValue -Path $hide -Name $g -Value 0 }   # 0 = shown
}

# --- icon size -------------------------------------------------------------------
if ($IconSize -ne 'Skip') {
    $px = @{ Small = 32; Medium = 48; Large = 96 }[$IconSize]
    Write-Log "Desktop icon size: $IconSize ($px px)" 'STEP'
    Set-RegValue -Path $bags -Name 'IconSize' -Value $px
    Set-RegValue -Path $bags -Name 'Mode'     -Value 1
    Set-RegValue -Path $bags -Name 'LogicalViewMode' -Value 3
}

# --- Explorer view --------------------------------------------------------------
if ($ExplorerView) {
    Write-Log "Explorer: extensions + hidden files shown, opens to This PC, compact view, no sync-provider ads" 'STEP'
    Set-RegValue -Path $adv -Name 'HideFileExt'       -Value 0
    Set-RegValue -Path $adv -Name 'Hidden'            -Value 1
    Set-RegValue -Path $adv -Name 'LaunchTo'          -Value 1
    Set-RegValue -Path $adv -Name 'UseCompactMode'    -Value 1
    Set-RegValue -Path $adv -Name 'ShowSyncProviderNotifications' -Value 0
    Set-RegValue -Path $adv -Name 'SeparateProcess'   -Value 1   # each Explorer window its own process: one hang doesn't kill the desktop
}

# --- Quick Access pins ------------------------------------------------------------
if ($QuickAccessPins) {
    Write-Log "Quick Access pins..." 'STEP'
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($p in $QuickAccessPins) {
            if (-not (Test-Path $p)) { Write-Log "  $p not reachable right now — skipped." 'WARN'; continue }
            if ($PSCmdlet.ShouldProcess($p, "Pin to Quick Access")) {
                try { $shell.Namespace($p).Self.InvokeVerb('pintohome'); Write-Log "  Pinned $p" 'OK' }
                catch { Write-Log "  Could not pin ${p}: $($_.Exception.Message)" 'WARN' }
            }
        }
    } catch { Write-Log "Shell COM not available: $($_.Exception.Message)" 'WARN' }
}

# --- tips / suggestions off -------------------------------------------------------
if ($DisableTips) {
    Write-Log "Tips, welcome experience, Start suggestions: off" 'STEP'
    foreach ($v in @('SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled',
                     'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SoftLandingEnabled',
                     'SystemPaneSuggestionsEnabled', 'RotatingLockScreenOverlayEnabled', 'SilentInstalledAppsEnabled')) {
        Set-RegValue -Path $cdm -Name $v -Value 0
    }
    Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name 'ScoobeSystemSettingEnabled' -Value 0   # "finish setting up your device"
}

if (-not $WhatIfPreference) {
    if (-not $NoExplorerRestart) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Write-Log "Explorer restarted." 'OK' }
    Write-Host ''
    Write-Host "  Done. Undo any time with:  .\Set-DesktopExperience.ps1 -Rollback" -ForegroundColor Green
    Write-Host "  Taskbar layout lives in 02-Windows11\Set-Win11Baseline.ps1 / 03-Windows10\Set-Win10Baseline.ps1." -ForegroundColor White
}
