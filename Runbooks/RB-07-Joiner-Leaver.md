# RB-07 — New employee (joiner) / employee leaving (leaver)

## Joiner

Before the first day, collect: full name, start date, department, job
title, manager, which existing colleague they should mirror ("same access
as Marc"), which licences (M365 E3? Visio?), hardware needed, phone/extension.

1. **Account(s)** — one command for the hybrid flow (creates AD, waits for
   Entra sync, licences + cloud groups):

   ```powershell
   14-Employee-Lifecycle\New-EmployeeOnboard.ps1 -GivenName Jan -Surname Peeters `
       -OU 'OU=Staff,DC=contoso,DC=local' -CopyGroupsFrom mvanden -CopyCloudGroupsFrom marc.vandenberg@contoso.com `
       -Title "Support Engineer" -Department IT -Manager mvanden `
       -UsageLocation BE -LicenseSkuIds "<sku-guid>" -WhatIf
   ```
   Run with `-WhatIf` first, read it, then for real. Save the temp
   password somewhere safe — hand it over in person / by phone, never by
   e-mail.

   AD-only environment → `01-Users\New-ADUserOnboard.ps1`. Cloud-only →
   `09-Entra-Intune\New-EntraUserOnboard.ps1`. Several at once →
   `01-Users\New-BulkADUsers.ps1` with a CSV.

2. **Mailbox / Teams / shared mailboxes** — licence assignment creates the
   mailbox; add them to shared mailboxes and distribution lists the
   colleague-template has.

3. **Device** — `04-PC-Provisioning\Initialize-NewPC.ps1`, then
   `Join-Domain.ps1` (or Autopilot/Intune enrolment if that's your
   process), then the baseline for the OS (`02-Windows11\` or
   `03-Windows10\`), then `Setup-PrintersAndDrives.ps1` if drives/printers
   aren't from GPO.

4. **First-login pack** — send the welcome template
   (`Docs\Communication-Templates.md` → "New user welcome"), in Dutch or
   English as appropriate.

5. **Ticket note**: what was created, groups given, licence, device serial,
   who approved.

## Leaver

Get in writing: who, last day, who takes over their mailbox/files, and
whether it's a friendly leave or an immediate cutoff.

1. **On the last day (or immediately for a cutoff)** — cloud first, then
   AD, one command:

   ```powershell
   14-Employee-Lifecycle\Disable-EmployeeOffboard.ps1 -SamAccountName jpeeters -UpnSuffix contoso.com `
       -Reason "Left 2026-09-30, ticket #1234" -DisabledOU 'OU=Disabled,DC=contoso,DC=local' -WipeDevices -WhatIf
   ```
   It blocks Entra sign-in and revokes sessions first, then strips
   licences/groups, then disables the AD account and randomises the
   password. Group lists are saved under `Backups\` in case they come back.

2. **Mailbox** — convert to a shared mailbox (frees the licence, keeps the
   mail), give the manager access, set an auto-reply. Forwarding only with
   HR/manager approval.

3. **Files** — OneDrive: Entra keeps it ~30 days after deletion by default;
   assign a manager as the retention owner. Home drive / personal share:
   move to the manager's area or archive, don't delete.

4. **Devices** — retrieve laptop, phone, badge, keys, tokens. Intune retire
   was requested by the script if `-WipeDevices` was passed. Reset the
   laptop before reissuing: `04-PC-Provisioning\Initialize-NewPC.ps1`.

5. **Shared secrets they knew** — any shared/service account password they
   had (Wi-Fi PSK, admin accounts, vendor portals): rotate them. This is the
   step everyone skips.

6. **Delete the account** only after your retention period (often 30–90
   days), as a separate, deliberate action. The scripts never delete.

## Both

Log it. Joiner/leaver records are what auditors and future-you ask for.
