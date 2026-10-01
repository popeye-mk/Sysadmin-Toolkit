# 11 — Group Policy: ADMX Central Store

Deploys a Microsoft "Administrative Templates (.admx)" package into your
domain's **GPO Central Store**, so every admin editing Group Policy sees the
same, up-to-date set of policies — instead of whatever ADMX/ADML happens to
ship with the Windows build on their own PC.

Self-contained — copy just this one folder anywhere and it runs.

## What's here

| File | What it is |
| --- | --- |
| `Deploy-GPOCentralStore.ps1` | Extracts the MSI (or uses an already-extracted folder) and deploys it into `\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions`, backing up whatever's already there first. |
| `Backup-GPOs.ps1` | Backs up every GPO in the domain, generates an HTML settings report per GPO, and flags which GPOs changed since the last run. Independent of `Deploy-GPOCentralStore.ps1` — neither script needs the other. |

## Why this matters

Without a Central Store, GPMC on each admin's machine falls back to the
**local** `PolicyDefinitions` folder (`C:\Windows\PolicyDefinitions`) — so two
admins on two different Windows builds can see two different policy sets, and
neither sees anything newer than their own OS. Setting up the Central Store
once fixes that for the whole domain, permanently — GPMC picks it up
automatically the moment it exists, no restart or re-config needed anywhere.

## Where to get the ADMX package

Download the "Administrative Templates (.admx)" MSI for your newest Windows
version from Microsoft's Download Center — search **"Administrative Templates
(.admx) for Windows 11"** (or Server) and pick the latest. It's a normal `.msi`
you save to disk; you point the script at it below. (*SYSVOL* is the special
share every domain controller replicates automatically — the Central Store lives
inside it, which is how the templates reach every admin.)

## Usage

**You downloaded the MSI** (e.g. `Administrative Templates (.admx) for
Windows Server2025 Oct 2025 Update-V3.msi`):

```powershell
# Preview first — nothing is changed
.\Deploy-GPOCentralStore.ps1 -SourceMsi 'C:\Downloads\Administrative Templates (.admx) for Windows Server2025 Oct 2025 Update-V3.msi' -WhatIf

# Then for real
.\Deploy-GPOCentralStore.ps1 -SourceMsi 'C:\Downloads\Administrative Templates (.admx) for Windows Server2025 Oct 2025 Update-V3.msi'
```

The script runs a silent **administrative install** (`msiexec /a`) — this
unpacks the ADMX/ADML files to a folder without installing or registering
anything on the machine you run it from. It then finds the resulting
`PolicyDefinitions` folder on its own.

**You already extracted/installed it yourself** — point straight at the
`PolicyDefinitions` folder it created:

```powershell
.\Deploy-GPOCentralStore.ps1 -SourcePolicyDefinitions 'C:\Program Files (x86)\Microsoft Group Policy\Windows Server 2025 Oct 2025 Update (.admx)\PolicyDefinitions'
```

## What it does, in order

1. Extract the MSI (skip if you passed an already-extracted folder).
2. Detect your domain (or pass `-DomainDns contoso.local` if this machine
   isn't domain-joined, e.g. you're running it from a management VM).
3. **Back up** the existing Central Store (if one exists) to
   `C:\Sysadmin-Toolkit\Backups\CentralStore_<timestamp>` — skippable with
   `-SkipBackup`, not recommended.
4. Create the Central Store if it doesn't exist yet, then copy the new
   `.admx`/`.adml` files in. Existing templates you're not updating are left
   untouched — this only adds/overwrites what's in the source.

## How to check it worked

Open **Group Policy Management** (`gpmc.msc`), edit any GPO, and expand
**Computer Configuration → Policies → Administrative Templates**. At the top you
should see **"Administrative Templates: Policy definitions (ADMX files) retrieved
from the central store."** That line is your confirmation — GPMC is now reading
the shared templates you just deployed, not the local ones.

## Requirements

- Run from a machine with line-of-sight to a **writable domain controller**
  (a domain-joined admin workstation, or a DC itself).
- Signed in as **Domain Admin**, or an account delegated write access to
  `\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions`.
- On a multi-DC domain, allow a few minutes for the change to reach every DC
  (normal SYSVOL/DFSR replication — not instant, not a sign anything failed).

## Rolling back

If something's wrong after an update, the pre-change backup is sitting in
`Backups\CentralStore_<timestamp>`. Copy its contents back over the Central
Store path to restore exactly what was there before.

## Backing up and reporting on GPOs themselves

`Backup-GPOs.ps1` is a separate concern from the Central Store above — it
backs up the GPO *objects* (the policies you've configured), not the ADMX
template definitions:

```powershell
.\Backup-GPOs.ps1 -WhatIf
.\Backup-GPOs.ps1                # full backup + HTML report per GPO
.\Backup-GPOs.ps1 -SkipReport    # backup only, faster
```

Each run writes a dated folder under `Backups\GPO\<timestamp>\` with the
Backup-GPO output plus an `Reports\<GPO name>.html` per GPO. It also keeps a
small version snapshot (`_lastversions.json`) so each run after the first
tells you which GPOs changed since the previous one — a lightweight "what
changed" list without diffing full backups by hand. Requires the
GroupPolicy module (RSAT: Group Policy Management).
