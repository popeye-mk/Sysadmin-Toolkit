# RB-09 — AD or Group Policy misbehaving

"The policy isn't applying", "logon is slow", "replication error in the
event log", "the drive mapping stopped working for some people".

## 1. GPO not applying on a machine

On the affected PC, as the affected user:

```powershell
gpresult /h C:\Temp\gp.html ; start C:\Temp\gp.html
```

Read the report: is the GPO listed under *Applied* or *Denied*? Denied
reasons are written out — security filtering (user/computer not in the
group), WMI filter false, link disabled, wrong OU. Then `gpupdate /force`
and check again.

- The GPO isn't in the list at all → it's not linked where this object
  lives. Check the OU the user/computer is actually in
  (`Get-ADUser jpeeters | Select-Object DistinguishedName`).
- Applies to some PCs, not others → the failing ones can't reach SYSVOL
  or DNS points at the wrong server. `Test-Path \\contoso.local\SYSVOL`
  from the PC.
- "The processing of Group Policy failed" in the event log → nearly always
  DNS or a DC the PC can't reach. `05-Network\Get-NetworkDiagnostics.ps1`.

## 2. Is AD itself healthy?

`12-AD-Health\Test-ADHealth.ps1` — dcdiag, replication summary, FSMO
holders, SYSVOL reachability, scored. If replication shows failures:

```powershell
repadmin /showrepl            # who can't talk to whom
repadmin /syncall /AdeP       # force a sync (safe)
```

A DC that hasn't replicated for days is a bigger problem than the GPO — fix
that first. Time skew (`w32tm /query /status` on each DC) and DNS on the
DCs themselves are the usual causes.

## 3. Before you change a GPO

- Back up first — always: `11-GPO-ADMX\Backup-GPOs.ps1`. It also tells you
  which GPOs changed since the last run, which answers "who changed
  something?" the next time this happens.
- New Windows build settings not visible in the editor → the Central
  Store is old: `11-GPO-ADMX\Deploy-GPOCentralStore.ps1` with the current
  ADMX package.
- Test on one OU / one PC before linking at the domain level.

## 4. Logon slow

- `gpresult /h` → look at the *Component Status* times; a logon script
  or drive mapping that waits on an unreachable server is the classic.
- Drive maps/printers via GPP: item-level targeting to a group the user
  isn't in? Old servers still referenced?
- Roaming profiles / folder redirection to a slow or full file server →
  RB-04.

## 5. Account or group changes not showing

Group membership is read at logon: the user must log off/on (or lock +
unlock doesn't count). Cloud groups: Entra Connect sync every 30 min —
`Start-ADSyncSyncCycle -PolicyType Delta` on the Connect server to hurry it.

## Close

Note the GPO name, what you changed, and why. GPOs are where "temporary"
fixes go to live forever.
