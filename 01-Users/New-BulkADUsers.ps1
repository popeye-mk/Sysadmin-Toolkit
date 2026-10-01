<#
.SYNOPSIS
    Create many AD users from a CSV — for class intakes, seasonal staff, or a
    batch of new hires.

.DESCRIPTION
    Reads a CSV and creates one account per row. Generates a strong temporary
    password for each, forces a change at first logon, and writes a results CSV
    listing every account with its temp password and status so you can hand out
    credentials and see what failed at a glance.

    Expected CSV columns (header row required):
        GivenName,Surname,SamAccountName,OU,Groups,Title,Department
    - SamAccountName optional (auto-built from first initial + surname if blank).
    - OU optional per row if you pass -DefaultOU.
    - Groups: semicolon-separated, optional.
    - Title / Department: optional.

    Always dry-run first with -WhatIf.

.PARAMETER CsvPath
    Path to the input CSV.
.PARAMETER DefaultOU
    OU used for any row that leaves the OU column blank.
.PARAMETER UpnSuffix
    UPN domain; defaults to the AD DNS root.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\newhires.csv -DefaultOU 'OU=Staff,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\newhires.csv -DefaultOU 'OU=Staff,DC=contoso,DC=local'

.NOTES
    Run as Administrator with the AD module. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$DefaultOU,
    [string]$UpnSuffix,
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
if (-not $PSBoundParameters.ContainsKey('DefaultOU')) { $__v = Get-ToolkitSetting 'ActiveDirectory.NewUserOU'; if ($null -ne $__v) { $DefaultOU = $__v; $__cfgUsed += 'ActiveDirectory.NewUserOU' } }
if (-not $PSBoundParameters.ContainsKey('UpnSuffix')) { $__v = Get-ToolkitSetting 'ActiveDirectory.UpnSuffix'; if ($null -ne $__v) { $UpnSuffix = $__v; $__cfgUsed += 'ActiveDirectory.UpnSuffix' } }
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
Write-Banner "Bulk AD User Create"

if (-not (Assert-Admin)) { return }
if (-not (Test-Path $CsvPath)) { Write-Log "CSV not found: $CsvPath" 'ERROR'; return }
if (-not (Get-Module -ListAvailable ActiveDirectory)) { Write-Log "AD module not found (install RSAT)." 'ERROR'; return }
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $UpnSuffix) { try { $UpnSuffix = (Get-ADDomain).DNSRoot } catch { Write-Log "Pass -UpnSuffix (could not read domain)." 'ERROR'; return } }

$rows = Import-Csv -Path $CsvPath
if (-not $rows) { Write-Log "CSV is empty." 'WARN'; return }
Write-Log "Loaded $($rows.Count) row(s) from $CsvPath" 'INFO'

$results = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    if (-not $r.GivenName -or -not $r.Surname) { Write-Log "Skipping a row missing GivenName/Surname." 'WARN'; continue }

    $sam = if ($r.SamAccountName) { $r.SamAccountName } else {
        ("{0}{1}" -f $r.GivenName.Substring(0,1), $r.Surname).ToLower() -replace '[^a-z0-9]', ''
    }
    $ou  = if ($r.OU) { $r.OU } else { $DefaultOU }
    if (-not $ou) { Write-Log "No OU for $sam and no -DefaultOU; skipping." 'WARN'; continue }

    $display = "$($r.GivenName) $($r.Surname)"
    $upn     = "$sam@$UpnSuffix"
    $status  = 'created'
    $tempPw  = New-StrongPassword -Length 16

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Log "$sam already exists — skipping." 'WARN'
        $results.Add([pscustomobject]@{ SamAccountName=$sam; Display=$display; TempPassword=''; Status='exists' })
        continue
    }

    $p = @{
        Name = $display; GivenName = $r.GivenName; Surname = $r.Surname
        SamAccountName = $sam; UserPrincipalName = $upn; DisplayName = $display
        Path = $ou; Enabled = $true; ChangePasswordAtLogon = $true
        AccountPassword = (ConvertTo-SecureString $tempPw -AsPlainText -Force)
    }
    if ($r.Title)      { $p.Title = $r.Title }
    if ($r.Department) { $p.Department = $r.Department }

    if ($PSCmdlet.ShouldProcess($display, "Create in $ou")) {
        try {
            New-ADUser @p -ErrorAction Stop
            Write-Log "Created $sam" 'OK'
            if ($r.Groups) {
                foreach ($g in ($r.Groups -split ';' | Where-Object { $_ })) {
                    try { Add-ADGroupMember -Identity $g.Trim() -Members $sam -ErrorAction Stop }
                    catch { Write-Log "  group '$g' failed for ${sam}: $($_.Exception.Message)" 'WARN' }
                }
            }
        } catch {
            $status = "FAILED: $($_.Exception.Message)"
            $tempPw = ''
            Write-Log "Create failed for ${sam}: $($_.Exception.Message)" 'ERROR'
        }
        $results.Add([pscustomobject]@{ SamAccountName=$sam; Display=$display; TempPassword=$tempPw; Status=$status })
    }
}

if (-not $WhatIfPreference -and $results.Count) {
    $root = Get-ToolkitRoot
    $out  = Join-Path $root ("Reports\BulkCreate_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))
    $results | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host "  Done. Results (with temp passwords) written to:" -ForegroundColor Green
    Write-Host "  $out" -ForegroundColor White
    Write-Host "  Protect that file — it contains initial passwords. Delete it after handing out credentials." -ForegroundColor DarkYellow
    Write-Log "Bulk create finished: $($results.Count) processed." 'OK'
}
