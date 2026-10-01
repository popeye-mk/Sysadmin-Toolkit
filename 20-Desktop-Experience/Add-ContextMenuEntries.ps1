<#
.SYNOPSIS
    Useful right-click menu entries for an admin / power user — "Open
    PowerShell here (Admin)", "Copy path", "Open with Notepad", "Take
    ownership" — added cleanly, removable cleanly.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Entries
    are written under HKCU\Software\Classes (this user only, no admin
    needed) or, with -AllUsers, under HKLM\Software\Classes (everyone,
    admin). Each entry is a key named 'SysadminToolkit.<Name>' so -Remove
    knows exactly what's ours and touches nothing else. Registry backup
    before, -Rollback after — same as the rest of the kit.

    Windows 11 note: these appear under "Show more options" (the classic
    menu) unless the classic menu is the default — which
    02-Windows11\Set-Win11Baseline.ps1 sets. Run both and they're one click
    away.

.PARAMETER PowerShellHere
    "Open PowerShell here" + "Open PowerShell here (Admin)" on folders and
    folder backgrounds.
.PARAMETER CopyPath
    "Copy path" on files and folders (without the quotes Shift+right-click
    adds).
.PARAMETER OpenWithNotepad
    "Open with Notepad" on every file type.
.PARAMETER TakeOwnership
    "Take ownership" on files and folders (takeown + icacls; admin prompt).
    Powerful — only add it on admin machines.
.PARAMETER All
    = -PowerShellHere -CopyPath -OpenWithNotepad (TakeOwnership stays opt-in).
.PARAMETER AllUsers
    Write under HKLM (all users) instead of HKCU. Needs admin.
.PARAMETER Remove
    Remove every entry this script ever added (in the chosen scope).
.PARAMETER Rollback
    Re-import the newest registry backup set and exit.

.EXAMPLE
    .\Add-ContextMenuEntries.ps1 -All -WhatIf
.EXAMPLE
    .\Add-ContextMenuEntries.ps1 -All -TakeOwnership -AllUsers
.EXAMPLE
    .\Add-ContextMenuEntries.ps1 -Remove

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [switch]$PowerShellHere,
    [switch]$CopyPath,
    [switch]$OpenWithNotepad,
    [switch]$TakeOwnership,
    [switch]$All,
    [switch]$AllUsers,
    [switch]$Remove,
    [switch]$Rollback
)

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

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Context Menu Entries" -ForegroundColor White
Write-Host "  =========================================" -ForegroundColor DarkGray

$label = 'ContextMenu'
$hive = if ($AllUsers) { 'HKLM' } else { 'HKCU' }
if ($AllUsers -and -not (Test-Admin)) { Write-Log "-AllUsers writes to HKLM and needs Administrator rights." 'ERROR'; return }
$prefix = 'SysadminToolkit.'

# The registry paths here contain a literal '*' (HKCU\Software\Classes\*\shell = "all file types").
# PowerShell's registry provider treats '*' as a wildcard in New-Item/Test-Path, so everything
# below talks to the registry through the .NET API, which is strictly literal.
$hiveKey = if ($AllUsers) { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }

if ($Rollback) { Restore-RegistryBackupSet -Label $label | Out-Null; return }
if ($All) { $PowerShellHere = $true; $CopyPath = $true; $OpenWithNotepad = $true }

# where each kind of entry lives (subkey paths relative to the hive)
$where = @{
    Directory           = 'Software\Classes\Directory\shell'
    DirectoryBackground = 'Software\Classes\Directory\Background\shell'
    AllFiles            = 'Software\Classes\*\shell'
}

Write-Log "Backing up registry keys ($hive)..." 'STEP'
foreach ($sub in $where.Values) { Backup-RegistryKey -Path "$hive\$sub" -Label $label | Out-Null }

# --- remove ---------------------------------------------------------------------------
if ($Remove) {
    $n = 0
    foreach ($sub in $where.Values) {
        $base = $hiveKey.OpenSubKey($sub, $true)
        if (-not $base) { continue }
        foreach ($name in $base.GetSubKeyNames()) {
            if ($name -like "$prefix*" -and $PSCmdlet.ShouldProcess("$hive\$sub\$name", "Remove context menu entry")) {
                $base.DeleteSubKeyTree($name, $false); $n++
            }
        }
        $base.Close()
    }
    Write-Log "Removed $n entr(y/ies)." 'OK'; return
}
if (-not ($PowerShellHere -or $CopyPath -or $OpenWithNotepad -or $TakeOwnership)) { Write-Log "Nothing selected — use -All or pick switches." 'WARN'; return }

function Add-Entry {
    param([string]$BaseSub, [string]$Name, [string]$Text, [string]$Command, [string]$Icon, [switch]$Extended, [switch]$NoWorkingDirectory)
    $sub = "$BaseSub\$prefix$Name"
    if (-not $PSCmdlet.ShouldProcess("$hive\$sub", "Add '$Text'")) { return }
    try {
        $k = $hiveKey.CreateSubKey($sub)
        $k.SetValue('', $Text)
        if ($Icon) { $k.SetValue('Icon', $Icon) }
        if ($Extended) { $k.SetValue('Extended', '') }               # Shift+right-click only
        if ($NoWorkingDirectory) { $k.SetValue('NoWorkingDirectory', '') }
        $c = $k.CreateSubKey('command'); $c.SetValue('', $Command); $c.Close(); $k.Close()
        Write-Log "Added '$Text' -> $hive\$sub" 'OK'
    } catch { Write-Log "Could not add '$Text': $($_.Exception.Message)" 'WARN' }
}

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if ($PowerShellHere) {
    Write-Log "PowerShell here (+ Admin)..." 'STEP'
    $hereCmd  = "`"$ps`" -NoExit -Command Set-Location -LiteralPath '%V'"
    $adminCmd = "`"$ps`" -Command Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-Command','Set-Location -LiteralPath ''%V'''"
    Add-Entry -BaseSub $where.Directory           -Name 'PSHere'      -Text 'Open PowerShell here'         -Icon $ps -Command $hereCmd
    Add-Entry -BaseSub $where.DirectoryBackground -Name 'PSHere'      -Text 'Open PowerShell here'         -Icon $ps -Command $hereCmd
    Add-Entry -BaseSub $where.Directory           -Name 'PSHereAdmin' -Text 'Open PowerShell here (Admin)' -Icon $ps -Command $adminCmd
    Add-Entry -BaseSub $where.DirectoryBackground -Name 'PSHereAdmin' -Text 'Open PowerShell here (Admin)' -Icon $ps -Command $adminCmd
}
if ($CopyPath) {
    Write-Log "Copy path..." 'STEP'
    $cmd = "`"$ps`" -WindowStyle Hidden -Command Set-Clipboard -Value '%1'"
    Add-Entry -BaseSub $where.AllFiles  -Name 'CopyPath' -Text 'Copy path' -Icon "$env:SystemRoot\System32\shell32.dll,134" -Command $cmd
    Add-Entry -BaseSub $where.Directory -Name 'CopyPath' -Text 'Copy path' -Icon "$env:SystemRoot\System32\shell32.dll,134" -Command $cmd
}
if ($OpenWithNotepad) {
    Write-Log "Open with Notepad..." 'STEP'
    Add-Entry -BaseSub $where.AllFiles -Name 'Notepad' -Text 'Open with Notepad' -Icon "$env:SystemRoot\System32\notepad.exe" -Command "`"$env:SystemRoot\System32\notepad.exe`" `"%1`""
}
if ($TakeOwnership) {
    Write-Log "Take ownership (admin prompt on use)..." 'STEP'
    $fileCmd = "`"$ps`" -Command Start-Process cmd -Verb RunAs -ArgumentList '/c takeown /f \`"%1\`" && icacls \`"%1\`" /grant administrators:F'"
    $dirCmd  = "`"$ps`" -Command Start-Process cmd -Verb RunAs -ArgumentList '/c takeown /f \`"%1\`" /r /d y && icacls \`"%1\`" /grant administrators:F /t'"
    Add-Entry -BaseSub $where.AllFiles  -Name 'TakeOwnership' -Text 'Take ownership' -Icon "$env:SystemRoot\System32\imageres.dll,78" -Command $fileCmd -NoWorkingDirectory
    Add-Entry -BaseSub $where.Directory -Name 'TakeOwnership' -Text 'Take ownership' -Icon "$env:SystemRoot\System32\imageres.dll,78" -Command $dirCmd  -NoWorkingDirectory
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done — entries are live immediately (Win11: under 'Show more options' unless the classic menu is on)." -ForegroundColor Green
    Write-Host "  Remove ours only:  .\Add-ContextMenuEntries.ps1 -Remove$(if ($AllUsers) { ' -AllUsers' })" -ForegroundColor White
}
