# First-Week Plan — starting as a sysadmin somewhere new

Nobody expects you to know their environment on day one. They *do* notice
who asks good questions, writes things down, and doesn't break anything.
This is the checklist for that. Tick it off, add your answers under each
item — this file becomes your own environment notes.

> New to the kit? Read **`Docs\MANUAL.md`** first (it explains install, the
> Config folder, and how to run things), and keep **`Docs\Command-Reference.md`**
> open for the exact commands. Every script named below is covered there.

## Day 1 — access, orientation, don't touch anything yet

- [ ] Your accounts: normal user account + separate admin account? (If they
      give you one account for both, ask about a separate admin account —
      it's what you'd recommend, and it shows you know why.)
- [ ] Where is documentation kept? (wiki, SharePoint, a folder, someone's
      head?) — get read access.
- [ ] Ticketing system: how do tickets come in, how are they prioritised,
      what's expected of you on response time?
- [ ] Run **`18-Environment-Discovery\Get-EnvironmentDiscovery.ps1`** from an
      admin workstation — read the output that evening. Bring questions
      from it tomorrow.
- [ ] Install the kit on your admin machine: run **`Sysadmin-Toolkit-Setup.exe`**
      (two clicks → `C:\Sysadmin-Toolkit` + desktop shortcut + menu), or copy the
      folder / run `Install-Toolkit.ps1` from the ISO. Set execution policy for
      your sessions if scripts are blocked (`Set-ExecutionPolicy -Scope Process
      Bypass`).
- [ ] Fill in **`C:\Sysadmin-Toolkit\Config\toolkit-settings.json`** once for
      this employer/customer: company + helpdesk info, AD OUs and UPN suffix,
      file server and shares, expected local admins, Zabbix server, report
      folder. Drop the company wallpaper/lock screen/logo in `Config\Branding\`.
      From then on every script uses those values automatically — you don't
      retype them per PC. (One Config folder per customer.)

## Day 2–3 — the questions that matter (ask, write the answers here)

**Backup & recovery**
- What backs up what, how often, where to? _______________________________
- When was the last **restore test**? (If nobody knows: that's a finding,
  not a criticism — note it.) _______________________________
- Is any backup copy offline / immutable (ransomware protection)? ________

**Identity**
- Hybrid (AD + Entra Connect), cloud-only, or AD-only? ___________________
- Where is the Entra Connect server? Who owns it? ________________________
- Is MFA enforced for everyone? For admins? _____________________________
- Who has Global Administrator? (Then run
  `09-Entra-Intune\Get-EntraSecurityPosture.ps1` and compare.) ___________
- Local admin on workstations: LAPS? (`09-Entra-Intune\Get-LAPSComplianceReport.ps1`)
  Who else is in local Administrators? (`17-Security-Audit\Get-LocalAdminAudit.ps1`) ___

**Devices**
- How are PCs deployed? (image, Autopilot, by hand?) ______________________
- Windows Update: WSUS, Intune rings, or "it just updates"? ______________
- BitLocker everywhere? Keys escrowed? (`07-Reporting-Health\Confirm-BitLockerEscrow.ps1`) ___
- Antivirus/EDR product and who watches its console? _____________________

**Network**
- Network diagram exists? Where? __________________________________________
- Who manages the firewall? Do you get access? ____________________________
- ISP: provider, circuit/customer ID, support number → write it here now:
  _____________________________________________________
- Wi-Fi: how do guests get on? How do corporate devices? __________________
- DHCP/DNS: on the DCs, or elsewhere? (`15-DNS-DHCP\Get-DHCPScopeReport.ps1`) ___

**Servers & services**
- List of servers and what each does — start from the discovery report,
  fill in the "what" column from people.
- What's monitored, and where do alerts go? (Zabbix/Grafana? — section 10
  of the kit plugs into that.) ____________________________________________
- Certificates: internal CA? Who renews what? (`07-Reporting-Health\Get-CertExpiryReport.ps1`) ___
- Licences: Microsoft 365 plan, how many seats, who buys more? ____________

**Process**
- Change process: can you change a GPO today, or is there a change window /
  approval? ________________________________________________________________
- Who's on-call / what happens outside hours? ______________________________
- Who do you escalate to, and how do they like to be told (chat, call,
  ticket)? _________________________________________________________________
- Vendors and support contracts (hardware, backup, firewall, printers):
  contact + contract number → collect into one page.

## Day 4–5 — establish your baselines (all read-only)

Run these once, keep the reports as your "day-5 snapshot":

- [ ] `12-AD-Health\Test-ADHealth.ps1`
- [ ] `11-GPO-ADMX\Backup-GPOs.ps1` (first backup + version baseline)
- [ ] `09-Entra-Intune\Get-IntuneDeviceCompliance.ps1` and `Get-IntunePatchCompliance.ps1`
- [ ] `07-Reporting-Health\Get-CertExpiryReport.ps1`
- [ ] `07-Reporting-Health\Get-SoftwareInventoryReport.ps1` (a few representative PCs)
- [ ] `16-FileShares\Get-SharePermissionReport.ps1` on the main file server
- [ ] `15-DNS-DHCP\Get-StaleDNSRecords.ps1` (report only — don't delete anything yet)

Anything red or surprising → not a fix yet, a **question** for your
senior: "I noticed X — is that known / intended?" That sentence is the
safest and most useful thing a new sysadmin can say.

## Week 2 and on

- [ ] Propose (don't just do) the scheduled reports:
      `Install-AllScheduledTasks.ps1 -WhatIf` shows exactly what it would
      register.
- [ ] Read the runbooks (`Runbooks\`) once so you know they exist before
      you need them at 09:00 on a Monday.
- [ ] Keep updating the discovery document as you learn — re-run the
      script monthly and compare.

## Things not to do in week one

- Don't change GPOs, firewall rules, or DNS without asking.
- Don't run anything with `-Execute` / without `-WhatIf` on a server you
  don't yet understand.
- Don't "clean up" old accounts, groups, DNS records, or shares yet —
  old often means "still used by something nobody remembers".
- Don't install tools on servers without asking.
