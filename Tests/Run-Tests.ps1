<#
.SYNOPSIS
    Run the kit's Pester tests. Installs Pester 5 for the current user if
    it's missing.

.EXAMPLE
    .\Tests\Run-Tests.ps1
.EXAMPLE
    .\Tests\Run-Tests.ps1 -Detailed

.NOTES
    Needs internet access to PowerShell Gallery the first time (to install
    Pester). Read-only otherwise. Part of the Sysadmin-Toolkit family.
#>

[CmdletBinding()]
param([switch]$Detailed)

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host "Pester 5 not found — installing for the current user..." -ForegroundColor Cyan
    try {
        Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
    } catch {
        Write-Host "Could not install Pester: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Install it manually: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck" -ForegroundColor Yellow
        return
    }
}
Import-Module Pester -MinimumVersion 5.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
$config.Run.Exit = $false
Invoke-Pester -Configuration $config
