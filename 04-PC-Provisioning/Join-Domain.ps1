<#
.SYNOPSIS
    Join a PC to an Active Directory domain (optionally renaming and placing it
    in a specific OU in the same step).

.DESCRIPTION
    Wraps Add-Computer with clear prompts and a dry-run. Prompts for domain
    credentials securely (or accepts a -Credential you built earlier). Can
    rename the machine and drop it straight into the target OU so it lands under
    the right GPOs. Queues a reboot but does not force one unless you pass
    -Restart.

.PARAMETER Domain
    FQDN of the domain, e.g. 'contoso.local'.
.PARAMETER NewName
    Optional new computer name to set during the join.
.PARAMETER OUPath
    Optional target OU DN, e.g. 'OU=Workstations,DC=contoso,DC=local'.
.PARAMETER Credential
    Domain account with join rights. If omitted, you'll be prompted.
.PARAMETER Restart
    Reboot automatically after a successful join.

.EXAMPLE
    .\Join-Domain.ps1 -Domain contoso.local -WhatIf
.EXAMPLE
    .\Join-Domain.ps1 -Domain contoso.local -NewName PC-HR-04 -OUPath 'OU=Workstations,DC=contoso,DC=local' -Restart

.NOTES
    Run as Administrator. The machine must be able to resolve and reach a domain
    controller (DNS pointed at the DC). Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Domain,
    [string]$NewName,
    [string]$OUPath,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Restart,
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
if (-not $PSBoundParameters.ContainsKey('Domain')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DomainDns'; if ($null -ne $__v) { $Domain = $__v; $__cfgUsed += 'ActiveDirectory.DomainDns' } }
if (-not $PSBoundParameters.ContainsKey('OUPath')) { $__v = Get-ToolkitSetting 'ActiveDirectory.ComputerOU'; if ($null -ne $__v) { $OUPath = $__v; $__cfgUsed += 'ActiveDirectory.ComputerOU' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $Domain) { Write-Host "  [ERROR] Missing: -Domain <dns name> (or ActiveDirectory.DomainDns in Config)" -ForegroundColor Red; return }


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
Write-Banner "Domain Join"
if (-not (Assert-Admin)) { return }

# already joined?
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $Domain) {
    Write-Log "This PC is already joined to $Domain." 'INFO'; return
}

# quick reachability sanity check
Write-Log "Checking domain reachability ($Domain)..." 'STEP'
if (-not (Test-Connection -ComputerName $Domain -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Write-Log "Could not ping $Domain. Make sure DNS points at a domain controller before joining." 'WARN'
}

if (-not $Credential) {
    if (-not [Environment]::UserInteractive) { Write-Log "No -Credential and no interactive session; cannot prompt. Aborting." 'ERROR'; return }
    $Credential = Get-Credential -Message "Domain account with rights to join $Domain (e.g. CONTOSO\admin)"
}

$params = @{ DomainName = $Domain; Credential = $Credential; Force = $true; ErrorAction = 'Stop' }
if ($NewName) { $params.NewName = $NewName }
if ($OUPath)  { $params.OUPath  = $OUPath }

$desc = "Join $Domain" + $(if ($NewName) { " as $NewName" } else { '' }) + $(if ($OUPath) { " into $OUPath" } else { '' })
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $desc)) {
    try {
        Add-Computer @params
        Write-Log "Joined $Domain successfully." 'OK'
        if ($Restart) {
            Write-Log "Rebooting in 10s..." 'INFO'
            if ([Environment]::UserInteractive) { Start-Sleep 10 }
            Restart-Computer -Force
        } else {
            Write-Host ''
            Write-Host "  Joined. Reboot to complete the join." -ForegroundColor Green
        }
    } catch {
        Write-Log "Join failed: $($_.Exception.Message)" 'ERROR'
    }
}
