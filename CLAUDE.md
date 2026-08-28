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

### Range VMs (Linux + Windows) — not yet inventoried

VM IPs, OS, and purpose have not been provided yet. Once available, add them to
`ansible/inventory/` and update this section with a short table (name, IP, OS,
role/purpose, access method).

Planned access approach:
- **Linux VMs:** SSH with `id_ed25519_cyberrange`, same as the Proxmox host.
- **Windows VMs:** preference not yet finalized between two options — flag this
  with the user if it comes up again before it's settled:
  1. Enable OpenSSH Server on each Windows VM and use plain SSH for everything
     (avoids ever touching this host's WinRM trust config).
  2. WinRM — requires the user (not Claude) to add each VM's IP to this host's
     `WSMan:\localhost\Client\TrustedHosts`, since that's a security-setting
     change Claude won't make on its own.

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
2. Get the list of range VM IPs (Linux + Windows) and their intended purpose.
3. Decide Windows VM access method (SSH vs WinRM — see above) and configure it.
4. Push the generated SSH key to each Linux VM (`ssh-copy-id` equivalent) and
   verify access, same as was done for the Proxmox host.
5. Build out the Ansible inventory and start writing playbooks for the
   vulnerable configurations the range should exercise.

## GitHub

Repo: `CyberHawks-IIT/cyber-range` (private).
