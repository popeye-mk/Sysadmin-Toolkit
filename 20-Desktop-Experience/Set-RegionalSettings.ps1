<#
.SYNOPSIS
    Belgium-ready regional setup in one go — language/format, keyboard
    layout, time zone, home location, date format — for this user and
    (optionally) copied to the welcome screen + new users.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit.

    Defaults are for a Dutch-speaking Belgian office: format nl-BE, Belgian
    (Period) keyboard, Brussels time zone, Belgium as home location. Every
    default is a parameter, so a French-speaking site is just
    -Culture fr-BE -KeyboardTip '080c:0000080c'.

    Before changing anything it saves the CURRENT settings to a JSON file
    under Backups\, and -Rollback restores exactly those. (Regional settings
    aren't a single registry key you can .reg-export, so this script keeps
    its own snapshot instead.)

    Display language (the UI language) is NOT changed here — that's a
    language pack install, and on a work PC it's usually decided by the
    image. This script is about formats, keyboard, clock and location.

.PARAMETER Culture
    Regional format (numbers/dates/currency). Default nl-BE.
.PARAMETER KeyboardTip
    Input profile "LCID:KLID". Default '0813:00000813' = Dutch (Belgium) +
    Belgian (Period). Others: '0813:0001080c' Belgian (Comma),
    '080c:0000080c' French (Belgium) + Belgian French, '0409:00000409' US.
.PARAMETER ReplaceKeyboards
    Make -KeyboardTip the ONLY input method (default: put it first and keep
    the others).
.PARAMETER TimeZone
    Default 'Romance Standard Time' (Brussels).
.PARAMETER HomeLocationGeoId
    Default 21 = Belgium. (Netherlands 176, France 84, Germany 94.)
.PARAMETER ShortDate
    Short date pattern. Default 'dd/MM/yyyy'.
.PARAMETER CopyToSystem
    Also apply to the welcome screen and to new user accounts
    (Copy-UserInternationalSettingsToSystem — Windows 11 / Server 2022+;
    on Windows 10 the script tells you the manual route instead). Needs admin.
.PARAMETER Rollback
    Restore the newest snapshot and exit.

.EXAMPLE
    .\Set-RegionalSettings.ps1 -WhatIf
.EXAMPLE
    .\Set-RegionalSettings.ps1 -CopyToSystem
.EXAMPLE
    .\Set-RegionalSettings.ps1 -Culture fr-BE -KeyboardTip '080c:0000080c' -ReplaceKeyboards
.EXAMPLE
    .\Set-RegionalSettings.ps1 -Rollback

.NOTES
    Runs as the user (CopyToSystem needs admin). Sign out/in to see every
    change (keyboard order and time zone apply immediately).
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$Culture = 'nl-BE',
    [string]$KeyboardTip = '0813:00000813',
    [switch]$ReplaceKeyboards,
    [string]$TimeZone = 'Romance Standard Time',
    [int]$HomeLocationGeoId = 21,
    [string]$ShortDate = 'dd/MM/yyyy',
    [switch]$CopyToSystem,
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
if (-not $PSBoundParameters.ContainsKey('Culture')) { $__v = Get-ToolkitSetting 'Regional.Culture'; if ($null -ne $__v) { $Culture = $__v; $__cfgUsed += 'Regional.Culture' } }
if (-not $PSBoundParameters.ContainsKey('KeyboardTip')) { $__v = Get-ToolkitSetting 'Regional.KeyboardTip'; if ($null -ne $__v) { $KeyboardTip = $__v; $__cfgUsed += 'Regional.KeyboardTip' } }
if (-not $PSBoundParameters.ContainsKey('TimeZone')) { $__v = Get-ToolkitSetting 'Regional.TimeZone'; if ($null -ne $__v) { $TimeZone = $__v; $__cfgUsed += 'Regional.TimeZone' } }
if (-not $PSBoundParameters.ContainsKey('HomeLocationGeoId')) { $__v = Get-ToolkitSetting 'Regional.HomeLocationGeoId'; if ($null -ne $__v) { $HomeLocationGeoId = $__v; $__cfgUsed += 'Regional.HomeLocationGeoId' } }
if (-not $PSBoundParameters.ContainsKey('ShortDate')) { $__v = Get-ToolkitSetting 'Regional.ShortDate'; if ($null -ne $__v) { $ShortDate = $__v; $__cfgUsed += 'Regional.ShortDate' } }
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

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Regional Settings" -ForegroundColor White
Write-Host "  ======================================" -ForegroundColor DarkGray

if (-not (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue)) {
    Write-Log "The International module (Get-WinUserLanguageList etc.) isn't available — this needs Windows." 'ERROR'; return
}
$backupDir = Join-Path (Get-ToolkitRoot) 'Backups'

# --- rollback ------------------------------------------------------------------------
if ($Rollback) {
    $snap = Get-ChildItem $backupDir -Filter 'RegionalSettings_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $snap) { Write-Log "No RegionalSettings snapshot found in $backupDir." 'WARN'; return }
    $s = Get-Content $snap.FullName -Raw | ConvertFrom-Json
    if ($PSCmdlet.ShouldProcess($snap.Name, "Restore regional settings")) {
        try {
            Set-Culture $s.Culture
            $list = New-WinUserLanguageList $s.Languages[0].LanguageTag
            $list[0].InputMethodTips.Clear()
            foreach ($tip in $s.Languages[0].InputMethodTips) { $list[0].InputMethodTips.Add($tip) }
            for ($i = 1; $i -lt $s.Languages.Count; $i++) { $l = New-WinUserLanguageList $s.Languages[$i].LanguageTag; $l[0].InputMethodTips.Clear(); foreach ($tip in $s.Languages[$i].InputMethodTips) { $l[0].InputMethodTips.Add($tip) }; $list.Add($l[0]) }
            Set-WinUserLanguageList $list -Force
            Set-WinHomeLocation -GeoId $s.HomeLocationGeoId
            if ($s.TimeZoneId) { Set-TimeZone -Id $s.TimeZoneId }
            Set-ItemProperty -Path 'HKCU:\Control Panel\International' -Name 'sShortDate' -Value $s.ShortDate
            Write-Log "Restored from $($snap.Name). Sign out/in to see everything." 'OK'
        } catch { Write-Log "Restore failed partway: $($_.Exception.Message)" 'ERROR' }
    }
    return
}

# --- snapshot current ----------------------------------------------------------------
Write-Log "Saving current settings..." 'STEP'
$current = [ordered]@{
    Culture           = (Get-Culture).Name
    Languages         = @(Get-WinUserLanguageList | ForEach-Object { @{ LanguageTag = $_.LanguageTag; InputMethodTips = @($_.InputMethodTips) } })
    HomeLocationGeoId = (Get-WinHomeLocation).GeoId
    TimeZoneId        = (Get-TimeZone).Id
    ShortDate         = (Get-ItemProperty 'HKCU:\Control Panel\International' -Name sShortDate -ErrorAction SilentlyContinue).sShortDate
}
$snapPath = Join-Path $backupDir ("RegionalSettings_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
if ($PSCmdlet.ShouldProcess($snapPath, "Write snapshot")) { $current | ConvertTo-Json -Depth 5 | Set-Content -Path $snapPath -Encoding UTF8; Write-Log "Snapshot: $snapPath" 'OK' }
Write-Log "Now: culture $($current.Culture), keyboards $(($current.Languages | ForEach-Object { $_.InputMethodTips }) -join ' '), TZ $($current.TimeZoneId), home $($current.HomeLocationGeoId)" 'INFO'

# --- apply ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("this user", "Regional format -> $Culture")) { Set-Culture $Culture; Write-Log "Format: $Culture" 'OK' }

if ($PSCmdlet.ShouldProcess("this user", "Keyboard -> $KeyboardTip $(if ($ReplaceKeyboards) { '(only)' } else { '(first)' })")) {
    $langTag = $Culture
    $list = New-WinUserLanguageList $langTag
    $list[0].InputMethodTips.Clear()
    $list[0].InputMethodTips.Add($KeyboardTip)
    if (-not $ReplaceKeyboards) {
        foreach ($existing in Get-WinUserLanguageList) {
            if ($existing.LanguageTag -eq $langTag) {
                foreach ($tip in $existing.InputMethodTips) { if ($tip -ne $KeyboardTip) { $list[0].InputMethodTips.Add($tip) } }
            } else { $list.Add($existing) }
        }
    }
    Set-WinUserLanguageList $list -Force
    Write-Log "Keyboard: $KeyboardTip" 'OK'
}

if ($PSCmdlet.ShouldProcess("this user", "Home location -> GeoId $HomeLocationGeoId")) { Set-WinHomeLocation -GeoId $HomeLocationGeoId; Write-Log "Home location: $HomeLocationGeoId" 'OK' }

if ($PSCmdlet.ShouldProcess("this machine", "Time zone -> $TimeZone")) {
    try { Set-TimeZone -Id $TimeZone -ErrorAction Stop; Write-Log "Time zone: $TimeZone" 'OK' }
    catch { Write-Log "Time zone needs admin (or the ID is wrong): $($_.Exception.Message)" 'WARN' }
}

if ($PSCmdlet.ShouldProcess("this user", "Short date -> $ShortDate")) {
    Set-ItemProperty -Path 'HKCU:\Control Panel\International' -Name 'sShortDate' -Value $ShortDate
    Set-ItemProperty -Path 'HKCU:\Control Panel\International' -Name 'iFirstDayOfWeek' -Value '0'   # Monday
    Write-Log "Short date: $ShortDate, week starts Monday" 'OK'
}

# --- welcome screen + new users -------------------------------------------------------
if ($CopyToSystem) {
    if (-not (Test-Admin)) { Write-Log "-CopyToSystem needs Administrator rights — skipped." 'WARN' }
    elseif (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess("welcome screen + new users", "Copy this user's international settings")) {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
            Write-Log "Copied to welcome screen and default profile." 'OK'
        }
    } else {
        Write-Log "Copy-UserInternationalSettingsToSystem isn't on this OS (Windows 10). Manual route: Control Panel > Region > Administrative > 'Copy settings...' (tick both boxes)." 'WARN'
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Sign out/in to see all changes. Undo with:  .\Set-RegionalSettings.ps1 -Rollback" -ForegroundColor Green
}
