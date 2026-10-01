<#
.SYNOPSIS
    Shared helpers for the Sysadmin-Toolkit scripts — logging, elevation check,
    registry backup/restore, and safe confirmation prompts.

.DESCRIPTION
    Dot-source or Import-Module this file at the top of any toolkit script:

        Import-Module "$PSScriptRoot\..\_Common\SysadminToolkit.Common.psm1" -Force

    Every function is defensive: nothing throws on a missing folder, and the
    registry helpers always back up before they change anything.

.NOTES
    Part of the Sysadmin-Toolkit family (companion to TechToolkit).
    Author: Stojan Tomeski
#>

# --- module-wide state -------------------------------------------------------
$script:ToolkitRoot = 'C:\Sysadmin-Toolkit'
$script:LogFile     = $null

function Get-ToolkitRoot {
    <#
    .SYNOPSIS
        Returns (and creates) the working root, default C:\Sysadmin-Toolkit.
    #>
    param([string]$Path = $script:ToolkitRoot)
    try {
        foreach ($sub in @('', 'Reports', 'Backups', 'Logs')) {
            $p = if ($sub) { Join-Path $Path $sub } else { $Path }
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null }
        }
    } catch { }
    $script:ToolkitRoot = $Path
    return $Path
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped line to the console (colored by level) and to the
        day's log file under <root>\Logs.
    .PARAMETER Level
        INFO | OK | WARN | ERROR | STEP
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    if (-not $script:LogFile) {
        $root = Get-ToolkitRoot
        $script:LogFile = Join-Path $root ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line  = "[{0}] [{1,-5}] {2}" -f $stamp, $Level, $Message
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { }
}

function Write-Banner {
    <#
    .SYNOPSIS
        Prints a titled header so multi-step scripts read cleanly in a console.
    #>
    param([Parameter(Mandatory)][string]$Title)
    $bar = '=' * ($Title.Length + 8)
    Write-Host ''
    Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White
    Write-Host "  $bar" -ForegroundColor DarkGray
}

function Test-Admin {
    <#
    .SYNOPSIS
        $true if the current session is elevated (Administrator).
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Assert-Admin {
    <#
    .SYNOPSIS
        Writes a clear warning and returns $false if not elevated. Call at the
        top of any script that needs it: if (-not (Assert-Admin)) { return }
    #>
    if (Test-Admin) { return $true }
    Write-Log "This tool needs Administrator rights. Right-click PowerShell and 'Run as administrator'." 'ERROR'
    return $false
}

function Backup-RegistryKey {
    <#
    .SYNOPSIS
        Exports a registry key to a timestamped .reg file under <root>\Backups
        before you change it. Returns the backup path (or $null if nothing to
        back up).
    .PARAMETER Path
        A registry path in reg.exe form, e.g. 'HKCU\Software\Microsoft\...'.
    .PARAMETER Label
        Short tag used in the backup filename.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'key'
    )
    $root  = Get-ToolkitRoot
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $safe  = ($Label -replace '[^\w\-]', '_')
    $tag   = (($Path -split '\\' | Select-Object -Last 2) -join '_') -replace '[^\w\-]', '_'
    $out   = Join-Path $root ("Backups\{0}_{1}_{2}.reg" -f $safe, $tag, $stamp)
    $psPath = "Registry::$Path"
    if (-not (Test-Path -LiteralPath $psPath)) {
        Write-Log "No existing key at $Path (nothing to back up)." 'INFO'
        return $null
    }
    $rc = (Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $Path), ('"{0}"' -f $out), '/y') -Wait -PassThru -WindowStyle Hidden).ExitCode
    if ($rc -eq 0) {
        Write-Log "Backed up $Path -> $out" 'OK'
        return $out
    }
    Write-Log "Could not back up $Path (reg.exe exit $rc)." 'WARN'
    return $null
}

function Set-RegValue {
    <#
    .SYNOPSIS
        Sets a registry value, creating the key path if needed. Honors -WhatIf
        through the caller's $WhatIfPreference.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,      # PowerShell form: HKCU:\...
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'Binary')]
        [string]$Type = 'DWord'
    )
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value ($Type)")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log "Set $Path\$Name = $Value" 'OK'
    }
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Simple yes/no prompt. Returns $true only on an explicit 'y'. In an
        unattended session (no interactive host) returns $false so nothing
        destructive runs by accident.
    #>
    param([Parameter(Mandatory)][string]$Question)
    # No interactive host (SYSTEM / scheduled task / piped): never auto-confirm.
    if (-not [Environment]::UserInteractive -or $null -eq $Host.UI.RawUI) { return $false }
    $ans = Read-Host "$Question [y/N]"
    return ($ans -match '^(y|yes)$')
}

function New-StrongPassword {
    <#
    .SYNOPSIS
        Generates a strong random password (default 16 chars) with upper, lower,
        digit and symbol, avoiding ambiguous characters.
    #>
    param([int]$Length = 16)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $sym   = '!@#$%^&*-_=+?'
    $all   = ($upper + $lower + $digit + $sym).ToCharArray()
    # guarantee one of each class, then fill
    $chars = @(
        $upper[(Get-Random -Max $upper.Length)]
        $lower[(Get-Random -Max $lower.Length)]
        $digit[(Get-Random -Max $digit.Length)]
        $sym[(Get-Random -Max $sym.Length)]
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) { $chars += $all[(Get-Random -Max $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Get-OSInfo {
    <#
    .SYNOPSIS
        Returns a small object describing the running OS (Caption, Build, and a
        friendly 'Win10'/'Win11'/'Server' tag) so scripts can branch.
    #>
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $tag =
        if     ($os.Caption -match 'Server') { 'Server' }
        elseif ($build -ge 22000)            { 'Win11' }
        elseif ($build -ge 10240)            { 'Win10' }
        else                                 { 'Older' }
    [pscustomobject]@{
        Caption = $os.Caption
        Version = $os.Version
        Build   = $build
        Tag     = $tag
    }
}

Export-ModuleMember -Function Get-ToolkitRoot, Write-Log, Write-Banner, Test-Admin,
    Assert-Admin, Backup-RegistryKey, Set-RegValue, Confirm-Action, New-StrongPassword, Get-OSInfo
