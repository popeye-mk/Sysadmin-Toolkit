# 06 — Debloat & Privacy

Remove pre-installed junk apps and manage startup programs — carefully.

| Script | What it does | Admin? |
| --- | --- | --- |
| `Remove-Bloatware.ps1` | Removes apps from a **curated safe list**. Shows what it *would* remove by default; only acts with `-Execute`. | yes |
| `Get-StartupItems.ps1` | Lists everything that runs at startup; can disable one reversibly with `-Disable`. | admin for machine-level items |

> ⚠️ This is the one section where the safe default is built into the script:
> `Remove-Bloatware` is **dry-run by default** — it lists what it would remove and
> changes nothing until you add `-Execute`.

```powershell
# 1) See what's on the safe-removal list and what would go — no changes:
.\06-Debloat-Privacy\Remove-Bloatware.ps1 -List
.\06-Debloat-Privacy\Remove-Bloatware.ps1

# 2) Actually remove them:
.\06-Debloat-Privacy\Remove-Bloatware.ps1 -Execute
```

Keep something the list would remove with `-Keep "Microsoft.Whatever"`; remove an
extra one with `-Extra "Some.App"`. `-AllUsers` applies to all profiles (needs
admin).

Startup programs:

```powershell
.\06-Debloat-Privacy\Get-StartupItems.ps1                 # list everything
.\06-Debloat-Privacy\Get-StartupItems.ps1 -Disable "Name" # disable one (reversible)
```
