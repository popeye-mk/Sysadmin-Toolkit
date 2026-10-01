<#
.SYNOPSIS
    Install the kit from wherever it's running (ISO, USB stick, network
    share, a download folder) to C:\Sysadmin-Toolkit, and put a launcher
    shortcut on the desktop.

.DESCRIPTION
    The kit runs fine straight from read-only media (reports and backups
    always go to C:\Sysadmin-Toolkit\Reports etc., not next to the scripts).
    But for anything that needs a permanent path — the scheduled tasks
    (Install-AllScheduledTasks.ps1), the secret store, the GPO version
    snapshot — you want a local copy. That's this script:

      1. Copies everything next to this script to -Destination
         (default C:\Sysadmin-Toolkit), skipping Reports/Backups/Logs and
         any secrets.json so an install never overwrites your local data.
      2. Unblocks the copied files (removes the "downloaded from the
         internet" mark that makes PowerShell refuse to run them).
      3. Creates a desktop shortcut "Sysadmin-Toolkit" that opens the menu.
      4. Creates Config\ (your settings, shortcuts, branding) on first install
         and never overwrites it afterwards.

    Re-running it updates the scripts in place — your Reports, Backups,
    Logs and secrets stay untouched.

.PARAMETER Destination
    Where to install. Default C:\Sysadmin-Toolkit.
.PARAMETER NoShortcut
    Skip the desktop shortcut.
.PARAMETER Prune
    After copying, move files that are in -Destination but NOT in this kit
    (left over from an older version) into Backups\Pruned-<date>\, so the
    installed kit matches this one exactly. Nothing is deleted - move a file
    back if you still need it. Config, Reports, Logs, Backups, secrets and
    the onboarding marker are never touched.

.EXAMPLE
    D:\Install-Toolkit.ps1              # from a mounted ISO
.EXAMPLE
    .\Install-Toolkit.ps1 -Destination D:\Tools\Sysadmin-Toolkit -WhatIf

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$Destination = 'C:\Sysadmin-Toolkit',
    [switch]$NoShortcut,
    [switch]$Prune
)

function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Install" -ForegroundColor White
Write-Host "  ===========================" -ForegroundColor DarkGray

$source = $PSScriptRoot
if (-not (Test-Path (Join-Path $source 'README.md'))) {
    Write-Log "This doesn't look like the kit root (no README.md next to me): $source" 'ERROR'; return
}
Write-Log "Source     : $source" 'INFO'
Write-Log "Destination: $Destination" 'INFO'

$sameFolder = $false
try { $sameFolder = ((Resolve-Path $source).Path.TrimEnd('\') -eq (Resolve-Path $Destination -ErrorAction Stop).Path.TrimEnd('\')) } catch { }
if ($sameFolder) {
    Write-Log "You're running the installer from the install folder itself - nothing to copy. Unblocking files and refreshing the shortcut only." 'INFO'
}

$skipDirs = @('Reports', 'Backups', 'Logs')
$skipFiles = @('secrets.json', '_lastversions.json', 'Sysadmin-Toolkit-Setup.exe', 'autorun.inf', 'README-ISO.txt')

if (-not $sameFolder -and $PSCmdlet.ShouldProcess($Destination, "Copy kit from $source")) {
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $items = Get-ChildItem -Path $source -Recurse -Force | Where-Object {
        $rel = $_.FullName.Substring($source.Length).TrimStart('\', '/')
        $top = ($rel -split '[\\/]')[0]
        (-not ($skipDirs -contains $top)) -and (-not ($skipFiles -contains $_.Name))
    }
    $count = 0; $keptCfg = 0
    foreach ($item in $items) {
        $rel = $item.FullName.Substring($source.Length).TrimStart('\', '/')
        $target = Join-Path $Destination $rel
        if ($item.PSIsContainer) {
            if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        } else {
            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            # Config\ holds the admin's own settings and files: created on first install, never overwritten after
            if ($rel -match '^Config[\\/]' -and (Test-Path -LiteralPath $target)) { $keptCfg++; continue }
            Copy-Item -Path $item.FullName -Destination $target -Force
            $count++
        }
    }
    foreach ($d in $skipDirs) { $p = Join-Path $Destination $d; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    Write-Log "Copied $count file(s)." 'OK'
    if (-not (Test-Path (Join-Path $source 'Config'))) {
        # an update pushed without Config\ (e.g. from OpsBoard): this PC's own settings stay as they are
        Write-Log "No Config\ in this package - kept this PC's own Config\ as it is." 'OK'
    }
    elseif ($keptCfg) { Write-Log "Kept your existing Config\ files ($keptCfg) - settings survive updates." 'OK' }
    else { Write-Log "Config\ created with templates - fill in Config\toolkit-settings.json once (see Config\README.md)." 'INFO' }
}
if ($Prune -and -not $sameFolder -and (Test-Path $Destination)) {
    # Files from an older kit that this version no longer ships. Moved, never deleted.
    $keepTop   = @('Config', 'Reports', 'Backups', 'Logs')
    $keepFiles = @('secrets.json', '_lastversions.json', '.opsboard-onboarded')
    $dst = (Resolve-Path $Destination).Path.TrimEnd('\', '/')
    $extra = @(Get-ChildItem -Path $dst -Recurse -File -Force | Where-Object {
        $rel = $_.FullName.Substring($dst.Length).TrimStart('\', '/')
        $top = ($rel -split '[\\/]')[0]
        (-not ($keepTop -contains $top)) -and (-not ($keepFiles -contains $_.Name)) -and
        (-not (Test-Path -LiteralPath (Join-Path $source $rel)))
    })
    if ($extra.Count -eq 0) {
        Write-Log "Prune: nothing left over - the installed kit matches this version." 'OK'
    } elseif ($PSCmdlet.ShouldProcess($Destination, "Move $($extra.Count) left-over file(s) to Backups")) {
        $bk = Join-Path (Join-Path $dst 'Backups') ('Pruned-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($f in $extra) {
            $rel = $f.FullName.Substring($dst.Length).TrimStart('\', '/')
            $to = Join-Path $bk $rel
            New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $to -Force
        }
        # folders that are now empty (they only held left-over files)
        Get-ChildItem -Path $dst -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            $rel = $_.FullName.Substring($dst.Length).TrimStart('\', '/')
            if (-not ($keepTop -contains ($rel -split '[\\/]')[0]) -and -not (Test-Path -LiteralPath (Join-Path $source $rel)) -and -not (Get-ChildItem -LiteralPath $_.FullName -Force)) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
        Write-Log "Prune: moved $($extra.Count) left-over file(s) from an older version to $bk" 'OK'
    }
}
if ($PSCmdlet.ShouldProcess($Destination, "Unblock files")) {
    try { Get-ChildItem -Path $Destination -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; Write-Log "Unblocked files." 'OK' } catch { }
}
if ($PSCmdlet.ShouldProcess($Destination, "Clear read-only")) {
    # Files copied off an ISO/CD keep the read-only attribute, which blocks editing Config\ later.
    try { Get-ChildItem -Path $Destination -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }; Write-Log "Cleared read-only attribute." 'OK' } catch { }
}

if (-not $NoShortcut -and $PSCmdlet.ShouldProcess("Desktop", "Create 'Sysadmin-Toolkit' shortcut")) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop 'Sysadmin-Toolkit.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$Destination\Start-SysadminToolkit.ps1`""
        $sc.WorkingDirectory = $Destination
        $sc.IconLocation = 'powershell.exe,0'
        $sc.Description = 'Sysadmin-Toolkit menu'
        $sc.Save()
        Write-Log "Shortcut: $lnk" 'OK'
    } catch { Write-Log "Could not create the shortcut: $($_.Exception.Message)" 'WARN' }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Installed. Open the menu with:  $Destination\Start-SysadminToolkit.ps1" -ForegroundColor Green
    Write-Host "  or double-click Sysadmin-Toolkit.bat in that folder / the desktop shortcut." -ForegroundColor White
}
