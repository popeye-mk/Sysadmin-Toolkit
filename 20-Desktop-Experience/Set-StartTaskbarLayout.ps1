<#
.SYNOPSIS
    Pinned Start menu and taskbar apps — for new users and (where Windows
    allows) existing ones. Does what's actually possible per OS and tells you
    which route it took.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit.

    Honest map of what Windows lets a script do here:

    Windows 11
      - Start pins, NEW users: a LayoutModification.json dropped into the
        Default profile is picked up at first logon. Always works.
      - Start pins, EXISTING users: only through the "Configure Start pins"
        policy (Windows 11 22H2+). It REPLACES the user's pins with yours
        and they can't re-arrange — that's the policy's nature, not this
        script's choice. Opt in with -ApplyToExistingUsers.
      - Taskbar pins: through a taskbar layout XML + the "Start Layout"
        policy (StartLayoutFile). Applies to all users at next logon; users
        can still add their own pins next to yours.
    Windows 10
      - Start layout: Export-StartLayout on a reference machine, then
        Import-StartLayout for new users, or the StartLayoutFile policy for
        everyone (partial lockdown: your groups are locked, users can add
        their own next to them).
      - Taskbar pins: same XML as Win11.

    Every registry change is backed up (one set per run) and -Rollback
    restores it; files this script drops are removed on rollback too.

.PARAMETER StartPins
    Apps to pin to Start, in order. Each is either a packaged-app AUMID
    (e.g. 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App') or the path of a
    desktop app / .lnk (e.g. '%ProgramFiles%\Microsoft Office\root\Office16\OUTLOOK.EXE',
    or '%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk').
    Get AUMIDs with: Get-StartApps.
.PARAMETER TaskbarPins
    Same format, for the taskbar.
.PARAMETER ApplyToExistingUsers
    Win11: also write the ConfigureStartPins policy (replaces + locks pins
    for everyone). Win10: use the StartLayoutFile policy instead of only
    the Default profile.
.PARAMETER ExportCurrent
    Export THIS machine's current Start pins (Win11: JSON; Win10: XML) to
    the toolkit Reports folder so you can reuse it — a good way to build the
    pin list from a machine you set up by hand.
.PARAMETER Rollback
    Restore registry from the newest backup set and remove dropped files.

.EXAMPLE
    .\Set-StartTaskbarLayout.ps1 -ExportCurrent
.EXAMPLE
    .\Set-StartTaskbarLayout.ps1 -StartPins 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App','%ProgramFiles%\Microsoft Office\root\Office16\OUTLOOK.EXE' -TaskbarPins '%ProgramFiles%\Microsoft Office\root\Office16\OUTLOOK.EXE' -WhatIf
.EXAMPLE
    .\Set-StartTaskbarLayout.ps1 -StartPins ... -ApplyToExistingUsers

.NOTES
    Run as Administrator. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$StartPins,
    [string[]]$TaskbarPins,
    [switch]$ApplyToExistingUsers,
    [switch]$ExportCurrent,
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
if (-not $PSBoundParameters.ContainsKey('StartPins')) { $__v = Get-ToolkitSetting 'Desktop.StartPins'; if ($null -ne $__v) { $StartPins = $__v; $__cfgUsed += 'Desktop.StartPins' } }
if (-not $PSBoundParameters.ContainsKey('TaskbarPins')) { $__v = Get-ToolkitSetting 'Desktop.TaskbarPins'; if ($null -ne $__v) { $TaskbarPins = $__v; $__cfgUsed += 'Desktop.TaskbarPins' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Backups', 'Reports')) {
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
Write-Host "  Sysadmin-Toolkit :: Start / Taskbar Layout" -ForegroundColor White
Write-Host "  ============================================" -ForegroundColor DarkGray

$label = 'StartTaskbarLayout'
$root = Get-ToolkitRoot
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$isWin11 = $build -ge 22000
$policyExplorer = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
$defaultShell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
$layoutDir = 'C:\ProgramData\Sysadmin-Toolkit\Layout'
$taskbarXml = Join-Path $layoutDir 'TaskbarLayout.xml'
$startJsonDefault = Join-Path $defaultShell 'LayoutModification.json'
$startXmlDefault = Join-Path $defaultShell 'LayoutModification.xml'
$droppedFilesList = Join-Path $root 'Backups\StartTaskbarLayout_droppedfiles.txt'

Write-Log "OS build $build -> $(if ($isWin11) { 'Windows 11' } else { 'Windows 10' }) rules apply." 'INFO'

# --- rollback ------------------------------------------------------------------------
if ($Rollback) {
    Restore-RegistryBackupSet -Label $label | Out-Null
    if (Test-Path $policyExplorer) {
        if ($PSCmdlet.ShouldProcess($policyExplorer, "Remove ConfigureStartPins / StartLayoutFile / LockedStartLayout values set by this script")) {
            foreach ($v in 'ConfigureStartPins', 'StartLayoutFile', 'LockedStartLayout') { Remove-ItemProperty -Path $policyExplorer -Name $v -ErrorAction SilentlyContinue }
        }
    }
    if (Test-Path $droppedFilesList) {
        foreach ($f in Get-Content $droppedFilesList) {
            if ($f -and (Test-Path $f) -and $PSCmdlet.ShouldProcess($f, "Remove dropped file")) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
        if ($PSCmdlet.ShouldProcess($droppedFilesList, "Clear dropped-files list")) { Remove-Item $droppedFilesList -Force -ErrorAction SilentlyContinue }
    }
    Write-Log "Rollback done. Existing users keep whatever pins they have now; new users get Windows defaults." 'OK'
    return
}

# --- export ----------------------------------------------------------------------------
if ($ExportCurrent) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    try {
        if ($isWin11) {
            $out = Join-Path $root "Reports\StartPins_$stamp.json"
            Export-StartLayout -UseDesktopApplicationID -Path $out -ErrorAction Stop
        } else {
            $out = Join-Path $root "Reports\StartLayout_$stamp.xml"
            Export-StartLayout -UseDesktopApplicationID -Path $out -ErrorAction Stop
        }
        Write-Log "Exported current Start layout -> $out" 'OK'
        Write-Host "  Open it to copy the app IDs/paths into -StartPins, or reuse the file directly." -ForegroundColor White
    } catch { Write-Log "Export failed: $($_.Exception.Message)" 'ERROR' }
    return
}

if (-not $StartPins -and -not $TaskbarPins) { Write-Log "Give -StartPins and/or -TaskbarPins (or -ExportCurrent / -Rollback)." 'WARN'; return }
if (-not (Test-Admin)) { Write-Log "Needs Administrator rights." 'ERROR'; return }

function ConvertTo-PinEntry {
    # returns @{ Kind='packaged'|'desktop'; Id=<AUMID or expanded path> }
    param([string]$Pin)
    $p = [Environment]::ExpandEnvironmentVariables($Pin)
    if ($p -match '!' -and $p -notmatch '[\\/]') { return @{ Kind = 'packaged'; Id = $p } }
    return @{ Kind = 'desktop'; Id = $p }
}

$dropped = New-Object System.Collections.Generic.List[string]
Write-Log "Backing up registry keys..." 'STEP'
Backup-RegistryKey -Path 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Label $label | Out-Null

# --- Start pins ---------------------------------------------------------------------------
if ($StartPins) {
    $entries = $StartPins | ForEach-Object { ConvertTo-PinEntry $_ }
    if ($isWin11) {
        $pinned = foreach ($e in $entries) { if ($e.Kind -eq 'packaged') { @{ packagedAppId = $e.Id } } else { @{ desktopAppLink = $e.Id } } }
        $json = @{ pinnedList = @($pinned) } | ConvertTo-Json -Depth 4 -Compress
        Write-Log "Win11 Start pins: $($entries.Count) app(s)" 'STEP'

        if ($PSCmdlet.ShouldProcess($startJsonDefault, "Write LayoutModification.json for NEW users")) {
            if (-not (Test-Path $defaultShell)) { New-Item -ItemType Directory -Path $defaultShell -Force | Out-Null }
            $json | Set-Content -Path $startJsonDefault -Encoding UTF8
            $dropped.Add($startJsonDefault)
            Write-Log "New users: $startJsonDefault" 'OK'
        }
        if ($ApplyToExistingUsers) {
            Write-Log "Existing users: ConfigureStartPins policy (replaces + locks their Start pins — that's how the policy works)." 'WARN'
            Set-RegValue -Path $policyExplorer -Name 'ConfigureStartPins' -Value $json -Type String
        } else {
            Write-Log "Existing users untouched (add -ApplyToExistingUsers to push via policy — note it locks the pins)." 'INFO'
        }
    } else {
        # Windows 10: build a partial-lockdown layout XML with one group holding the pins
        # lay the tiles out 3 per row
        $i = 0; $tiles = foreach ($e in $entries) {
            $col = ($i % 3) * 2; $row = [math]::Floor($i / 3) * 2; $i++
            if ($e.Kind -eq 'packaged') { "        <start:Tile Size=`"2x2`" Column=`"$col`" Row=`"$row`" AppUserModelID=`"$($e.Id)`" />" }
            else { "        <start:DesktopApplicationTile Size=`"2x2`" Column=`"$col`" Row=`"$row`" DesktopApplicationLinkPath=`"$($e.Id)`" />" }
        }
        $xml = @"
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
  <LayoutOptions StartTileGroupCellWidth="6" />
  <DefaultLayoutOverride LayoutCustomizationRestrictionType="OnlySpecifiedGroups">
    <StartLayoutCollection>
      <defaultlayout:StartLayout GroupCellWidth="6">
        <start:Group Name="Company apps">
$($tiles -join "`n")
        </start:Group>
      </defaultlayout:StartLayout>
    </StartLayoutCollection>
  </DefaultLayoutOverride>
</LayoutModificationTemplate>
"@
        Write-Log "Win10 Start layout: $($entries.Count) tile(s) in one 'Company apps' group (partial lockdown — users can add their own groups)" 'STEP'
        if (-not (Test-Path $layoutDir)) { New-Item -ItemType Directory -Path $layoutDir -Force | Out-Null }
        $startXmlFile = Join-Path $layoutDir 'StartLayout.xml'
        if ($PSCmdlet.ShouldProcess($startXmlFile, "Write Start layout XML")) { $xml | Set-Content -Path $startXmlFile -Encoding UTF8; $dropped.Add($startXmlFile) }
        if ($ApplyToExistingUsers) {
            Set-RegValue -Path $policyExplorer -Name 'StartLayoutFile'   -Value $startXmlFile -Type ExpandString
            Set-RegValue -Path $policyExplorer -Name 'LockedStartLayout' -Value 1
            Write-Log "Applied to all users via StartLayoutFile policy (next logon)." 'OK'
        } else {
            if ($PSCmdlet.ShouldProcess($startXmlDefault, "Import-StartLayout for NEW users")) {
                try { Import-StartLayout -LayoutPath $startXmlFile -MountPath 'C:\' -ErrorAction Stop; $dropped.Add($startXmlDefault); Write-Log "New users: layout imported into the Default profile." 'OK' }
                catch { Write-Log "Import-StartLayout failed: $($_.Exception.Message)" 'WARN' }
            }
        }
    }
}

# --- taskbar pins (same XML mechanism on Win10 and Win11) ----------------------------------
if ($TaskbarPins) {
    $entries = $TaskbarPins | ForEach-Object { ConvertTo-PinEntry $_ }
    $pins = foreach ($e in $entries) {
        if ($e.Kind -eq 'packaged') { "        <taskbar:UWA AppUserModelID=`"$($e.Id)`" />" }
        else { "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$($e.Id)`" />" }
    }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$($pins -join "`n")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
    Write-Log "Taskbar pins: $($entries.Count) app(s) (users can still add their own next to these)" 'STEP'
    if (-not (Test-Path $layoutDir)) { New-Item -ItemType Directory -Path $layoutDir -Force | Out-Null }
    if ($PSCmdlet.ShouldProcess($taskbarXml, "Write taskbar layout XML")) { $xml | Set-Content -Path $taskbarXml -Encoding UTF8; $dropped.Add($taskbarXml) }
    # the StartLayoutFile policy carries the taskbar section on both OSes; on Win11 it affects the taskbar only
    Set-RegValue -Path $policyExplorer -Name 'StartLayoutFile' -Value $taskbarXml -Type ExpandString
    if ($isWin11) { Write-Log "Win11: StartLayoutFile policy applies the TASKBAR pins (Start is unaffected by it on Win11)." 'INFO' }
    else { Write-Log "Win10: taskbar pins apply at next logon. If you also set -StartPins with -ApplyToExistingUsers, the last StartLayoutFile written wins — combine both into one XML by hand for that case." 'WARN' }
}

if ($dropped.Count -and -not $WhatIfPreference) { $dropped | Add-Content -Path $droppedFilesList -Encoding UTF8 }

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Changes show at next logon (policy-based ones may need 'gpupdate /force' or a reboot)." -ForegroundColor Green
    Write-Host "  Undo with:  .\Set-StartTaskbarLayout.ps1 -Rollback" -ForegroundColor White
}
