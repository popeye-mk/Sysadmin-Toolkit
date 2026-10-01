<#
.SYNOPSIS
    Map the environment you just walked into — domain, DCs, OUs, GPOs, DHCP,
    DNS, servers, shares, Intune — into one document. The day-1 script.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Read-only.

    Run it from a domain-joined admin workstation (or a DC) with RSAT, and it
    writes a Markdown + HTML "Environment" document describing what it can
    see. Every section is optional: if the module for it isn't installed
    (DHCP, DNS, GroupPolicy, Microsoft.Graph), that section says so and the
    rest still runs. Nothing here changes anything.

    What it collects, per section:
      - This machine (OS, domain membership, who's running it)
      - Active Directory: domain/forest, functional levels, DCs + sites,
        FSMO holders, top-level OU structure, object counts
      - Group Policy: every GPO with status + link count (GroupPolicy module)
      - DHCP: authorized servers, scopes + utilization (DhcpServer module)
      - DNS: zones on the DC (DnsServer module)
      - Servers: every AD computer running a Server OS, with OS + last logon
      - File shares on this machine (or the -FileServer you name)
      - Entra / Intune (only with -IncludeCloud): tenant, device count by OS,
        compliance policy + configuration profile names

.PARAMETER OutputPath
    Folder for the documents. Default: toolkit Reports folder.
.PARAMETER FileServer
    Also enumerate SMB shares on this server name (via CIM/WinRM).
.PARAMETER IncludeCloud
    Also query Entra ID / Intune via Microsoft Graph (prompts for sign-in).
.PARAMETER OUDepth
    How many OU levels deep to show in the OU tree (default 2).

.EXAMPLE
    .\Get-EnvironmentDiscovery.ps1
.EXAMPLE
    .\Get-EnvironmentDiscovery.ps1 -FileServer FS01 -IncludeCloud

.NOTES
    RSAT: Active Directory module at minimum. GroupPolicy, DhcpServer and
    DnsServer modules add their sections when present. Cloud section needs
    Microsoft.Graph + Intune Administrator (read). Read-only throughout.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$FileServer,
    [switch]$IncludeCloud,
    [int]$OUDepth = 2
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
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if (-not $PSBoundParameters.ContainsKey('FileServer')) { $__v = Get-ToolkitSetting 'Shares.FileServer'; if ($null -ne $__v) { $FileServer = $__v; $__cfgUsed += 'Shares.FileServer' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


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
function Connect-ToolkitGraphStandalone {
    param([string[]]$Scopes)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { return $false }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru -ErrorAction SilentlyContinue | Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) { return $true }
    try { Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null; return $true }
    catch { Write-Log "Graph connect failed: $($_.Exception.Message)" 'ERROR'; return $false }
}
function Add-Section {
    param([string]$Title, [string[]]$Lines)
    $script:md.Add("## $Title")
    $script:md.Add('')
    foreach ($l in $Lines) { $script:md.Add($l) }
    $script:md.Add('')
}
function ConvertTo-MdTable {
    param($Objects, [string[]]$Columns)
    if (-not $Objects -or -not @($Objects).Count) { return @('_none found_') }
    # two separate lines (careful: in PowerShell the comma binds tighter than +, so build them one at a time)
    $header = '| ' + ($Columns -join ' | ') + ' |'
    $sep    = '| ' + (($Columns | ForEach-Object { '---' }) -join ' | ') + ' |'
    $out = @($header, $sep)
    foreach ($o in $Objects) {
        $cells = foreach ($c in $Columns) { $v = $o.$c; if ($null -eq $v) { '' } else { ([string]$v) -replace '\|', '\|' -replace "`r?`n", ' ' } }
        $out += '| ' + ($cells -join ' | ') + ' |'
    }
    return $out
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Environment Discovery" -ForegroundColor White
Write-Host "  ===========================================" -ForegroundColor DarkGray

$script:md = New-Object System.Collections.Generic.List[string]
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$md.Add("# Environment Discovery")
$md.Add('')
$md.Add("Generated $stamp on **$env:COMPUTERNAME** by **$env:USERDOMAIN\$env:USERNAME** — read-only snapshot. Sections marked _skipped_ just mean that module wasn't installed where this ran; run again from a machine that has it (or a DC) to fill them in.")
$md.Add('')

# --- 1. this machine ------------------------------------------------------------
Write-Log "This machine..." 'STEP'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
Add-Section 'This machine' @(
    "- Name: **$env:COMPUTERNAME**",
    "- OS: $($os.Caption) ($($os.Version))",
    "- Domain joined: $($cs.PartOfDomain) — $($cs.Domain)",
    "- PowerShell: $($PSVersionTable.PSVersion)"
)

# --- 2. Active Directory --------------------------------------------------------
$adOk = [bool](Get-Module -ListAvailable ActiveDirectory)
if ($adOk) {
    Write-Log "Active Directory..." 'STEP'
    Import-Module ActiveDirectory -ErrorAction Stop
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        $dcs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object HostName, Site, IPv4Address, OperatingSystem, IsGlobalCatalog)
        $userCount = @(Get-ADUser -Filter * -ErrorAction SilentlyContinue).Count
        $enabledUsers = @(Get-ADUser -Filter 'Enabled -eq $true' -ErrorAction SilentlyContinue).Count
        $compCount = @(Get-ADComputer -Filter * -ErrorAction SilentlyContinue).Count
        $groupCount = @(Get-ADGroup -Filter * -ErrorAction SilentlyContinue).Count

        $lines = @(
            "- Domain: **$($domain.DNSRoot)** (NetBIOS $($domain.NetBIOSName)) — functional level $($domain.DomainMode)",
            "- Forest: $($forest.Name) — functional level $($forest.ForestMode)",
            "- Sites: $($forest.Sites -join ', ')",
            "- Users: $userCount ($enabledUsers enabled) · Computers: $compCount · Groups: $groupCount",
            '',
            '**FSMO role holders**',
            '',
            "- Schema Master: $($forest.SchemaMaster)",
            "- Domain Naming Master: $($forest.DomainNamingMaster)",
            "- PDC Emulator: $($domain.PDCEmulator)",
            "- RID Master: $($domain.RIDMaster)",
            "- Infrastructure Master: $($domain.InfrastructureMaster)",
            '',
            '**Domain controllers**',
            ''
        )
        $lines += ConvertTo-MdTable -Objects $dcs -Columns HostName, Site, IPv4Address, OperatingSystem, IsGlobalCatalog

        # OU tree, limited depth
        $lines += @('', "**OU structure (top $OUDepth level(s))**", '')
        $baseDepth = ($domain.DistinguishedName -split ',').Count
        $ous = Get-ADOrganizationalUnit -Filter * -ErrorAction SilentlyContinue | ForEach-Object {
            $depth = (($_.DistinguishedName -split ',').Count - $baseDepth)
            if ($depth -le $OUDepth) { [pscustomobject]@{ DN = $_.DistinguishedName; Depth = $depth; Name = $_.Name } }
        } | Sort-Object DN
        foreach ($ou in $ous) { $lines += ('  ' * ($ou.Depth - 1)) + "- $($ou.Name)" }
        if (-not $ous) { $lines += '_no OUs (or no rights to read them)_' }

        Add-Section 'Active Directory' $lines
    } catch {
        Add-Section 'Active Directory' @("_skipped: $($_.Exception.Message)_")
    }
} else {
    Add-Section 'Active Directory' @('_skipped: ActiveDirectory module not installed here_')
}

# --- 3. Group Policy ------------------------------------------------------------
if (Get-Module -ListAvailable GroupPolicy) {
    Write-Log "Group Policy..." 'STEP'
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        $gpos = Get-GPO -All -ErrorAction Stop | Sort-Object DisplayName | ForEach-Object {
            $links = 0
            try { $links = ([xml](Get-GPOReport -Guid $_.Id -ReportType Xml -ErrorAction Stop)).GPO.LinksTo.Count } catch { }
            [pscustomobject]@{ Name = $_.DisplayName; Status = $_.GpoStatus; Links = $links; Modified = $_.ModificationTime.ToString('yyyy-MM-dd') }
        }
        Add-Section "Group Policy ($(@($gpos).Count) GPOs)" (ConvertTo-MdTable -Objects $gpos -Columns Name, Status, Links, Modified)
    } catch { Add-Section 'Group Policy' @("_skipped: $($_.Exception.Message)_") }
} else { Add-Section 'Group Policy' @('_skipped: GroupPolicy module not installed here_') }

# --- 4. DHCP ---------------------------------------------------------------------
if (Get-Module -ListAvailable DhcpServer) {
    Write-Log "DHCP..." 'STEP'
    try {
        Import-Module DhcpServer -ErrorAction Stop
        $dhcpServers = @(Get-DhcpServerInDC -ErrorAction Stop)
        $lines = @("- Authorized DHCP servers: $(($dhcpServers.DnsName) -join ', ')", '')
        $scopeRows = foreach ($s in $dhcpServers) {
            try {
                Get-DhcpServerv4Scope -ComputerName $s.DnsName -ErrorAction Stop | ForEach-Object {
                    $st = Get-DhcpServerv4ScopeStatistics -ComputerName $s.DnsName -ScopeId $_.ScopeId -ErrorAction SilentlyContinue
                    [pscustomobject]@{ Server = $s.DnsName; Scope = $_.ScopeId; Name = $_.Name; Range = "$($_.StartRange) - $($_.EndRange)"; State = $_.State; PctUsed = if ($st) { [math]::Round($st.PercentageInUse, 1) } else { '' } }
                }
            } catch { [pscustomobject]@{ Server = $s.DnsName; Scope = ''; Name = "(unreachable: $($_.Exception.Message))"; Range = ''; State = ''; PctUsed = '' } }
        }
        $lines += ConvertTo-MdTable -Objects $scopeRows -Columns Server, Scope, Name, Range, State, PctUsed
        Add-Section 'DHCP' $lines
    } catch { Add-Section 'DHCP' @("_skipped: $($_.Exception.Message)_") }
} else { Add-Section 'DHCP' @('_skipped: DhcpServer module not installed here_') }

# --- 5. DNS ----------------------------------------------------------------------
if (Get-Module -ListAvailable DnsServer) {
    Write-Log "DNS..." 'STEP'
    try {
        Import-Module DnsServer -ErrorAction Stop
        $dnsTarget = if ($adOk -and $domain) { $domain.PDCEmulator } else { $env:COMPUTERNAME }
        $zones = Get-DnsServerZone -ComputerName $dnsTarget -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated } |
            Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate
        Add-Section "DNS (queried $dnsTarget)" (ConvertTo-MdTable -Objects $zones -Columns ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate)
    } catch { Add-Section 'DNS' @("_skipped: $($_.Exception.Message)_") }
} else { Add-Section 'DNS' @('_skipped: DnsServer module not installed here_') }

# --- 6. Servers ------------------------------------------------------------------
if ($adOk) {
    Write-Log "Servers..." 'STEP'
    try {
        $servers = Get-ADComputer -Filter 'OperatingSystem -like "*Server*"' -Properties OperatingSystem, LastLogonDate, IPv4Address, Enabled -ErrorAction Stop |
            Sort-Object Name | Select-Object Name, OperatingSystem, IPv4Address, @{n='LastLogon';e={ if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { '' } }}, Enabled
        Add-Section "Servers in AD ($(@($servers).Count))" (ConvertTo-MdTable -Objects $servers -Columns Name, OperatingSystem, IPv4Address, LastLogon, Enabled)
    } catch { Add-Section 'Servers in AD' @("_skipped: $($_.Exception.Message)_") }
}

# --- 7. File shares --------------------------------------------------------------
Write-Log "File shares..." 'STEP'
try {
    $shareTarget = if ($FileServer) { $FileServer } else { $env:COMPUTERNAME }
    if ($FileServer) {
        $cim = New-CimSession -ComputerName $FileServer -ErrorAction Stop
        $shares = Get-SmbShare -CimSession $cim -ErrorAction Stop
        Remove-CimSession $cim -ErrorAction SilentlyContinue
    } else { $shares = Get-SmbShare -ErrorAction Stop }
    $shares = $shares | Where-Object { $_.Name -notmatch '\$$' } | Select-Object Name, Path, Description
    Add-Section "File shares on $shareTarget" (ConvertTo-MdTable -Objects $shares -Columns Name, Path, Description)
} catch { Add-Section 'File shares' @("_skipped: $($_.Exception.Message)_") }

# --- 8. Entra / Intune (opt-in) --------------------------------------------------
if ($IncludeCloud) {
    Write-Log "Entra ID / Intune..." 'STEP'
    if (Connect-ToolkitGraphStandalone -Scopes @('Organization.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All')) {
        try {
            Import-Module Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement -ErrorAction Stop
            $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
            $devices = @(Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop)
            $byOs = $devices | Group-Object OperatingSystem | ForEach-Object { [pscustomobject]@{ OS = $_.Name; Count = $_.Count } }
            $compliancePolicies = @(Get-MgDeviceManagementDeviceCompliancePolicy -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
            $configProfiles = @(Get-MgDeviceManagementDeviceConfiguration -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
            $lines = @(
                "- Tenant: **$($org.DisplayName)** — verified domains: $(($org.VerifiedDomains.Name) -join ', ')",
                "- Intune-managed devices: $($devices.Count)",
                ''
            )
            $lines += ConvertTo-MdTable -Objects $byOs -Columns OS, Count
            $lines += @('', "**Compliance policies ($($compliancePolicies.Count))**", '')
            $lines += if ($compliancePolicies.Count) { $compliancePolicies | ForEach-Object { "- $_" } } else { '_none_' }
            $lines += @('', "**Configuration profiles ($($configProfiles.Count), classic device configurations — Settings Catalog profiles need a different API and aren't listed here)**", '')
            $lines += if ($configProfiles.Count) { $configProfiles | ForEach-Object { "- $_" } } else { '_none_' }
            Add-Section 'Entra ID / Intune' $lines
        } catch { Add-Section 'Entra ID / Intune' @("_skipped: $($_.Exception.Message)_") }
    } else { Add-Section 'Entra ID / Intune' @('_skipped: Microsoft.Graph not installed or sign-in failed_') }
} else {
    Add-Section 'Entra ID / Intune' @('_not queried — re-run with -IncludeCloud to add this section_')
}

# --- write out ---------------------------------------------------------------------
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }
$fileStamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$mdPath = Join-Path $OutputPath "Environment_$fileStamp.md"
$htmlPath = Join-Path $OutputPath "Environment_$fileStamp.html"
$md -join "`n" | Set-Content -Path $mdPath -Encoding UTF8

# minimal Markdown -> HTML (headings, bullets, tables, bold) so it opens nicely without any tooling
$htmlBody = New-Object System.Collections.Generic.List[string]
$inTable = $false; $inList = $false
foreach ($line in $md) {
    $l = [System.Net.WebUtility]::HtmlEncode($line) -replace '\*\*(.+?)\*\*', '<b>$1</b>' -replace '_(.+?)_', '<i>$1</i>'
    if ($line -match '^\| ---') { continue }
    if ($line -match '^\|') {
        $cells = ($line.Trim('|') -split '\|') | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_.Trim()) }
        if (-not $inTable) { $htmlBody.Add('<table><tr>' + (($cells | ForEach-Object { "<th>$_</th>" }) -join '') + '</tr>'); $inTable = $true }
        else { $htmlBody.Add('<tr>' + (($cells | ForEach-Object { "<td>$_</td>" }) -join '') + '</tr>') }
        continue
    } elseif ($inTable) { $htmlBody.Add('</table>'); $inTable = $false }
    if ($line -match '^(\s*)- (.*)') {
        if (-not $inList) { $htmlBody.Add('<ul>'); $inList = $true }
        $htmlBody.Add("<li>$($l -replace '^\s*- ', '')</li>"); continue
    } elseif ($inList) { $htmlBody.Add('</ul>'); $inList = $false }
    if ($line -match '^# (.*)') { $htmlBody.Add("<h1>$($Matches[1])</h1>") }
    elseif ($line -match '^## (.*)') { $htmlBody.Add("<h2>$([System.Net.WebUtility]::HtmlEncode($Matches[1]))</h2>") }
    elseif ($line.Trim()) { $htmlBody.Add("<p>$l</p>") }
}
if ($inTable) { $htmlBody.Add('</table>') }
if ($inList) { $htmlBody.Add('</ul>') }
$html = @"
<html><head><meta charset='utf-8'><title>Environment Discovery — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222;max-width:1100px}
table{border-collapse:collapse;width:100%;margin:.5em 0 1em} td,th{border:1px solid #ccc;padding:5px 9px;text-align:left;font-size:.9em} th{background:#f0f0f0}
h2{border-bottom:2px solid #e6eef7;padding-bottom:4px;margin-top:1.6em}</style></head><body>
$($htmlBody -join "`n")
</body></html>
"@
$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host ''
Write-Host "  Markdown: $mdPath" -ForegroundColor White
Write-Host "  HTML    : $htmlPath" -ForegroundColor White
Write-Log "Environment discovery complete." 'OK'
