<#
.SYNOPSIS
    Domain health, one shot: replication, SYSVOL, FSMO holders, dcdiag — the
    "does AD feel fine?" check you run first when something's off.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Runs:
      1. dcdiag (against one DC or every DC in the domain) and counts pass/fail.
      2. repadmin /replsummary — domain-wide replication status.
      3. FSMO role holders (Schema/Domain Naming/PDC/RID/Infrastructure masters).
      4. SYSVOL + NETLOGON share reachability on every DC.

    Read-only. Scores a simple Healthy / Attention / Action needed grade (same
    idea as 07-Reporting-Health\Invoke-HealthCheck.ps1, applied to AD instead
    of a single PC) and writes an HTML report.

.PARAMETER DomainController
    Test one specific DC by name. Default: every DC in the current domain.
.PARAMETER SkipDcdiag
    Skip the dcdiag pass (it's the slowest step) — useful for a quick
    replication-only check.

.EXAMPLE
    .\Test-ADHealth.ps1
.EXAMPLE
    .\Test-ADHealth.ps1 -DomainController DC01
.EXAMPLE
    .\Test-ADHealth.ps1 -SkipDcdiag

.NOTES
    Run from a domain-joined machine with RSAT (Active Directory module,
    dcdiag.exe, repadmin.exe — both ship with RSAT-AD-Tools / on any DC).
    Read-only: nothing here changes AD. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$DomainController,
    [switch]$SkipDcdiag
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
if (-not $PSBoundParameters.ContainsKey('DomainController')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DomainController'; if ($null -ne $__v) { $DomainController = $__v; $__cfgUsed += 'ActiveDirectory.DomainController' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- standalone-safe helpers (no _Common dependency) --------------------------
function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Reports')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: AD Health Check" -ForegroundColor White
Write-Host "  ====================================" -ForegroundColor DarkGray

if (-not (Get-Module -ListAvailable ActiveDirectory)) {
    Write-Log "ActiveDirectory module not found (install RSAT: Active Directory module)." 'ERROR'; return
}
Import-Module ActiveDirectory -ErrorAction Stop

try {
    $domain = Get-ADDomain -ErrorAction Stop
    $forest = Get-ADForest -ErrorAction Stop
} catch {
    Write-Log "Could not query AD (not domain-joined, or no DC reachable): $($_.Exception.Message)" 'ERROR'; return
}

$dcs = if ($DomainController) { @($DomainController) }
       else { (Get-ADDomainController -Filter *).HostName }

Write-Log "Domain: $($domain.DNSRoot)  |  DCs to check: $($dcs -join ', ')" 'INFO'

$issues  = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$sections = New-Object System.Collections.Generic.List[string]  # HTML fragments

# --- 1. FSMO role holders ------------------------------------------------------
Write-Log "Checking FSMO role holders..." 'STEP'
$fsmo = [ordered]@{
    'Schema Master'          = $forest.SchemaMaster
    'Domain Naming Master'   = $forest.DomainNamingMaster
    'PDC Emulator'           = $domain.PDCEmulator
    'RID Master'             = $domain.RIDMaster
    'Infrastructure Master'  = $domain.InfrastructureMaster
}
foreach ($role in $fsmo.GetEnumerator()) {
    if ($role.Value) { Write-Log "  $($role.Key): $($role.Value)" 'OK' }
    else { $issues.Add("FSMO role '$($role.Key)' has no holder"); Write-Log "  $($role.Key): NOT FOUND" 'ERROR' }
}
$fsmoRows = ($fsmo.GetEnumerator() | ForEach-Object { "<tr><td>$($_.Key)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Value))</td></tr>" }) -join "`n"

# --- 2. SYSVOL / NETLOGON reachability -----------------------------------------
Write-Log "Checking SYSVOL / NETLOGON on each DC..." 'STEP'
$shareRows = New-Object System.Collections.Generic.List[string]
foreach ($dc in $dcs) {
    $sysvolOk   = Test-Path "\\$dc\SYSVOL" -ErrorAction SilentlyContinue
    $netlogonOk = Test-Path "\\$dc\NETLOGON" -ErrorAction SilentlyContinue
    $status = if ($sysvolOk -and $netlogonOk) { 'OK' } else { 'WARN' }
    if ($status -eq 'WARN') { $warnings.Add("$dc — SYSVOL/NETLOGON not both reachable") }
    Write-Log "  ${dc}: SYSVOL=$sysvolOk  NETLOGON=$netlogonOk" $status
    $shareRows.Add("<tr><td>$dc</td><td>$sysvolOk</td><td>$netlogonOk</td></tr>")
}

# --- 3. repadmin /replsummary ----------------------------------------------------
Write-Log "Running repadmin /replsummary..." 'STEP'
$replText = ''
$replFailCount = 0
if (Get-Command repadmin.exe -ErrorAction SilentlyContinue) {
    $replText = (& repadmin.exe /replsummary) -join "`n"
    # crude but effective: lines with a non-zero fail count look like "... 3 / 10   0"
    $replFailCount = ([regex]::Matches($replText, '\b(\d+)\s*/\s*\d+\s+\d+\s*$', 'Multiline') |
        Where-Object { [int]$_.Groups[1].Value -gt 0 }).Count
    if ($replFailCount -gt 0) {
        $issues.Add("$replFailCount replication link(s) showing failures — see repadmin output")
        Write-Log "  $replFailCount replication link(s) with failures." 'ERROR'
    } else {
        Write-Log "  No replication failures reported." 'OK'
    }
} else {
    $warnings.Add("repadmin.exe not found — install RSAT-AD-Tools to include replication status")
    Write-Log "  repadmin.exe not found — skipping (install RSAT-AD-Tools)." 'WARN'
}

# --- 4. dcdiag -------------------------------------------------------------------
$dcdiagResults = New-Object System.Collections.Generic.List[pscustomobject]
if (-not $SkipDcdiag) {
    if (Get-Command dcdiag.exe -ErrorAction SilentlyContinue) {
        foreach ($dc in $dcs) {
            Write-Log "Running dcdiag against $dc (this can take a minute)..." 'STEP'
            $out = (& dcdiag.exe /s:$dc /q) -join "`n"
            $failedTests = [regex]::Matches($out, 'Failed test (\S+)') | ForEach-Object { $_.Groups[1].Value }
            if ($failedTests.Count -gt 0) {
                $issues.Add("${dc}: dcdiag failed test(s): $($failedTests -join ', ')")
                Write-Log "  ${dc}: FAILED — $($failedTests -join ', ')" 'ERROR'
            } else {
                Write-Log "  ${dc}: all tests passed (or no output — check manually if that seems wrong)." 'OK'
            }
            $dcdiagResults.Add([pscustomobject]@{ DC = $dc; FailedTests = ($failedTests -join ', '); RawOutput = $out })
        }
    } else {
        $warnings.Add("dcdiag.exe not found — install RSAT-AD-Tools to include this check")
        Write-Log "dcdiag.exe not found — skipping (install RSAT-AD-Tools)." 'WARN'
    }
} else {
    Write-Log "Skipping dcdiag (-SkipDcdiag)." 'INFO'
}

# --- score + report ----------------------------------------------------------------
$grade = if ($issues.Count -eq 0 -and $warnings.Count -eq 0) { 'Healthy' }
         elseif ($issues.Count -eq 0) { 'Attention' }
         else { 'Action needed' }
$gradeColor = @{ Healthy = '#2e7d32'; Attention = '#f9a825'; 'Action needed' = '#c62828' }[$grade]

Write-Host ''
Write-Host "  Overall: $grade" -ForegroundColor $(@{ Healthy='Green'; Attention='Yellow'; 'Action needed'='Red' }[$grade])
if ($issues.Count)   { Write-Host "  Issues:   $($issues -join ' | ')" -ForegroundColor Red }
if ($warnings.Count) { Write-Host "  Warnings: $($warnings -join ' | ')" -ForegroundColor Yellow }

$root  = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\ADHealth_{0}.html" -f $stamp)

$dcdiagHtml = if ($dcdiagResults.Count) {
    ($dcdiagResults | ForEach-Object {
        $status = if ($_.FailedTests) { "FAILED: $($_.FailedTests)" } else { 'OK' }
        "<tr><td>$($_.DC)</td><td>$status</td></tr>"
    }) -join "`n"
} else { '<tr><td colspan="2">skipped</td></tr>' }

$html = @"
<html><head><title>AD Health — $($domain.DNSRoot) — $stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
h1{margin-bottom:0} .grade{display:inline-block;padding:4px 14px;border-radius:4px;color:#fff;background:$gradeColor;font-weight:bold}
table{border-collapse:collapse;margin:1em 0;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left}
th{background:#f0f0f0} .issue{color:#c62828} .warn{color:#f9a825}
</style></head><body>
<h1>AD Health — $($domain.DNSRoot)</h1>
<p>$stamp &nbsp; <span class="grade">$grade</span></p>

<h2>Issues</h2>
<ul>$(if ($issues.Count) { ($issues | ForEach-Object { "<li class='issue'>$_</li>" }) -join "`n" } else { '<li>None</li>' })</ul>

<h2>Warnings</h2>
<ul>$(if ($warnings.Count) { ($warnings | ForEach-Object { "<li class='warn'>$_</li>" }) -join "`n" } else { '<li>None</li>' })</ul>

<h2>FSMO role holders</h2>
<table><tr><th>Role</th><th>Holder</th></tr>$fsmoRows</table>

<h2>SYSVOL / NETLOGON reachability</h2>
<table><tr><th>DC</th><th>SYSVOL</th><th>NETLOGON</th></tr>$($shareRows -join "`n")</table>

<h2>dcdiag summary</h2>
<table><tr><th>DC</th><th>Result</th></tr>$dcdiagHtml</table>

<h2>repadmin /replsummary (raw)</h2>
<pre>$([System.Net.WebUtility]::HtmlEncode($replText))</pre>

</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
Write-Log "AD health check complete — $grade" 'OK'
