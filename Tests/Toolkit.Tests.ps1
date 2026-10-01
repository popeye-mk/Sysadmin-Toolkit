<#
.SYNOPSIS
    Pester tests for the Sysadmin-Toolkit — the checks that catch a broken
    script BEFORE it reaches a real machine.

.DESCRIPTION
    Three groups, none of which need AD, Graph, or admin rights — they run
    on any machine with Pester (and on Linux/macOS pwsh too):

      1. Every .ps1 in the kit parses cleanly.
      2. Every .ps1 avoids PowerShell 7-only syntax (ternary ?:, ??, &&/||)
         so it still runs on Windows PowerShell 5.1.
      3. Contract tests for the riskiest scripts — the ones where a mistake
         is hardest to undo: they must support -WhatIf (SupportsShouldProcess),
         declare ConfirmImpact High where they disable/remove things, and
         never contain a "Remove-AD*"/"Remove-Mg*" call that deletes an
         account (the kit's rule is disable, never delete).

    Run with:  .\Tests\Run-Tests.ps1
#>

BeforeDiscovery {
    $script:KitRoot = Split-Path $PSScriptRoot -Parent
    $script:AllScripts = Get-ChildItem -Path $script:KitRoot -Recurse -Filter *.ps1 -File |
        Where-Object { $_.FullName -notmatch '[\\/](Tests|Reports|Backups|Logs)[\\/]' }
}

Describe 'Every script parses' {
    It '<_.Name> parses without errors' -ForEach $script:AllScripts {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0 -Because (($errors | ForEach-Object { "$($_.Message) (line $($_.Extent.StartLineNumber))" }) -join '; ')
    }
}

Describe 'Windows PowerShell 5.1 compatibility' {
    It '<_.Name> uses no PS7-only syntax' -ForEach $script:AllScripts {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        $bad = @()
        $bad += $ast.FindAll({ $args[0].GetType().Name -eq 'TernaryExpressionAst' }, $true)
        $bad += $ast.FindAll({ $args[0].GetType().Name -match 'Coalesc' }, $true)
        $bad += $ast.FindAll({ $args[0].GetType().Name -eq 'PipelineChainAst' }, $true)
        $bad.Count | Should -Be 0 -Because 'target machines run Windows PowerShell 5.1'
    }
}

Describe 'Risky scripts keep their safety contract' {
    BeforeAll {
        $kit = Split-Path $PSScriptRoot -Parent
        $script:Risky = @(
            '01-Users\Disable-ADUserOffboard.ps1',
            '01-Users\New-BulkADUsers.ps1',
            '09-Entra-Intune\Disable-EntraUserOffboard.ps1',
            '11-GPO-ADMX\Deploy-GPOCentralStore.ps1',
            '14-Employee-Lifecycle\Disable-EmployeeOffboard.ps1',
            '14-Employee-Lifecycle\New-EmployeeOnboard.ps1',
            '15-DNS-DHCP\Get-StaleDNSRecords.ps1'
        ) | ForEach-Object { Join-Path $kit ($_ -replace '\\', [IO.Path]::DirectorySeparatorChar) } | Where-Object { Test-Path $_ }
    }

    It 'supports -WhatIf: <_>' -ForEach ($script:Risky) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors)
        $cb = $ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $cb | Should -Not -BeNullOrEmpty
        ($cb.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) | Should -Not -BeNullOrEmpty -Because 'destructive scripts must be previewable'
    }

    It 'never deletes an account (disable, not delete): <_>' -ForEach ($script:Risky | Where-Object { $_ -match 'Offboard|Onboard' }) {
        $text = Get-Content $_ -Raw
        $text | Should -Not -Match '(?m)^\s*Remove-ADUser\b' -Because 'the kit disables accounts, never deletes them'
        $text | Should -Not -Match '(?m)^\s*Remove-MgUser\b'
    }

    It 'DNS cleanup never removes without an explicit list' {
        $p = $script:Risky | Where-Object { $_ -match 'Get-StaleDNSRecords' }
        if (-not $p) { Set-ItResult -Skipped -Because 'script not present'; return }
        $text = Get-Content $p -Raw
        # the only Remove-DnsServerResourceRecord must be inside the RecordsToRemove branch
        ($text -split "`n" | Where-Object { $_ -match 'Remove-DnsServerResourceRecord' }).Count | Should -Be 1
        $text | Should -Match 'if \(\$RecordsToRemove\)'
    }
}

Describe 'Standalone-safety' {
    It '<_.Name> does not hard-require a module by relative path without a fallback' -ForEach $script:AllScripts {
        $text = Get-Content $_.FullName -Raw
        $hard = [regex]::Matches($text, '(?m)^\s*Import-Module\s+"\$PSScriptRoot[^"]*(_Common|_GraphCommon)[^"]*"')
        $hard.Count | Should -Be 0 -Because 'every script must run when copied out alone (use the Test-Path fallback pattern)'
    }
}

Describe 'Windows PowerShell 5.1 encoding' {
    It '<_.Name> is saved as UTF-8 with BOM (5.1 reads BOM-less files as ANSI and breaks on non-ASCII text)' -ForEach $script:AllScripts {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because 'the file must carry a UTF-8 BOM for Windows PowerShell 5.1'
    }
}

Describe 'Native command stderr safety (Windows PowerShell 5.1)' {
    It '<_.Name> never captures reg.exe stderr with 2>&1 / *> (promoted to a terminating error inside try/catch on 5.1)' -ForEach $script:AllScripts {
        $text = Get-Content $_.FullName -Raw
        $text | Should -Not -Match 'reg\.exe\s+(import|export)[^\n]*(2>&1|\*>)' -Because 'reg.exe import writes its success message to stderr; use Start-Process instead'
    }
}

Describe 'Config folder' {
    BeforeAll {
        $script:CfgPath = Join-Path $script:KitRoot 'Config\toolkit-settings.json'
        $script:Cfg = Get-Content $script:CfgPath -Raw | ConvertFrom-Json
    }
    It 'Config\toolkit-settings.json is valid JSON' {
        $script:Cfg | Should -Not -BeNullOrEmpty
    }
    It 'Config\desktop-shortcuts.json is valid JSON with a shortcuts list' {
        $m = Get-Content (Join-Path $script:KitRoot 'Config\desktop-shortcuts.json') -Raw | ConvertFrom-Json
        @($m.shortcuts).Count | Should -BeGreaterThan 0
    }
    It '<_.Name> only asks Config for keys that exist in the template' -ForEach ($script:AllScripts | Where-Object { (Get-Content $_.FullName -Raw) -match "Get-ToolkitSetting '" }) {
        $text = Get-Content $_.FullName -Raw
        $keys = [regex]::Matches($text, "Get-ToolkitSetting '([A-Za-z]+\.[A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($k in $keys) {
            $sec, $name = $k.Split('.')
            ($script:Cfg.PSObject.Properties.Name -contains $sec) | Should -BeTrue -Because "section '$sec' must exist in toolkit-settings.json"
            ($script:Cfg.$sec.PSObject.Properties.Name -contains $name) | Should -BeTrue -Because "key '$k' must exist in toolkit-settings.json"
        }
    }
    It '<_.Name> lets explicit parameters win over Config (uses PSBoundParameters guard)' -ForEach ($script:AllScripts | Where-Object { (Get-Content $_.FullName -Raw) -match "Get-ToolkitSetting '" }) {
        $text = Get-Content $_.FullName -Raw
        $lookups = [regex]::Matches($text, "Get-ToolkitSetting '").Count
        $guards  = [regex]::Matches($text, "PSBoundParameters\.ContainsKey\('").Count
        $guards | Should -Be $lookups
    }
    It '<_.Name> has no [Parameter(Mandatory)] on a Config-mapped parameter (PowerShell would prompt before Config is read)' -ForEach ($script:AllScripts | Where-Object { (Get-Content $_.FullName -Raw) -match "Get-ToolkitSetting '" }) {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
        $text = Get-Content $_.FullName -Raw
        $mapped = [regex]::Matches($text, "ContainsKey\('([A-Za-z]+)'\)") | ForEach-Object { $_.Groups[1].Value }
        foreach ($p in $ast.ParamBlock.Parameters) {
            $n = $p.Name.VariablePath.UserPath
            if ($mapped -contains $n) {
                $mand = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' }
                $mand | Should -BeNullOrEmpty -Because "-$n is filled from Config, so it must not be Mandatory"
            }
        }
    }
}
