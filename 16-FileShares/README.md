# 16 — File Shares

Who has access to what — share-level and NTFS permissions in one report,
with orphaned SIDs (leftover grants for deleted accounts) flagged
automatically. Self-contained, single file, read-only.

## What's here

| Script | What it does |
| --- | --- |
| `Get-SharePermissionReport.ps1` | Enumerates SMB shares (local or remote), reads share-level + NTFS permissions for each, flags orphaned SIDs. HTML report. |

## Usage

```powershell
.\Get-SharePermissionReport.ps1
.\Get-SharePermissionReport.ps1 -ComputerName FS01 -ShareName Finance,HR
.\Get-SharePermissionReport.ps1 -IncludeAdminShares
```

## What "orphaned SID" means here

When an account is deleted, permissions granted to it don't get cleaned up
automatically — Windows just can't translate the SID back to a name anymore,
so it shows up as a raw `S-1-5-21-...` string instead of `CONTOSO\jpeeters`.
That's the signature this script looks for. It's almost always safe to
remove those entries, but this script only reports them — removing an ACE is
a manual step (Windows Explorer, `icacls`, or `Set-Acl`) so you can look at
each share's context before touching permissions.

## Requirements

Read rights on the share definitions and underlying NTFS ACLs. A remote
check (`-ComputerName`) needs WinRM/CIM reachability to the target server.
