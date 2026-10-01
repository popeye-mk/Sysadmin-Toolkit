<#
.SYNOPSIS
    Daily health check for a Windows PC or server — disk, memory, key services,
    pending reboot, updates, uptime, errors, and Defender status — with a
    scored HTML report and optional e-mail.

.DESCRIPTION
    Read-only. Runs a battery of checks, assigns each a PASS / WARN / FAIL, and
    computes a simple health score out of 100. Writes a self-contained HTML
    report (and a compact CSV line for trend tracking). Designed to run
    unattended from Task Scheduler — see Install-HealthCheckTask.ps1.

    Checks:
      - Free disk space on every fixed drive (WARN < 15%, FAIL < 8%).
      - Memory in use (WARN > 85%, FAIL > 95%).
      - Critical services running (list is tunable via -Services).
      - Pending reboot (Component Based Servicing / Windows Update flags).
      - Days since last boot (WARN > 30).
      - Windows Update: days since last successful update scan.
      - System event-log errors in the last 24h (WARN > 10).
      - Microsoft Defender: real-time on + signatures fresh.

.PARAMETER Services
    Extra service names that must be running (added to the sensible defaults).
.PARAMETER EmailTo
    If EmailTo + SmtpServer are set, the HTML report is e-mailed.
.PARAMETER EmailFrom
    If EmailTo + SmtpServer are set, the HTML report is e-mailed.
.PARAMETER SmtpServer
    If EmailTo + SmtpServer are set, the HTML report is e-mailed.
.PARAMETER SmtpPort
    If EmailTo + SmtpServer are set, the HTML report is e-mailed.
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Invoke-HealthCheck.ps1
.EXAMPLE
    .\Invoke-HealthCheck.ps1 -Services 'Spooler','MSSQLSERVER' -EmailTo you@firm.be -EmailFrom pc@firm.be -SmtpServer smtp.firm.be

.NOTES
    Read-only. Some checks read fuller with admin. Part of the Sysadmin-Toolkit
    family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding()]
param(
    [string[]]$Services,
    [string]$EmailTo,
    [string]$EmailFrom,
    [string]$SmtpServer,
    [int]$SmtpPort = 25,
    [string]$OutputPath,
    [switch]$Force
)

$script:__ntForce = $false
if ($Force -or $env:SYSADMIN_TOOLKIT_FORCE -eq '1') { $ConfirmPreference = 'None'; $script:__ntForce = $true }

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
if (-not $PSBoundParameters.ContainsKey('Services')) { $__v = Get-ToolkitSetting 'Monitoring.HealthCheckServices'; if ($null -ne $__v) { $Services = $__v; $__cfgUsed += 'Monitoring.HealthCheckServices' } }
if (-not $PSBoundParameters.ContainsKey('EmailTo')) { $__v = Get-ToolkitSetting 'Alerting.EmailTo'; if ($null -ne $__v) { $EmailTo = $__v; $__cfgUsed += 'Alerting.EmailTo' } }
if (-not $PSBoundParameters.ContainsKey('EmailFrom')) { $__v = Get-ToolkitSetting 'Alerting.EmailFrom'; if ($null -ne $__v) { $EmailFrom = $__v; $__cfgUsed += 'Alerting.EmailFrom' } }
if (-not $PSBoundParameters.ContainsKey('SmtpServer')) { $__v = Get-ToolkitSetting 'Alerting.SmtpServer'; if ($null -ne $__v) { $SmtpServer = $__v; $__cfgUsed += 'Alerting.SmtpServer' } }
if (-not $PSBoundParameters.ContainsKey('SmtpPort')) { $__v = Get-ToolkitSetting 'Alerting.SmtpPort'; if ($null -ne $__v) { $SmtpPort = $__v; $__cfgUsed += 'Alerting.SmtpPort' } }
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- toolkit helpers (standalone-safe) -------------------------------------
# Uses the shared _Common module when run inside the kit. If this script is
# copied out on its own, it self-provides the same helpers so it still runs.
$__common = Join-Path $PSScriptRoot '..\_Common\SysadminToolkit.Common.psm1'
if (Test-Path $__common) {
    Import-Module $__common -Force
} else {
    function Get-ToolkitRoot { param([string]$Path = 'C:\Sysadmin-Toolkit')
        try { foreach ($s in @('','Reports','Backups','Logs')) { $p = if ($s) { Join-Path $Path $s } else { $Path }; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } } } catch { }
        return $Path }
    function Write-Log { param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
        $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
        Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
        try { $lf = Join-Path (Get-ToolkitRoot) ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')); Add-Content -Path $lf -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { } }
    function Write-Banner { param([Parameter(Mandatory)][string]$Title) Write-Host ''; Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White; Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray }
    function Test-Admin { try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } }
    function Assert-Admin { if (Test-Admin) { return $true } Write-Log 'This tool needs Administrator rights. Right-click PowerShell and Run as administrator.' 'ERROR'; return $false }
    function Confirm-Action { param([Parameter(Mandatory)][string]$Question) if ($script:__ntForce) { return $true } if (-not [Environment]::UserInteractive -or $null -eq $Host.UI.RawUI) { return $false } (Read-Host "$Question [y/N]") -match '^(y|yes)$' }
    function New-StrongPassword { param([int]$Length=16)
        $U='ABCDEFGHJKLMNPQRSTUVWXYZ'; $L='abcdefghijkmnpqrstuvwxyz'; $D='23456789'; $S='!@#$%^&*-_=+?'; $all=($U+$L+$D+$S).ToCharArray()
        $ch=@($U[(Get-Random -Maximum $U.Length)],$L[(Get-Random -Maximum $L.Length)],$D[(Get-Random -Maximum $D.Length)],$S[(Get-Random -Maximum $S.Length)])
        for ($i=$ch.Count; $i -lt $Length; $i++){ $ch += $all[(Get-Random -Maximum $all.Length)] }
        -join ($ch | Sort-Object { Get-Random }) }
    function Get-OSInfo { $o=Get-CimInstance Win32_OperatingSystem; $b=[int]$o.BuildNumber
        $t = if ($o.Caption -match 'Server') { 'Server' } elseif ($b -ge 22000) { 'Win11' } elseif ($b -ge 10240) { 'Win10' } else { 'Older' }
        [pscustomobject]@{ Caption=$o.Caption; Version=$o.Version; Build=$b; Tag=$t } }
    function Backup-RegistryKey { param([Parameter(Mandatory)][string]$Path,[string]$Label='key')
        $tag=(($Path -split '\\' | Select-Object -Last 2) -join '_') -replace '[^\w\-]','_'; $o=Join-Path (Get-ToolkitRoot) ("Backups\{0}_{1}_{2}.reg" -f ($Label -replace '[^\w\-]','_'),$tag,(Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        if (-not (Test-Path -LiteralPath "Registry::$Path")) { return $null }
        $rc = (Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $Path), ('"{0}"' -f $o), '/y') -Wait -PassThru -WindowStyle Hidden).ExitCode; if ($rc -eq 0) { Write-Log "Backed up $Path -> $o" 'OK'; return $o }; return $null }
    function Set-RegValue { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Value,[ValidateSet('DWord','String','ExpandString','QWord','Binary')][string]$Type='DWord')
        if ($PSCmdlet.ShouldProcess("$Path\$Name","Set to $Value ($Type)")) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null; Write-Log "Set $Path\$Name = $Value" 'OK' } }
}
# ---------------------------------------------------------------------------
Write-Banner "Health Check — $env:COMPUTERNAME"
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

$checks = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Category, [string]$Name, [ValidateSet('PASS','WARN','FAIL')][string]$State, [string]$Detail) {
    $checks.Add([pscustomobject]@{ Category = $Category; Name = $Name; State = $State; Detail = $Detail })
}

# --- disk --------------------------------------------------------------------
foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
    if (-not $d.Size) { continue }
    $pct = [math]::Round($d.FreeSpace / $d.Size * 100, 0)
    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
    $state = if ($pct -lt 8) { 'FAIL' } elseif ($pct -lt 15) { 'WARN' } else { 'PASS' }
    Add-Result 'Disk' "$($d.DeviceID) free" $state "$pct% free ($freeGB GB)"
}

# --- memory ------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$usedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
$memState = if ($usedPct -gt 95) { 'FAIL' } elseif ($usedPct -gt 85) { 'WARN' } else { 'PASS' }
Add-Result 'Memory' 'RAM in use' $memState "$usedPct% used"

# --- services ----------------------------------------------------------------
$svcList = @('Spooler', 'Dnscache', 'LanmanServer', 'LanmanWorkstation', 'W32Time', 'WinDefend', 'wuauserv')
if ($Services) { $svcList += $Services }
foreach ($s in ($svcList | Select-Object -Unique)) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $svc) { continue }   # not present on this box; skip silently
    $state = if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }
    Add-Result 'Service' $s $state "$($svc.Status)"
}

# --- pending reboot ----------------------------------------------------------
$pending = $false
if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
Add-Result 'System' 'Pending reboot' $(if ($pending) { 'WARN' } else { 'PASS' }) $(if ($pending) { 'A reboot is pending' } else { 'None' })

# --- uptime ------------------------------------------------------------------
$uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
Add-Result 'System' 'Uptime' $(if ($uptimeDays -gt 30) { 'WARN' } else { 'PASS' }) "$uptimeDays days since boot"

# --- windows update ----------------------------------------------------------
try {
    $auto = New-Object -ComObject 'Microsoft.Update.AutoUpdate'
    $last = $auto.Results.LastInstallationSuccessDate
    if ($last) {
        $days = [math]::Round(((Get-Date) - $last).TotalDays, 0)
        Add-Result 'Updates' 'Last install' $(if ($days -gt 40) { 'WARN' } else { 'PASS' }) "$days days ago ($($last.ToString('yyyy-MM-dd')))"
    } else { Add-Result 'Updates' 'Last install' 'WARN' 'No record' }
} catch { Add-Result 'Updates' 'Last install' 'WARN' 'Could not read update history' }

# --- event log errors --------------------------------------------------------
try {
    $errs = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -ErrorAction Stop
    $n = @($errs).Count
    Add-Result 'Events' 'System errors (24h)' $(if ($n -gt 10) { 'WARN' } else { 'PASS' }) "$n critical/error events"
} catch { Add-Result 'Events' 'System errors (24h)' 'PASS' '0 (or log empty)' }

# --- defender ----------------------------------------------------------------
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $rt = $mp.RealTimeProtectionEnabled
    $sigAge = [math]::Round($mp.AntivirusSignatureAge, 0)
    $state = if (-not $rt) { 'FAIL' } elseif ($sigAge -gt 3) { 'WARN' } else { 'PASS' }
    Add-Result 'Security' 'Defender' $state "RT=$rt, signatures $sigAge day(s) old"
} catch { Add-Result 'Security' 'Defender' 'WARN' 'Could not query (3rd-party AV or needs admin)' }

# --- score -------------------------------------------------------------------
$total = $checks.Count
$fail  = ($checks | Where-Object State -eq 'FAIL').Count
$warn  = ($checks | Where-Object State -eq 'WARN').Count
$score = if ($total) { [math]::Max(0, 100 - ($fail * 15) - ($warn * 5)) } else { 0 }
$grade = if ($score -ge 90) { 'Healthy' } elseif ($score -ge 70) { 'Attention' } else { 'Action needed' }

$checks | Format-Table -AutoSize | Out-Host
Write-Host ''
Write-Host "  Health score: $score / 100  ($grade)" -ForegroundColor $(if ($score -ge 90) { 'Green' } elseif ($score -ge 70) { 'Yellow' } else { 'Red' })
Write-Log "Health $score/100 ($grade); $fail fail, $warn warn." 'STEP'

# --- HTML --------------------------------------------------------------------
$scoreColor = if ($score -ge 90) { '#15803d' } elseif ($score -ge 70) { '#b45309' } else { '#b91c1c' }
$css = @"
<style>body{font-family:Segoe UI,Arial;margin:24px;color:#1e2327}h1{font-size:20px;margin:0}
.score{font-size:42px;font-weight:700;color:$scoreColor;margin:6px 0}.sub{color:#6b7280;font-size:12px}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:14px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}th{background:#f5f8fc}
.PASS{color:#15803d;font-weight:600}.WARN{color:#b45309;font-weight:600}.FAIL{color:#b91c1c;font-weight:700}
tr:nth-child(even) td{background:#fafcff}</style>
"@
$rowsHtml = ($checks | ForEach-Object { "<tr><td>$($_.Category)</td><td>$($_.Name)</td><td class='$($_.State)'>$($_.State)</td><td>$($_.Detail)</td></tr>" }) -join "`n"
$html = @"
<!doctype html><html><head><meta charset='utf-8'>$css<title>Health — $env:COMPUTERNAME</title></head><body>
<h1>Health check — $env:COMPUTERNAME</h1>
<div class='score'>$score / 100</div>
<div class='sub'>$grade · $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $fail fail, $warn warn, $($total-$fail-$warn) pass</div>
<table><tr><th>Category</th><th>Check</th><th>State</th><th>Detail</th></tr>$rowsHtml</table>
</body></html>
"@
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "Health_${env:COMPUTERNAME}_$stamp.html"
$csvOut  = Join-Path $OutputPath "Health_trend.csv"
$html | Set-Content -Path $htmlOut -Encoding UTF8
[pscustomobject]@{ Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Computer = $env:COMPUTERNAME; Score = $score; Grade = $grade; Fail = $fail; Warn = $warn } |
    Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8 -Append
Write-Log "HTML: $htmlOut" 'OK'
Write-Log "Trend appended: $csvOut" 'OK'

# --- email -------------------------------------------------------------------
if ($EmailTo -and $SmtpServer) {
    if (-not $EmailFrom) { $EmailFrom = "$env:COMPUTERNAME@local" }
    try {
        $subject = "[Health $score/100 · $grade] $env:COMPUTERNAME $(Get-Date -Format 'yyyy-MM-dd')"
        Send-MailMessage -To $EmailTo -From $EmailFrom -Subject $subject -Body $html -BodyAsHtml -SmtpServer $SmtpServer -Port $SmtpPort -ErrorAction Stop
        Write-Log "E-mailed report to $EmailTo" 'OK'
    } catch { Write-Log "E-mail failed: $($_.Exception.Message)" 'WARN' }
}

try { if ([Environment]::UserInteractive -and -not $EmailTo) { Start-Process $htmlOut } } catch { }

# exit code reflects worst state — handy for monitoring
if ($fail) { exit 2 } elseif ($warn) { exit 1 } else { exit 0 }
