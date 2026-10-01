<#
.SYNOPSIS
    Run one toolkit script across a company's devices — pick company, pick script,
    run it, get one report. The fleet runner.

.DESCRIPTION
    Resolves the target devices (from Zabbix host groups via 21-Fleet\Get-ManagedFleet,
    or an explicit list), checks each is reachable over PowerShell remoting (WinRM),
    then runs the kit script on each with Invoke-Command, in parallel, and prints a
    single done / offline / failed report.

    The kit is assumed installed at C:\Sysadmin-Toolkit on the targets (via the
    installer, GPO or Intune). Machine-scope scripts (reports, branding with
    -AllUsers, power, etc.) run this way; per-user scripts (theme, per-user context
    menu) must run in the user's own session — push those via GPO/Intune instead.

    Non-interactive: it sets SYSADMIN_TOOLKIT_FORCE=1 in the remote session, so any
    confirmation prompts are skipped (no hang). Always shows the target list with
    -WhatIf first; nothing runs until you drop -WhatIf.

.PARAMETER Company
    Company whose devices to target (via Get-ManagedFleet / Config\companies.json,
    or the Zabbix host-group name).
.PARAMETER Computers
    Explicit computer names instead of resolving a company.
.PARAMETER Script
    Kit script to run, path under C:\Sysadmin-Toolkit, e.g.
    '17-Security-Audit\Get-LocalAdminAudit.ps1'.
.PARAMETER ScriptArgs
    Arguments for the script as a string, e.g. '-WhatIf' or '-Workstation'.
.PARAMETER OS
    Only devices whose OS matches this wildcard (e.g. 'Windows 11*').
.PARAMETER OnlineOnly
    Only devices Zabbix/AD reports as reachable (a WinRM check still runs).
.PARAMETER Exclude
    Computer names to skip.
.PARAMETER InstallRoot
    Kit location on the targets. Default C:\Sysadmin-Toolkit.
.PARAMETER Credential
    Credential for remoting (and for resolving the fleet), if needed.
.PARAMETER ThrottleLimit
    How many hosts at once. Default 16.
.PARAMETER ReportPath
    Where to write the CSV result. Default: the kit's Reports folder.

.EXAMPLE
    .\Invoke-ToolkitFleet.ps1 -Company Contoso -Script '17-Security-Audit\Get-LocalAdminAudit.ps1' -WhatIf
.EXAMPLE
    .\Invoke-ToolkitFleet.ps1 -Company Contoso -OS 'Windows 11*' -Script '20-Desktop-Experience\Set-Branding.ps1'
.EXAMPLE
    .\Invoke-ToolkitFleet.ps1 -Computers PC01,PC02 -Script '07-Reporting-Health\Get-PCInventory.ps1'

.NOTES
    Needs PowerShell remoting (WinRM) open from here to the targets. Part of the
    Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Company,
    [string[]]$Computers,
    [Parameter(Mandatory)][string]$Script,
    [string]$ScriptArgs = '',
    [string]$OS,
    [switch]$OnlineOnly,
    [string[]]$Exclude,
    [string]$InstallRoot = 'C:\Sysadmin-Toolkit',
    [System.Management.Automation.PSCredential]$Credential,
    [int]$ThrottleLimit = 16,
    [string]$ReportPath
)

function Write-Log {
    param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
    $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -ForegroundColor $c
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Fleet runner" -ForegroundColor White
Write-Host "  ================================" -ForegroundColor DarkGray

# --- resolve targets ----------------------------------------------------------------
$targets = @()
if ($Computers) {
    $targets = @($Computers | ForEach-Object { [pscustomobject]@{ Name=$_; OS=''; Online=$true; Source='Explicit' } })
} else {
    if (-not $Company) { Write-Log "Give -Company (resolved via Zabbix/AD) or -Computers." 'ERROR'; return }
    $fleetScript = Join-Path $PSScriptRoot '21-Fleet\Get-ManagedFleet.ps1'
    if (-not (Test-Path $fleetScript)) { Write-Log "Get-ManagedFleet.ps1 not found — pass -Computers instead." 'ERROR'; return }
    $gp = @{ Company=$Company }
    if ($OS) { $gp.OS = $OS }
    if ($OnlineOnly) { $gp.OnlineOnly = $true }
    try { $targets = @(& $fleetScript @gp | Where-Object { $_ -and $_.Name }) }
    catch { Write-Log "Fleet resolution failed: $($_.Exception.Message)" 'ERROR'; return }
}
if ($Exclude) { $targets = @($targets | Where-Object { $Exclude -notcontains $_.Name }) }
if ($OS -and $Computers) { $targets = @($targets | Where-Object { $_.OS -like $OS }) }

if (-not $targets.Count) { Write-Log "No targets after filtering." 'WARN'; return }

$Script = $Script -replace '/','\'
$scriptFull = ($InstallRoot.TrimEnd('\')) + '\' + $Script.TrimStart('\')
Write-Host ''
Write-Host "  Script : $scriptFull $ScriptArgs" -ForegroundColor Gray
Write-Host "  Targets: $($targets.Count)" -ForegroundColor Gray
$targets | Sort-Object Name | Format-Table Name, OS, Online, Source -AutoSize | Out-Host

# --- WhatIf: list and stop ----------------------------------------------------------
if ($WhatIfPreference) {
    Write-Log "-WhatIf: would run the script on the $($targets.Count) host(s) above. Nothing was run." 'INFO'
    return
}
if (-not $PSCmdlet.ShouldProcess("$($targets.Count) host(s)", "Run $Script")) { return }

# --- reachability (WinRM) -----------------------------------------------------------
Write-Log "Checking WinRM reachability..." 'STEP'
$online=@(); $offline=@()
foreach ($t in $targets) {
    $ok=$false
    try { $ok=[bool](Test-WSMan -ComputerName $t.Name -ErrorAction Stop) } catch { $ok=$false }
    if ($ok) { $online += $t.Name } else { $offline += $t.Name }
}
Write-Log ("{0} reachable, {1} offline." -f $online.Count, $offline.Count) $(if($offline.Count){'WARN'}else{'OK'})
if (-not $online.Count) { Write-Log "No reachable hosts — is WinRM open from here? (Enable-PSRemoting on targets / GPO)" 'ERROR'; return }

# --- run ----------------------------------------------------------------------------
$block = {
    param($ScriptFull, $ArgLine)
    $env:SYSADMIN_TOOLKIT_FORCE = '1'
    # Bypass the target's execution policy for this remote process only (no permanent change).
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }
    if (-not (Test-Path -LiteralPath $ScriptFull)) {
        return [pscustomobject]@{ ok=$false; note='kit/script not found on host'; output='' }
    }
    try {
        $cmd = '& "{0}" {1}' -f $ScriptFull, $ArgLine
        $out = Invoke-Expression $cmd 2>&1 | Out-String
        return [pscustomobject]@{ ok=$true; note='ran'; output=$out.Trim() }
    } catch {
        return [pscustomobject]@{ ok=$false; note=$_.Exception.Message; output='' }
    }
}

Write-Log "Running on $($online.Count) host(s) (throttle $ThrottleLimit)..." 'STEP'
$icParams = @{ ComputerName=$online; ScriptBlock=$block; ArgumentList=@($scriptFull,$ScriptArgs); ThrottleLimit=$ThrottleLimit; ErrorAction='SilentlyContinue' }
if ($Credential) { $icParams.Credential = $Credential }
$results = Invoke-Command @icParams

# --- report -------------------------------------------------------------------------
$rows = @()
foreach ($r in $results) {
    $rows += [pscustomobject]@{ Computer=$r.PSComputerName; Result=$(if($r.ok){'done'}else{'failed'}); Note=$r.note }
}
foreach ($o in $offline) { $rows += [pscustomobject]@{ Computer=$o; Result='offline'; Note='WinRM not reachable' } }

$done=@($rows|Where-Object Result -eq 'done').Count
$failed=@($rows|Where-Object Result -eq 'failed').Count
Write-Host ''
$rows | Sort-Object Result, Computer | Format-Table Computer, Result, Note -AutoSize | Out-Host
Write-Host ("  Summary: {0} done, {1} failed, {2} offline (of {3})." -f $done,$failed,$offline.Count,$targets.Count) -ForegroundColor $(if($failed -or $offline.Count){'Yellow'}else{'Green'})

if (-not $ReportPath) {
    $rp = 'C:\Sysadmin-Toolkit\Reports'
    if (-not (Test-Path $rp)) { try { New-Item -ItemType Directory -Path $rp -Force | Out-Null } catch { $rp = $env:TEMP } }
    $label = if ($Company) { ($Company -replace '[^A-Za-z0-9]','') } else { 'run' }
    $ReportPath = Join-Path $rp ("Fleet_{0}_{1}.csv" -f $label, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
}
try { $rows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8; Write-Log "Report: $ReportPath" 'OK' } catch { }
