<#
.SYNOPSIS
    Shared helpers for the Entra + Intune scripts — Graph connection, logging,
    and small utilities specific to cloud identity work.

.DESCRIPTION
    Dot-source or Import-Module this at the top of any 09-Entra-Intune script:

        Import-Module "$PSScriptRoot\_GraphCommon.psm1" -Force

    Mirrors the logging conventions of the main _Common module (Write-Log,
    Write-Banner, Get-ToolkitRoot) so console output and log files look the
    same across the whole kit, plus Graph-specific helpers:

      - Connect-ToolkitGraph   : connects with just the scopes a script needs,
                                  reuses an existing connection if it already
                                  has them, and gives a clear error if the
                                  Microsoft.Graph module isn't installed.
      - Test-GraphScope        : checks the current connection actually has a
                                  scope before you rely on it.

.NOTES
    Requires the Microsoft.Graph PowerShell SDK (or at least the relevant
    sub-modules — Microsoft.Graph.Authentication is the minimum). Install with:
        Install-Module Microsoft.Graph -Scope CurrentUser
    Works on Windows PowerShell 5.1 and PowerShell 7.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

$script:ToolkitRoot = 'C:\Sysadmin-Toolkit'
$script:LogFile     = $null

function Get-ToolkitRoot {
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
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { }
}

function Write-Banner {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White
    Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray
}

function Connect-ToolkitGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with the given scopes, reusing an existing
        session if it already covers them. Errors clearly if the SDK is missing.
    .PARAMETER Scopes
        Delegated permission scopes needed, e.g. 'User.ReadWrite.All','Group.ReadWrite.All'.
    .PARAMETER TenantId
        Optional — pin to a specific tenant (useful if you're a guest in others).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [string]$TenantId
    )
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'
        return $false
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru |
        Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) {
        Write-Log "Reusing existing Graph connection ($($ctx.Account), tenant $($ctx.TenantId))." 'INFO'
        return $true
    }

    Write-Log "Connecting to Microsoft Graph (scopes: $($Scopes -join ', '))..." 'STEP'
    try {
        $params = @{ Scopes = $Scopes; NoWelcome = $true }
        if ($TenantId) { $params.TenantId = $TenantId }
        Connect-MgGraph @params -ErrorAction Stop
        $ctx = Get-MgContext
        Write-Log "Connected as $($ctx.Account) to tenant $($ctx.TenantId)." 'OK'
        return $true
    } catch {
        Write-Log "Graph connection failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Test-GraphScope {
    param([Parameter(Mandatory)][string]$Scope)
    $ctx = Get-MgContext
    if (-not $ctx) { return $false }
    return ($ctx.Scopes -contains $Scope)
}

Export-ModuleMember -Function Get-ToolkitRoot, Write-Log, Write-Banner, Connect-ToolkitGraph, Test-GraphScope
