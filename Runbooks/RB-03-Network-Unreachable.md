# RB-03 — "No internet" / "can't reach the server" / "the network is down"

## 1. Scope in 60 seconds — this decides everything

| Who's affected | Where to look |
| --- | --- |
| One user, one PC | The PC (go to 2) |
| One user, any PC | Their account / permissions (RB-01) |
| Everyone in one room / floor / building | Switch, VLAN, cable to that area, DHCP scope for that subnet |
| Everyone, one specific system | That server / service (RB-08) |
| Everyone, everything | Core switch, firewall, ISP, or DC/DNS is down — escalate immediately, then investigate |

## 2. One PC

Run the diagnostics — adapters, gateway, DNS, internet, public IP, named
hosts, one report:

`05-Network\Get-NetworkDiagnostics.ps1`

Read it top to bottom:

- **No IP / 169.254.x.x** → DHCP not reached. Cable? Wi-Fi joined? Port
  dead? `ipconfig /release` + `/renew`. If several PCs: DHCP scope
  exhausted → `15-DNS-DHCP\Get-DHCPScopeReport.ps1`.
- **IP fine, gateway ping fails** → cable/switch port/VLAN problem for that
  PC. Swap the cable and port. Check the switch port's link light.
- **Gateway ok, DNS fails** → wrong DNS servers on the PC (should be the
  DCs), or DNS service down on the DC. `nslookup <server> <dc-ip>` to test
  a specific DC directly.
- **DNS ok, internet fails** → firewall/proxy/ISP. Ask if anyone else has
  internet.
- **Everything ok but "can't open the share"** → not a network problem:
  permissions (`16-FileShares\Get-SharePermissionReport.ps1`), or the file
  server itself (RB-08).

## 3. A whole area

- Anything changed? (Someone plugged a cable into the wrong port; a rogue
  device; a switch rebooted?)
- Sweep the subnet from a working machine to see who's alive:
  `05-Network\Invoke-SubnetScan.ps1 -Subnet 10.1.20.0/24`
- DHCP scope for that subnet: `15-DNS-DHCP\Get-DHCPScopeReport.ps1`
- Switch: power, uplink light, and can you reach its management IP? If
  not — that's your answer. Power-cycle the access switch as a last
  resort (users will lose the connection briefly; tell them).

## 4. Everything is down

1. **Tell people** — one line, right away (Docs\Communication-Templates.md
   → "Storing" / "Outage"). Silence is worse than bad news.
2. Is the **firewall / router** up? Is the **core switch** up?
3. Are the **DCs** up? Without DNS and AD nothing works even if the wires
   are fine: `12-AD-Health\Test-ADHealth.ps1` from any machine that can
   still reach them.
4. ISP line: check the modem/ONT lights; call the ISP with the circuit ID
   (find it now, in advance, and write it in Docs\First-Week-Plan.md).
5. Escalate — this is not a solo job.

## Close

Note the actual cause and the fix. If it was a cable, label the cable.
