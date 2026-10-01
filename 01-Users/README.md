# 01 — Users (Active Directory + local accounts)

Everything for the **joiner / mover / leaver** side of the job: create AD
accounts, disable them safely when someone leaves, do it in bulk from a
spreadsheet, and check whose password is about to expire. Also a local
(non-domain) account helper.

Run these from a machine with the **Active Directory module** (a domain
controller, or a PC with RSAT), as an **administrator**.

> Golden rule for this section: **add `-WhatIf` the first time.** It shows
> exactly what the script *would* do and changes nothing. And offboarding
> **disables, never deletes** — accounts can always be brought back.

| Script | What it does |
| --- | --- |
| `New-ADUserOnboard.ps1` | Create one AD user — temp password, groups, title/dept/manager, home drive. |
| `Disable-ADUserOffboard.ps1` | Safely disable a leaver: randomise password, save then remove groups, move to a Disabled OU, hide from the address book. |
| `New-BulkADUsers.ps1` | Create many users from a CSV. |
| `Get-ADPasswordExpiry.ps1` | Report accounts whose password expires soon. Read-only. |
| `Manage-LocalUser.ps1` | Create/disable a **local** (non-domain) account. |

---

## Onboard a new user (worked example)

Only first and last name are required — the OU and UPN suffix (the bit after
the `@`) come from your `Config\toolkit-settings.json` if you don't type them.

```powershell
# 1) Preview first — changes nothing:
.\01-Users\New-ADUserOnboard.ps1 -GivenName Anna -Surname Jansen -WhatIf

# 2) For real, with a department and copying another user's groups:
.\01-Users\New-ADUserOnboard.ps1 -GivenName Anna -Surname Jansen `
    -Department Sales -CopyFrom jdoe
```

**What you'll see:** the login name it picked (e.g. `ajansen`), the UPN, the OU
it went into, and a **temporary password** printed once — give that to the user;
they change it at first logon.

Useful extras: `-OU "OU=Staff,DC=lab,DC=local"` (put them somewhere specific),
`-Groups "GG_Sales","VPN-Users"` (add groups), `-Manager jdoe`, `-Title "Sales rep"`.

---

## Offboard a leaver (worked example)

```powershell
# Preview:
.\01-Users\Disable-ADUserOffboard.ps1 -SamAccountName ajansen -WhatIf

# For real:
.\01-Users\Disable-ADUserOffboard.ps1 -SamAccountName ajansen -HideFromGAL
```

It asks **"Are you sure?"** first (that's on purpose). It then disables the
account, scrambles the password, **saves the group list to `Backups\`** before
removing the groups (so nothing is lost), moves the account to your Disabled OU,
and optionally hides it from the address book. Nothing is deleted.

> Running it unattended (a scheduled task)? Add **`-Force`** to skip the "Are you
> sure?" prompt — otherwise it waits forever for an answer.

---

## Bulk create from a spreadsheet

There's a `sample-newhires.csv` in this folder — copy its columns. Then:

```powershell
.\01-Users\New-BulkADUsers.ps1 -CsvPath .\01-Users\sample-newhires.csv -WhatIf
.\01-Users\New-BulkADUsers.ps1 -CsvPath C:\newhires.csv
```

You get a results CSV listing each account and its temp password.

---

## Who's about to be locked out (read-only)

```powershell
.\01-Users\Get-ADPasswordExpiry.ps1 -Days 14
```

Lists accounts whose password expires within 14 days. Safe to run any time.

---

## A local (non-domain) account

```powershell
.\01-Users\Manage-LocalUser.ps1 -Action List
.\01-Users\Manage-LocalUser.ps1 -Action Onboard -User svc-backup -FullName "Backup service"
.\01-Users\Manage-LocalUser.ps1 -Action Offboard -User svc-backup
```
