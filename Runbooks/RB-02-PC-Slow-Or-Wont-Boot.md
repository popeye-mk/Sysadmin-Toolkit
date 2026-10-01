# RB-02 — PC slow, freezing, or won't boot

## A. It boots, but it's slow

1. **Ask since when and what changed** (new software? update? "it got a
   pop-up"?).
2. Run the health check — it scores disk, memory, pending reboot, uptime,
   Defender and event-log errors in one go:
   `07-Reporting-Health\Invoke-HealthCheck.ps1`
3. Uptime > 30 days or "pending reboot" flagged → **reboot first**, then
   re-evaluate. A shocking share of "slow" tickets end here.
4. Disk < 10% free → clear temp files, empty Downloads/Recycle Bin with the
   user, check `C:\Users\<name>\AppData\Local\Temp`, Windows Update cleanup
   (`cleanmgr`). Disk full = everything slow.
5. What's running at startup:
   `06-Debloat-Privacy\Get-StartupItems.ps1` — disable the junk with `-Disable`.
   Then bloatware: `06-Debloat-Privacy\Remove-Bloatware.ps1` (dry-run first).
6. Task Manager → Performance: is it CPU, memory, or disk at 100%? Disk at
   100% on an old spinning HDD = replace with an SSD, don't fight it.
7. Defender full scan if anything smells off (see RB-06).
8. Fresh machine baseline if it's a mess and the user agrees:
   `08-TechToolkit\Optimize-Workstation.ps1`

## B. It won't boot / blue screen

1. **Note the stop code** on the blue screen (e.g. `CRITICAL_PROCESS_DIED`,
   `INACCESSIBLE_BOOT_DEVICE`). Photograph it.
2. Power-cycle once, properly (hold power 10 s, wait, start).
3. Three failed boots in a row → Windows offers **Automatic Repair** →
   Advanced options:
   - **Startup Repair** first.
   - **Uninstall Updates** if it started right after Patch Tuesday.
   - **System Restore** if a restore point exists.
   - **Safe Mode** → if it boots there, a driver or startup item is the
     cause; use RB-02 A steps from Safe Mode.
4. Command prompt from recovery, check the disk:
   `chkdsk C: /f` and `sfc /scannow /offbootdir=C:\ /offwindir=C:\Windows`
5. BitLocker prompt appears during recovery → you need the recovery key.
   `07-Reporting-Health\Confirm-BitLockerEscrow.ps1` tells you (from another
   machine) whether it's in AD/Entra; look it up in AD (computer object →
   BitLocker Recovery tab) or Entra (Devices → device → Recovery keys).
6. Hardware suspicion (random freezes, no pattern): memory test
   (`mdsched.exe`), SMART status of the disk (`Get-PhysicalDisk |
   Get-StorageReliabilityCounter`), overheating (dust!).
7. Nothing works within ~45 min and the data is on the server anyway →
   reimage and re-provision:
   `04-PC-Provisioning\Initialize-NewPC.ps1` then `Join-Domain.ps1`.
   Don't spend a day saving a machine that takes an hour to rebuild.

## Before you hand it back

- Reboot it once more and log in as the user, yourself.
- Note what the actual cause was — "slow" is a symptom, not a cause.
