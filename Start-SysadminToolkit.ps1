<#
.SYNOPSIS
    One menu for the whole kit — pick a section, pick a script, run it.
    Optional convenience only: nothing in the kit needs this to work.

.DESCRIPTION
    Scans the numbered section folders next to this file (01-Users,
    02-Windows11, ...) and offers a two-level menu: sections, then the
    scripts inside the one you picked. Shows each script's one-line SYNOPSIS
    so you don't have to remember names. Runs the script in this console
    (with any extra arguments you type, e.g. "-WhatIf").

    Every script stays fully usable on its own — this just saves you
    navigating folders when you do have the whole kit in front of you.

.PARAMETER Section
    Jump straight to a section by number ("12") or name fragment ("AD-Health").
.PARAMETER Help
    Show this help.

.EXAMPLE
    .\Start-SysadminToolkit.ps1
.EXAMPLE
    .\Start-SysadminToolkit.ps1 -Section 12

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$Section,
    [switch]$Help
)

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

function Get-Synopsis {
    param([string]$Path)
    try {
        $text = Get-Content $Path -TotalCount 40 -ErrorAction Stop
        $idx = [array]::IndexOf(($text | ForEach-Object { $_.Trim() }), '.SYNOPSIS')
        if ($idx -ge 0) {
            $line = ($text[($idx + 1)..([math]::Min($idx + 2, $text.Count - 1))] | ForEach-Object { $_.Trim() }) -join ' '
            if ($line.Length -gt 90) { $line = $line.Substring(0, 87) + '...' }
            return $line
        }
    } catch { }
    return ''
}

$root = $PSScriptRoot
$sections = Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -match '^\d{2}-' } | Sort-Object Name
if (-not $sections) { Write-Host "No numbered section folders found next to this script." -ForegroundColor Red; return }

# Folders whose .ps1 files are NOT standalone entry points: TechToolkit's 22
# departments are function libraries loaded on top of Departments\00-Core.ps1
# by TechToolkit.ps1 / Run-Department.ps1 — they must stay together and are
# never run directly. Launchers\ are .bat wrappers, not scripts.
$notEntryPoints = @('Departments', 'Launchers')

function Get-SectionScripts {
    param($Sec)
    @(Get-ChildItem -Path $Sec.FullName -Filter *.ps1 -File -Recurse |
        Where-Object {
            $rel = $_.FullName.Substring($Sec.FullName.Length + 1)
            $top = ($rel -split '[\\/]')[0]
            $_.Name -notmatch '^_' -and ($notEntryPoints -notcontains $top)
        } | Sort-Object FullName)
}

function Show-ScriptHelp {
    # The "what am I about to run?" card: synopsis, description, switches, examples —
    # all read from the script's own comment-based help, so it's never out of date.
    param($File, [switch]$Full)
    $h = $null
    try { $h = Get-Help -Name $File.FullName -ErrorAction Stop } catch { }
    Write-Host ''
    Write-Host "  $($File.Name)" -ForegroundColor White
    Write-Host ("  " + ('-' * $File.Name.Length)) -ForegroundColor DarkGray
    if (-not $h -or -not $h.Synopsis) { Write-Host "  (this script has no built-in help)" -ForegroundColor DarkGray; return }

    Write-Host ("  " + ($h.Synopsis -replace '\s+', ' ').Trim()) -ForegroundColor Gray

    if ($h.description) {
        $desc = (($h.description | ForEach-Object { $_.Text }) -join "`n") -split "`r?`n"
        $max = if ($Full) { $desc.Count } else { 10 }
        Write-Host ''
        foreach ($l in ($desc | Select-Object -First $max)) { Write-Host "    $l" -ForegroundColor DarkGray }
        if ($desc.Count -gt $max) { Write-Host "    ... ('H n' shows the full text)" -ForegroundColor DarkGray }
    }

    $params = @($h.parameters.parameter | Where-Object { $_ -and $_.name -and $_.name -notin @('WhatIf','Confirm','Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable') })
    if ($params.Count) {
        Write-Host ''
        Write-Host "  Switches:" -ForegroundColor Gray
        foreach ($pp in $params) {
            $d = (($pp.description | ForEach-Object { $_.Text }) -join ' ') -replace '\s+', ' '
            if (-not $Full -and $d.Length -gt 95) { $d = $d.Substring(0, 92) + '...' }
            $t = if ($pp.type.name -and $pp.type.name -ne 'SwitchParameter') { " <$($pp.type.name)>" } else { '' }
            Write-Host ("    -{0}{1}" -f $pp.name, $t) -ForegroundColor White -NoNewline
            Write-Host ("  {0}" -f $d) -ForegroundColor DarkGray
        }
    }

    $ex = @($h.examples.example)
    if ($ex.Count) {
        Write-Host ''
        Write-Host "  Examples (type just the part after the script name, e.g. '-All -WhatIf'):" -ForegroundColor Gray
        foreach ($e in $ex) {
            $code = ($e.code -replace '\s+', ' ').Trim()
            Write-Host "    $code" -ForegroundColor Cyan
        }
    }
    $all = @($h.parameters.parameter | ForEach-Object { $_.name })
    $tips = @()
    if ($all -contains 'WhatIf')   { $tips += "-WhatIf shows what WOULD change without changing anything" }
    if ($all -contains 'Rollback') { $tips += "-Rollback puts back the backup it makes before changing anything" }
    if (-not ($all -contains 'WhatIf') -and -not ($all -contains 'Rollback')) { $tips += "read-only / reporting script — safe to run as is" }
    Write-Host ''
    Write-Host ("  Tip: " + ($tips -join '; ') + ".") -ForegroundColor DarkGray
}

function Show-SectionMenu {
    Write-Host ''
    Write-Host "  Sysadmin-Toolkit" -ForegroundColor White
    Write-Host "  ================" -ForegroundColor DarkGray
    foreach ($s in $sections) {
        $num = $s.Name.Substring(0, 2)
        $name = $s.Name.Substring(3)
        $count = (Get-SectionScripts $s).Count
        $extra = ''
        if (Test-Path (Join-Path $s.FullName 'Departments')) {
            $deps = @(Get-ChildItem (Join-Path $s.FullName 'Departments') -Filter *.ps1 -File | Where-Object { $_.Name -notmatch '^00-' }).Count
            $extra = "  (+ $deps departments, stay together)"
        }
        Write-Host ("  {0}  {1,-24} {2,3} script(s){3}" -f $num, $name, $count, $extra) -ForegroundColor Gray
    }
    Write-Host ''
    $cfg = Join-Path $root 'Config\toolkit-settings.json'
    if (Test-Path -LiteralPath $cfg) { Write-Host "  Config: $cfg  (your environment - scripts read it automatically)" -ForegroundColor DarkGray }
    else { Write-Host "  No Config folder found - scripts use their built-in defaults or ask." -ForegroundColor DarkYellow }
    Write-Host "  Also at the root: Invoke-ToolkitFleet.ps1 (run a script across a company), Install-AllScheduledTasks.ps1, Runbooks\, Docs\, Tests\" -ForegroundColor DarkGray
    Write-Host "  Type a section number (or part of its name), Q to quit." -ForegroundColor DarkGray
}

function Resolve-Section {
    param([string]$Choice)
    $c = $Choice.Trim()
    if (-not $c) { return $null }
    $hit = $sections | Where-Object { $_.Name.StartsWith($c.PadLeft(2, '0')) -and $c -match '^\d{1,2}$' } | Select-Object -First 1
    if (-not $hit) { $hit = $sections | Where-Object { $_.Name -like "*$c*" } | Select-Object -First 1 }
    return $hit
}

function Show-ScriptMenu {
    param($Sec)
    $scripts = Get-SectionScripts $Sec
    Write-Host ''
    Write-Host "  $($Sec.Name)" -ForegroundColor White
    Write-Host ("  " + ('=' * $Sec.Name.Length)) -ForegroundColor DarkGray
    if (Test-Path (Join-Path $Sec.FullName 'README.md')) { Write-Host "  (README.md in this folder has the full detail)" -ForegroundColor DarkGray }
    if (Test-Path (Join-Path $Sec.FullName 'Departments')) {
        Write-Host "  The 22 departments in Departments\ are loaded by TechToolkit.ps1 / Run-Department.ps1 —" -ForegroundColor DarkYellow
        Write-Host "  they stay together as one folder and aren't run on their own. Pick one of the entry points below." -ForegroundColor DarkYellow
    }
    for ($i = 0; $i -lt $scripts.Count; $i++) {
        $rel = $scripts[$i].FullName.Substring($Sec.FullName.Length + 1)
        Write-Host ("  {0,2}  {1}" -f ($i + 1), $rel) -ForegroundColor Gray
        $syn = Get-Synopsis $scripts[$i].FullName
        if ($syn) { Write-Host ("      {0}" -f $syn) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host "  Number = show what it does, then run it.  Number + arguments runs directly (e.g. '3 -WhatIf')." -ForegroundColor DarkGray
    Write-Host "  H + number = full help (e.g. 'H 3').  B = back, Q = quit." -ForegroundColor DarkGray
    return $scripts
}

$current = if ($Section) { Resolve-Section $Section } else { $null }
if ($Section -and -not $current) { Write-Host "  No section matches '$Section'." -ForegroundColor Yellow }

while ($true) {
    if (-not $current) {
        Show-SectionMenu
        $choice = Read-Host '  >'
        if ($choice -match '^(q|quit|exit)$') { return }
        $current = Resolve-Section $choice
        if (-not $current) { Write-Host "  No section matches '$choice'." -ForegroundColor Yellow }
        continue
    }

    $scripts = Show-ScriptMenu $current
    $choice = Read-Host '  >'
    if ($choice -match '^(q|quit|exit)$') { return }
    if ($choice -match '^(b|back)$') { $current = $null; continue }

    # 'H 3' / '? 3' / 'help 3' = full help for script 3, nothing runs
    if ($choice -match '^(h|\?|help)\s*(\d+)$') {
        $n = [int]$Matches[2]
        if ($n -ge 1 -and $n -le $scripts.Count) { Show-ScriptHelp $scripts[$n - 1] -Full; Write-Host "  (Enter to return to the list)" -ForegroundColor DarkGray; [void](Read-Host) }
        else { Write-Host "  Pick a number between 1 and $($scripts.Count)." -ForegroundColor Yellow }
        continue
    }

    $parts = $choice.Trim() -split '\s+', 2
    if ($parts[0] -notmatch '^\d+$' -or [int]$parts[0] -lt 1 -or [int]$parts[0] -gt $scripts.Count) {
        Write-Host "  Pick a number between 1 and $($scripts.Count)." -ForegroundColor Yellow; continue
    }
    $target = $scripts[[int]$parts[0] - 1]
    $extraArgs = if ($parts.Count -gt 1) { $parts[1] } else { '' }

    # Number alone: show the card first, then ask what to run — so you always know what you're getting.
    if (-not $extraArgs) {
        Show-ScriptHelp $target
        Write-Host "  Enter = run with no arguments   |   type arguments (e.g. -WhatIf) then Enter   |   B = back" -ForegroundColor Gray
        $ans = Read-Host '  >'
        if ($ans -match '^(q|quit|exit)$') { return }
        if ($ans -match '^(b|back)$') { continue }
        $extraArgs = $ans.Trim()
    }

    Write-Host ''
    Write-Host "  Running: $($target.FullName) $extraArgs" -ForegroundColor Cyan
    Write-Host ''
    try {
        Push-Location $target.DirectoryName
        if ($extraArgs) { Invoke-Expression "& '$($target.FullName)' $extraArgs" }
        else { & $target.FullName }
    } catch {
        Write-Host "  Script ended with an error: $($_.Exception.Message)" -ForegroundColor Red
    } finally { Pop-Location }
    Write-Host ''
    Write-Host "  (done — Enter to return to the menu)" -ForegroundColor DarkGray
    [void](Read-Host)
}
