<#
.SYNOPSIS
    Put the standard set of shortcuts on the desktop — apps, shares, web
    portals, the IT toolkit — with proper icons, from a simple JSON manifest.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit (the
    manifest is a plain JSON file: Config\desktop-shortcuts.json in the kit,
    or any file you point -ManifestPath at; shortcuts-EXAMPLE.json next to
    this script shows the format). Idempotent: existing shortcuts with the same name are
    replaced, so re-running after editing the manifest is the normal way to
    update a desktop.

      - A Target that starts with http:// or https:// becomes an Internet
        Shortcut (.url) with the icon you give it.
      - Anything else becomes a normal .lnk (program, file, folder, UNC).
      - RunAsAdmin: true sets the "Run as administrator" flag on the .lnk.
      - Icon: 'C:\path\file.ico', or 'file.exe,0' / 'shell32.dll,14' style.

.PARAMETER ManifestPath
    JSON manifest. Default: Config\desktop-shortcuts.json (the kit's Config
    folder). Without that and without -ManifestPath the script stops and tells
    you — it never puts example shortcuts on a desktop unless you say -UseExample.
.PARAMETER UseExample
    Use shortcuts-EXAMPLE.json next to this script (demo targets - for testing
    the mechanism only).
.PARAMETER Scope
    CurrentUser (this user's desktop) or AllUsers (the Public desktop —
    every user sees them; needs admin).
.PARAMETER Remove
    Delete the shortcuts named in the manifest instead of creating them.

.EXAMPLE
    .\New-DesktopShortcuts.ps1 -WhatIf          (uses Config\desktop-shortcuts.json)
.EXAMPLE
    .\New-DesktopShortcuts.ps1 -ManifestPath \\fs01\IT\desktop-shortcuts.json -Scope AllUsers
.EXAMPLE
    .\New-DesktopShortcuts.ps1 -Remove

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$ManifestPath,
    [switch]$UseExample,
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$Remove
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
if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $__v = Get-ToolkitSetting 'Desktop.ShortcutsManifest' -File; if ($null -ne $__v) { $ManifestPath = $__v; $__cfgUsed += 'Desktop.ShortcutsManifest' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Test-Admin {
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}
function Set-RunAsAdminFlag {
    # .lnk header byte 0x15, bit 0x20 = "Run as administrator" (the checkbox in Properties > Advanced)
    param([string]$LnkPath)
    $bytes = [IO.File]::ReadAllBytes($LnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($LnkPath, $bytes)
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Desktop Shortcuts" -ForegroundColor White
Write-Host "  ======================================" -ForegroundColor DarkGray

if (-not $ManifestPath -and $UseExample) { $ManifestPath = Join-Path $PSScriptRoot 'shortcuts-EXAMPLE.json' }
if (-not $ManifestPath) {
    Write-Log "No shortcut manifest. Put your shortcuts in Config\desktop-shortcuts.json (kit) or pass -ManifestPath <file>. Format: shortcuts-EXAMPLE.json next to this script; -UseExample runs that demo set." 'WARN'; return
}
if (-not (Test-Path -LiteralPath $ManifestPath)) { Write-Log "Manifest not found: $ManifestPath" 'ERROR'; return }
try { $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json } catch { Write-Log "Manifest isn't valid JSON: $($_.Exception.Message)" 'ERROR'; return }
$items = @($manifest.shortcuts)
if (-not $items.Count) { Write-Log "Manifest has no 'shortcuts' entries." 'WARN'; return }

$desktop = if ($Scope -eq 'AllUsers') { [Environment]::GetFolderPath('CommonDesktopDirectory') } else { [Environment]::GetFolderPath('Desktop') }
if ($Scope -eq 'AllUsers' -and -not (Test-Admin)) { Write-Log "-Scope AllUsers writes to the Public desktop and needs Administrator rights." 'ERROR'; return }
Write-Log "Desktop: $desktop  ($Scope)" 'INFO'

$shell = New-Object -ComObject WScript.Shell
$done = 0
foreach ($s in $items) {
    if (-not $s.Name -or -not $s.Target) { Write-Log "Entry without Name/Target skipped." 'WARN'; continue }
    $safeName = $s.Name -replace '[\\/:*?"<>|]', '_'
    $target = [Environment]::ExpandEnvironmentVariables([string]$s.Target)
    $isUrl = $target -match '^https?://'
    $path = Join-Path $desktop ($safeName + $(if ($isUrl) { '.url' } else { '.lnk' }))

    if ($Remove) {
        if (Test-Path $path) {
            if ($PSCmdlet.ShouldProcess($path, "Remove shortcut")) { Remove-Item $path -Force; Write-Log "Removed $safeName" 'OK'; $done++ }
        } else { Write-Log "$safeName not present — nothing to remove." 'INFO' }
        continue
    }

    if (-not $isUrl -and -not (Test-Path $target)) { Write-Log "${safeName}: target not found right now ($target) — creating anyway (may be a share/app that appears later)." 'WARN' }

    if (-not $PSCmdlet.ShouldProcess($path, "Create shortcut -> $target")) { continue }
    try {
        if ($isUrl) {
            $lines = @('[InternetShortcut]', "URL=$target")
            if ($s.Icon) {
                $iconSpec = [Environment]::ExpandEnvironmentVariables([string]$s.Icon)
                $iconFile = ($iconSpec -split ',')[0]; $iconIdx = if ($iconSpec -match ',\s*(-?\d+)$') { $Matches[1] } else { '0' }
                $lines += "IconFile=$iconFile"; $lines += "IconIndex=$iconIdx"
            }
            $lines | Set-Content -Path $path -Encoding ASCII
        } else {
            $lnk = $shell.CreateShortcut($path)
            $lnk.TargetPath = $target
            if ($s.Arguments)        { $lnk.Arguments = [Environment]::ExpandEnvironmentVariables([string]$s.Arguments) }
            if ($s.WorkingDirectory) { $lnk.WorkingDirectory = [Environment]::ExpandEnvironmentVariables([string]$s.WorkingDirectory) }
            elseif (-not $target.StartsWith('\\')) { try { $lnk.WorkingDirectory = Split-Path $target -Parent } catch { } }
            if ($s.Icon)             { $lnk.IconLocation = [Environment]::ExpandEnvironmentVariables([string]$s.Icon) }
            if ($s.Description)      { $lnk.Description = [string]$s.Description }
            $lnk.Save()
            if ($s.RunAsAdmin -eq $true) { Set-RunAsAdminFlag -LnkPath $path }
        }
        Write-Log "Created $safeName$(if ($s.RunAsAdmin -eq $true) { ' (run as admin)' })" 'OK'
        $done++
    } catch {
        Write-Log "$safeName failed: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  $done shortcut(s) $(if ($Remove) { 'removed' } else { 'created/updated' }) on $desktop" -ForegroundColor Green
}
