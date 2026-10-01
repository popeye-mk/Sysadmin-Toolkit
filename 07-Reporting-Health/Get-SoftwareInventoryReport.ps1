<#
.SYNOPSIS
    Fleet-wide installed-software rollup — what's out there, how many
    machines have it, and what's flagged as long past end-of-life.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    Get-PCInventory.ps1 next to it (that one gives you one machine's full
    picture including its software list; this one rolls software up ACROSS
    machines so you can see "which title/version is everywhere" and "who's
    still got something that should've been gone years ago").

    Reads the standard uninstall-registry locations (fast, unlike
    Win32_Product, and doesn't trigger an MSI repair scan) on the local
    machine or one or more remote machines, then rolls the results up by
    title + version and flags anything matching EOLSoftwareList.json next to
    this script.

    That EOL list is a small, honestly-scoped seed — a handful of software
    titles that are unambiguously, long out of support. It is NOT a live or
    authoritative feed (nothing here can be, without a service that keeps
    itself current) — edit the JSON file yourself as you find things worth
    tracking in your own environment. Same "don't fake freshness" discipline
    as the rest of this kit.

.PARAMETER ComputerName
    One or more machines to inventory. Default: local machine only.
.PARAMETER EOLListPath
    Path to the EOL reference JSON. Default: EOLSoftwareList.json next to
    this script.
.PARAMETER FlaggedOnly
    Only show rollup rows that matched something in the EOL list.

.EXAMPLE
    .\Get-SoftwareInventoryReport.ps1
.EXAMPLE
    .\Get-SoftwareInventoryReport.ps1 -ComputerName PC01,PC02,PC03 -FlaggedOnly

.NOTES
    Remote checks use PowerShell remoting (Invoke-Command) — needs WinRM
    enabled on the target. Read-only. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$EOLListPath = (Join-Path $PSScriptRoot 'EOLSoftwareList.json'),
    [switch]$FlaggedOnly
)

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
Write-Host "  Sysadmin-Toolkit :: Software Inventory Report" -ForegroundColor White
Write-Host "  ================================================" -ForegroundColor DarkGray

$eolEntries = @()
if (Test-Path $EOLListPath) {
    try { $eolEntries = (Get-Content $EOLListPath -Raw | ConvertFrom-Json).entries }
    catch { Write-Log "Could not parse EOL list at ${EOLListPath}: $($_.Exception.Message)" 'WARN' }
} else {
    Write-Log "No EOL list found at $EOLListPath — EOL flagging will be skipped, inventory still runs." 'INFO'
}

$scanBlock = {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object @{n='Name';e={$_.DisplayName}}, @{n='Version';e={$_.DisplayVersion}}, @{n='Publisher';e={$_.Publisher}}
}

$allSoftware = New-Object System.Collections.Generic.List[pscustomobject]
$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }

foreach ($target in $targets) {
    Write-Log "Scanning $target..." 'STEP'
    try {
        if ($target -eq $env:COMPUTERNAME -or $target -eq 'localhost' -or $target -eq '.') {
            $found = & $scanBlock
        } else {
            $found = Invoke-Command -ComputerName $target -ScriptBlock $scanBlock -ErrorAction Stop
        }
        foreach ($item in $found) {
            $allSoftware.Add([pscustomobject]@{ ComputerName = $target; Name = $item.Name; Version = $item.Version; Publisher = $item.Publisher })
        }
    } catch {
        Write-Log "Could not scan ${target}: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $allSoftware.Count) { Write-Log "No software found (or no machines reachable)." 'WARN'; return }
Write-Log "$($allSoftware.Count) software entr(y/ies) collected across $($targets.Count) machine(s)." 'INFO'

# --- roll up by Name + Version, flag EOL matches ---
function Test-EOLMatch {
    param([string]$Name, $Entries)
    foreach ($e in $Entries) {
        if ($Name -match $e.match) { return $e.note }
    }
    return $null
}

$rollup = $allSoftware | Group-Object Name, Version | ForEach-Object {
    $first = $_.Group[0]
    $eolNote = Test-EOLMatch -Name $first.Name -Entries $eolEntries
    [pscustomobject]@{
        Name        = $first.Name
        Version     = $first.Version
        Publisher   = $first.Publisher
        MachineCount = $_.Count
        Machines    = ($_.Group.ComputerName | Select-Object -Unique) -join ', '
        EOLNote     = $eolNote
        Flagged     = [bool]$eolNote
    }
}

if ($FlaggedOnly) { $rollup = $rollup | Where-Object Flagged }
$flaggedCount = @($rollup | Where-Object Flagged).Count

Write-Host ''
if ($flaggedCount) {
    Write-Host "  Flagged (matches EOL list):" -ForegroundColor Red
    $rollup | Where-Object Flagged | Sort-Object Name | ForEach-Object {
        Write-Host ("    {0} {1}  — on {2} machine(s): {3}" -f $_.Name, $_.Version, $_.MachineCount, $_.Machines) -ForegroundColor Red
        Write-Host ("      $($_.EOLNote)") -ForegroundColor DarkYellow
    }
} else {
    Write-Log "Nothing matched the EOL list." 'OK'
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\SoftwareInventory_{0}.html" -f $stamp)
$csvPath = Join-Path $root ("Reports\SoftwareInventory_{0}.csv" -f $stamp)
$rollup | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$rows = ($rollup | Sort-Object @{e={-not $_.Flagged}}, Name | ForEach-Object {
    $cls = if ($_.Flagged) { 'flagged' } else { '' }
    $note = if ($_.EOLNote) { [System.Net.WebUtility]::HtmlEncode($_.EOLNote) } else { '' }
    "<tr class='$cls'><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.Version)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Publisher))</td><td>$($_.MachineCount)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Machines))</td><td>$note</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>Software Inventory — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:.9em}
th{background:#f0f0f0} .flagged td{background:#fdecea;color:#c62828}</style>
</head><body>
<h1>Software Inventory</h1>
<p>$stamp &nbsp; $($targets.Count) machine(s) scanned &nbsp; $($rollup.Count) unique title/version(s) &nbsp; Flagged: $flaggedCount</p>
<table><tr><th>Name</th><th>Version</th><th>Publisher</th><th>Machine count</th><th>Machines</th><th>EOL note</th></tr>
$rows
</table>
<p style="color:#6b7280;font-size:12px">EOL flags come from EOLSoftwareList.json next to this script — a small, manually-maintained seed list, not a live feed. Edit it as you find things worth tracking.</p>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  HTML: $reportPath" -ForegroundColor White
Write-Host "  CSV : $csvPath" -ForegroundColor White
