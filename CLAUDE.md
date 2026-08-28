# Cyber Range Project

Purpose: a personal cyber range for practicing identification and remediation of
common vulnerabilities. VMs are hosted on a Proxmox server and reached from this
Windows 11 host over a NetBird VPN (NetBird routes traffic directly to each VM's
IP — no separate tunnel/proxy config needed per host).

This repo holds the Ansible code used to provision/configure range hosts, plus
this file as the running source of truth for project context across sessions.

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
`cyber-range` in Proxmox for identification. DNS: dc1 points at gateway
(10.0.2.1); dc2 and all other members point at dc1 (10.0.2.2), same pattern as
the prior range.

**Access:** WinRM, user `Administrator`. Credentials are inherited from the
Proxmox cloud-init templates (300-304) — same across all clones since they
weren't overridden at clone time. Retrieve the current plaintext password by
running this on the Proxmox host (do **not** commit it to this repo):
```
qm cloudinit dump <vmid> user
```
WinRM setup is still pending — see Open items below.

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
2. Configure WinRM access to the 7 range VMs (see table above). This host's
   `WSMan:\localhost\Client\TrustedHosts` needs each VM IP added — that's a
   security-setting change the user needs to run themselves, not Claude.
3. Retrieve the Administrator cloud-init password from the Proxmox host
   (`qm cloudinit dump <vmid> user`) and verify WinRM connectivity to each VM.
4. Build out the Ansible inventory (`ansible/inventory/`) with the 7 VMs and
   start writing playbooks for the vulnerable configurations the range should
   exercise. Ansible's `winrm` connection plugin will need `pywinrm` installed
   in the WSL2 environment.

## GitHub

Repo: `CyberHawks-IIT/cyber-range` (private).
