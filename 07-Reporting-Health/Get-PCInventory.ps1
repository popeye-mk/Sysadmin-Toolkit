<#
.SYNOPSIS
    Collect a full per-PC inventory and write a clean HTML report plus a CSV
    summary — a fast asset snapshot for any machine you service.

.DESCRIPTION
    Gathers system/hardware/OS/network/storage details, Windows activation,
    BitLocker status, and installed software (from the registry — fast, unlike
    Win32_Product). Read-only. A few fields (BitLocker) need Administrator.

.PARAMETER OutputPath
    Folder for the reports. Default: C:\TechToolkit\Reports

.EXAMPLE
    .\Get-PCInventory.ps1
.EXAMPLE
    .\Get-PCInventory.ps1 -OutputPath D:\Audits

.NOTES
    Part of the TechToolkit family. Reports contain machine + security details —
    handle like the other TechToolkit reports (don't commit them).
#>

[CmdletBinding()]
param([string]$OutputPath = 'C:\TechToolkit\Reports')

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
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Host "TechToolkit :: Get-PCInventory — collecting..." -ForegroundColor White

$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

# ----- summary -----
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$uptime = (Get-Date) - $os.LastBootUpTime
$summary = [ordered]@{
    'Hostname'      = $env:COMPUTERNAME
    'Manufacturer'  = $cs.Manufacturer
    'Model'         = $cs.Model
    'Serial'        = $bios.SerialNumber
    'CPU'           = $cpu.Name.Trim()
    'RAM (GB)'      = $ramGB
    'OS'            = "$($os.Caption) ($($os.Version), build $($os.BuildNumber))"
    'Logged-on user'= $cs.UserName
    'Last boot'     = $os.LastBootUpTime
    'Uptime'        = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
    'Report time'   = Get-Date
}

# ----- disks -----
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [pscustomobject]@{
        Drive     = $_.DeviceID
        'Size GB' = [math]::Round($_.Size / 1GB, 1)
        'Free GB' = [math]::Round($_.FreeSpace / 1GB, 1)
        '% Free'  = if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100, 0) } else { 0 }
    }
}

# ----- network -----
$net = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | ForEach-Object {
    [pscustomobject]@{
        Adapter = $_.Description
        IPv4    = ($_.IPAddress | Where-Object { $_ -notmatch ':' }) -join ', '
        MAC     = $_.MACAddress
        Gateway = ($_.DefaultIPGateway -join ', ')
    }
}

# ----- activation -----
$act = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
    Select-Object -First 1
$activation = if ($act) { switch ($act.LicenseStatus) { 1 { 'Licensed' } default { "Status $($act.LicenseStatus)" } } } else { 'Unknown' }

# ----- bitlocker -----
$bitlocker = try {
    (Get-BitLockerVolume -ErrorAction Stop | ForEach-Object { "$($_.MountPoint): $($_.VolumeStatus)" }) -join '; '
} catch { 'N/A (needs admin, or not supported)' }

# ----- installed software (registry) -----
$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$software = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object @{n='Name';e={$_.DisplayName}}, @{n='Version';e={$_.DisplayVersion}}, @{n='Publisher';e={$_.Publisher}} |
    Sort-Object Name -Unique

$summary['Activation'] = $activation
$summary['BitLocker']  = $bitlocker

# ----- build HTML -----
$css = @"
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327;background:#fff}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 8px;color:#0b62c4;border-bottom:2px solid #e6eef7;padding-bottom:4px}
 .sub{color:#6b7280;font-size:12px;margin-bottom:8px}
 table{border-collapse:collapse;width:100%;font-size:13px} th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}
 th{background:#f5f8fc} tr:nth-child(even) td{background:#fafcff}
 .k{width:200px;font-weight:600;background:#f5f8fc}
 .low{color:#b91c1c;font-weight:600}
</style>
"@

$sumRows = ($summary.GetEnumerator() | ForEach-Object {
    "<tr><td class='k'>$($_.Key)</td><td>$([System.Web.HttpUtility]::HtmlEncode([string]$_.Value))</td></tr>"
}) -join "`n"

Add-Type -AssemblyName System.Web
$diskTbl = $disks   | ConvertTo-Html -Fragment
$netTbl  = $net     | ConvertTo-Html -Fragment
$swTbl   = $software | ConvertTo-Html -Fragment

$html = @"
<!doctype html><html><head><meta charset='utf-8'>$css<title>Inventory — $env:COMPUTERNAME</title></head><body>
<h1>PC Inventory — $env:COMPUTERNAME</h1>
<div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by TechToolkit</div>
<h2>Summary</h2><table>$sumRows</table>
<h2>Storage</h2>$diskTbl
<h2>Network</h2>$netTbl
<h2>Installed software ($($software.Count))</h2>$swTbl
</body></html>
"@

$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "Inventory_${env:COMPUTERNAME}_$stamp.html"
$csvOut  = Join-Path $OutputPath "Inventory_${env:COMPUTERNAME}_$stamp.csv"

$html | Set-Content -Path $htmlOut -Encoding UTF8
$summary.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Field=$_.Key; Value=$_.Value } } |
    Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8

Write-Host "[+] HTML : $htmlOut" -ForegroundColor Green
Write-Host "[+] CSV  : $csvOut"  -ForegroundColor Green
try { Start-Process $htmlOut } catch { }
