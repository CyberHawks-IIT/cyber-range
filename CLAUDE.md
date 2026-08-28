# Cyber Range Project

Purpose: a personal cyber range for practicing identification and remediation of
common vulnerabilities. VMs are hosted on a Proxmox server and reached from this
Windows 11 host over a NetBird VPN (NetBird routes traffic directly to each VM's
IP — no separate tunnel/proxy config needed per host).

This repo holds the Ansible code used to provision/configure range hosts, plus
this file as the running source of truth for project context across sessions.

## Working conventions

- **Always `git commit` and `git push` after making changes in this repo** —
  don't batch changes up or wait to be asked. This applies to every change
  (CLAUDE.md updates, Ansible code, anything else tracked here), not just
  end-of-session wrap-ups.

## Control host

Working from a Windows 11 machine (`C:\Tools` is the general tools directory this
project lives under). Key tooling installed on this host so far:

- **OpenSSH client** — built into Windows 11, used for all Linux SSH access.
- **PuTTY / plink** (`C:\Program Files\PuTTY\plink.exe`) — installed via winget.
  Used only for one-off password-authenticated bootstrapping (e.g. initial key
  push) since Win32-OpenSSH's `ssh` reads passwords from the console directly and
  can't be scripted. Prefer plain `ssh` with the key for everything else.
- **GitHub CLI** (`gh`, `C:\Program Files\GitHub CLI\gh.exe`) — installed via
  winget, already authenticated as `RedefiningReality`.
- **WSL2 + Ansible** — WSL2 install was kicked off via `wsl --install` (requires
  local admin + a reboot, which Claude can't trigger itself). **Status: pending
  confirmation that WSL2 finished setting up and Ansible was installed inside
  it.** Once done, this section should be updated with the distro used and
  Ansible version.

SSH key for range hosts: `~/.ssh/id_ed25519_cyberrange` (public key comment
`cyberrange-lab`) on this Windows host — private key is gitignored, never
committed. This is the key deployed to range hosts for automation access.

## Hosts

### Proxmox host — 192.168.192.150

- **Access:** SSH as `root@192.168.192.150`, key-only (`id_ed25519_cyberrange`).
- **Hardening applied 2026-08-27:** password authentication disabled for SSH.
  Changes to `/etc/ssh/sshd_config` on the Proxmox host itself:
  - `PasswordAuthentication no`
  - `PubkeyAuthentication yes`
  - `PermitRootLogin prohibit-password` (root login only via key, never password)
  - `KbdInteractiveAuthentication no` (was already set)
  - Original config backed up on the Proxmox host at
    `/etc/ssh/sshd_config.bak.<timestamp>` before editing.
  - Verified after restart: key login works, password login is rejected
    (`server sent: publickey` only).
  - Note: the root account password that was used to bootstrap this (shared
    with the user out-of-band) no longer works for SSH, but may still be valid
    for the Proxmox web UI — consider rotating it if it's not already unique to
    that surface.

### Range VMs — all Windows, all accessed over WinRM

All are on the Proxmox `ad` bridge, network `10.0.2.0/24`, gateway `10.0.2.1`,
domain `cyberhawks.lab`. This looks like an Active Directory range: dc1/dc2 are
domain controllers, ca is a certificate authority, sql1/sql2 are SQL Server
boxes, web is a web server, workstation is a Win11 client.

| Name | VMID | Template (source) | IP | OS | MAC (net0) |
|---|---|---|---|---|---|
| dc1 | 320 | 300 (Windows2016) | 10.0.2.2/24 | Windows Server 2016 | BC:24:11:F4:20:96 |
| dc2 | 321 | 301 (Windows2019) | 10.0.2.3/24 | Windows Server 2019 | BC:24:11:52:77:99 |
| ca | 322 | 301 (Windows2019) | 10.0.2.4/24 | Windows Server 2019 | BC:24:11:C1:3C:1C |
| web | 323 | 302 (Windows2022) | 10.0.2.5/24 | Windows Server 2022 | BC:24:11:27:52:53 |
| sql1 | 324 | 300 (Windows2016) | 10.0.2.6/24 | Windows Server 2016 | BC:24:11:A5:48:39 |
| sql2 | 325 | 302 (Windows2022) | 10.0.2.7/24 | Windows Server 2022 | BC:24:11:5A:C6:7D |
| workstation | 326 | 304 (Windows11) | 10.0.2.8/24 | Windows 11 | BC:24:11:94:BB:C6 |

All 7 confirmed `running` in Proxmox as of provisioning time, correct disk sizes
(sql1/sql2 at 48G, rest at template default 32G).

Provisioned 2026-08-27 via linked clone (`qm clone`, default linked-clone
behavior since sources 300/301/302/304 are Proxmox templates) from the Proxmox
host itself, cloud-init IP set per host above. sql1/sql2 disks resized to 48G
(from the 32G template default) to match a prior similar range setup found on
this host (VMs 310-314, tag `cptc-practice-2025` — an earlier/separate
dc/ca/sql/web set, not part of this project, left untouched). All 7 tagged
`cyber-range` in Proxmox for identification.

**DNS (updated 2026-08-27 — balanced across both DCs):** neither dc1 nor dc2
has AD DS/DNS installed yet, so both currently point their own DNS upward at
the gateway (10.0.2.1) rather than at each other — pointing a DC at another DC
with no DNS service running just breaks resolution for it. The 5 non-DC
members are split between the two DCs (primary + the other as secondary) so
no single DC is a hard dependency:

| VM | Primary DNS | Secondary DNS |
|---|---|---|
| dc1 | 10.0.2.1 (gateway) | — |
| dc2 | 10.0.2.1 (gateway) | — |
| ca | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| sql1 | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| workstation | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| web | 10.0.2.3 (dc2) | 10.0.2.2 (dc1) |
| sql2 | 10.0.2.3 (dc2) | 10.0.2.2 (dc1) |

Applied both ways: directly in-guest via `netsh interface ip set/add dns`
(over WinRM for the 6 reachable VMs — cloud-init/cloudbase-init only runs on
first boot, which had already happened, so changing Proxmox's config alone
would not have retroactively updated already-booted guests) **and** in the
Proxmox cloud-init `--nameserver` config on each VM, so a future re-clone or
cloud-init reset picks up the same scheme without redoing this by hand.

**Note for when dc1/dc2 are actually promoted to domain controllers with the
DNS role:** this scheme should be revisited. Standard AD practice is for each
DC to primary-point at *another* DC (not upstream) for resolution/replication
health, with the gateway (10.0.2.1) configured as a conditional forwarder
inside the DNS server role for external names — not as the client-level
primary resolver like it is now.

**Access:** WinRM, user `Administrator`. Credentials are inherited from the
Proxmox cloud-init templates (300-304) — same password across all clones since
it wasn't overridden at clone time (confirmed identical across templates
300/301/302/304). Retrieve the current plaintext password by running this on
the Proxmox host (do **not** commit it to this repo):
```
qm cloudinit dump <vmid> user
```
This host's `WSMan:\localhost\Client\TrustedHosts` has been set (by the user)
to include all 7 VM IPs. **Verified 2026-08-27** via authenticated
`Invoke-Command` (not just port reachability): dc1, dc2, ca, web, sql1, sql2 all
respond correctly. workstation was still cycling through its first Windows 11
specialize/reboot on last check — recheck before assuming it's reachable.

**Known issue found and worked around:** cloud-init/cloudbase-init on templates
**300 (Windows2016) and 302 (Windows2022) does not reliably apply the static IP**
— clones from those two templates booted with DHCP/APIPA (169.254.x.x) instead
of their assigned static IP. Template 301 (Windows2019) applied correctly both
times it was used (dc2, ca). Affected on first boot: dc1, web, sql1, sql2 (all
either 300- or 302-sourced). Fixed manually per-VM by setting the static IP via
`netsh` through the QEMU guest agent from the Proxmox host — no WinRM/guest
credentials needed for this path:
```
qm guest exec <vmid> -- netsh interface ipv4 set address name=Ethernet static <ip> 255.255.255.0 10.0.2.1
qm guest exec <vmid> -- netsh interface ip set dns name=Ethernet static <dns>
```
(`workstation`/VM 326, from template 304, has no QEMU guest agent configured at
all — that template doesn't have `agent: 1` set — so this diagnostic path isn't
available for it if it has network trouble too.)

Also note: cloud-init did **not** rename any guest's hostname away from the
Windows autogenerated `WIN-XXXXXXX` default, on any of the 7, including the
VMs where the IP was applied correctly (dc2, ca). Hostnames will need to be set
explicitly (e.g. via `Rename-Computer` over WinRM) before domain setup —
Windows normally wants a reboot after a hostname change, so factor that in.

**Recommendation for later:** if more VMs get cloned from templates 300/302,
expect to hit the same static-IP bug and need the same manual fix — worth
investigating the cloudbase-init config/logs on those two templates directly
(`C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\` inside the guest)
to find and fix the root cause rather than patching every future clone by hand.

## Repo layout

```
cyber-range/
  CLAUDE.md              # this file
  .gitignore             # excludes private keys, vault secrets, retry files
  ansible/
    inventory/            # host inventories (empty until VMs are provided)
    playbooks/             # provisioning/vulnerability playbooks
    group_vars/
    host_vars/
    roles/
```

## Open items / next steps

1. Confirm WSL2 finished installing (user needs to run `wsl --install` elevated
   + reboot if not already done) and install Ansible inside it.
2. `workstation` (VM 326) is not reachable over WinRM and has no QEMU guest
   agent configured (template 304 lacks `agent: 1`), so it can't be diagnosed
   via `qm guest exec` like the others. User has flagged this looks like a
   different issue from the 300/302 static-IP bug and wants to diagnose it
   together — parked for now, not blocking the rest of the range.
3. Set proper hostnames on all 7 VMs (currently all still show Windows
   autogenerated `WIN-XXXXXXX` names) via `Rename-Computer` over WinRM, then
   reboot each.
4. Root-cause the cloudbase-init static-IP bug on templates 300/302 (see Known
   issue above) so future clones from them don't need manual `netsh` fixes.
5. Build out the Ansible inventory (`ansible/inventory/`) with the 7 VMs and
   start writing playbooks for the vulnerable configurations the range should
   exercise. Ansible's `winrm` connection plugin will need `pywinrm` installed
   in the WSL2 environment.

## GitHub

Repo: `CyberHawks-IIT/cyber-range` (private).
