# Setup 1 — Range only

Build just the vulnerable `cyberhawks.lab` AD range: 7 Windows VMs you attack
from a Kali/Windows box. No monitoring stack.

If you want the Zeek + Splunk monitoring layer too, follow
[range-with-monitoring.md](range-with-monitoring.md) instead — it's a superset
of this guide.

Every step ends with a **Check** so you can confirm it worked before moving on.

---

## What runs where

- **Proxmox host** — you run the VM-cloning script here (it drives `qm`).
- **Control node** — a Linux box with Ansible that reaches the range VMs over
  WinRM. This project uses **WSL2 (Kali)** on a Windows workstation; a plain
  Linux box works too. All `ansible-playbook` commands run here.

---

## Prerequisites

### 1. Proxmox + templates

- A Proxmox host with capacity for 7 Windows VMs (4 vCPU / 4 GB each; sql1/sql2
  get 48 GB disks, the rest 32 GB) on a bridge/vnet for the range network
  (`10.0.2.0/24`, gateway `10.0.2.1`). See
  [../network-and-infrastructure.md](../network-and-infrastructure.md).
- The four VM **templates** built and reachable, with cloud-init/cloudbase-init:
  Windows Server 2016, 2019, 2022, and Windows 11. These come from the
  [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs) repo (it also
  builds the Kali/Windows attacker templates). Note the template VMIDs — the
  clone script defaults to `300`/`301`/`302`/`304`, override with `--tmpl-*`.

### 2. Control node

- Ansible (core 2.15+) with `pywinrm` (`apt-get install -y ansible` pulls in
  `python3-winrm`). Windows collection: `ansible-galaxy collection install ansible.windows`.
- An SSH keypair for the Proxmox host (this project uses `id_ed25519_cyberrange`).
- This node's `TrustedHosts` (if it's Windows/WSL) or WinRM client must allow
  the 7 range IPs — the range VMs speak WinRM over NTLM.

### 3. SQL Server media (manual download)

`sql1`/`sql2` install SQL Server from **Evaluation-edition ISOs** you download
once (login-free, but the automation won't fetch them — same stance
defense-tooling takes for Splunk). You need, matched to each host's OS:

- **sql1** (Windows Server 2016): SQL Server 2016 Evaluation ISO
- **sql2** (Windows Server 2022): SQL Server 2022 Evaluation ISO
- **SSMS** (SQL Server Management Studio) installer, for both — optional
  (`mssql_install_ssms: false` to skip). On Server 2016 SSMS also needs
  .NET Framework 4.7.2+ (Server 2022 already has it).

Provide each either as a URL the guest downloads (`mssql_iso_url` /
`mssql_ssms_url`) or as a file already staged on the guest
(`mssql_iso_guest_path` / `mssql_ssms_guest_path`) — see
`ansible/inventory/host_vars/sql1.yml` and `sql2.yml`.

---

## Steps

### 1. Clone the repos side by side

```bash
mkdir cyberhawks && cd cyberhawks
git clone https://github.com/CyberHawks-IIT/cyber-range.git
git clone https://github.com/CyberHawks-IIT/AttackerVMs.git   # optional, for attacker VMs
```

**Check:** `ls` shows `cyber-range/` (and `AttackerVMs/`).

### 2. Create the range VMs

Copy the clone script to the Proxmox host and run it there:

```bash
scp cyber-range/scripts/create_range_vms.sh root@<proxmox>:/root/
ssh root@<proxmox>
./create_range_vms.sh --dry-run          # preview
./create_range_vms.sh                     # clone dc1,dc2,ca,web,sql1,sql2,workstation
```

Override defaults if your templates/bridge differ, e.g.
`--tmpl-2016 300 --tmpl-2019 301 --tmpl-2022 302 --tmpl-win11 304 --bridge ad`.
Add `--start-vms` to power them on immediately.

**Check:** `qm list | grep -E 'dc1|dc2|ca|web|sql1|sql2|workstation'` shows all
7. Start them if you didn't use `--start-vms`. Give them a few minutes, then
confirm each got its static IP (`qm guest exec <vmid> -- ipconfig`); if a
2016/2022 clone came up on APIPA, the script's closing notes have the one-line
`netsh` fix.

### 3. Configure the inventory and vault

On the control node, in `cyber-range/ansible`:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/windows_vms/vault.yml.example inventory/group_vars/windows_vms/vault.yml
```

Edit `inventory/hosts.yml`: set your Proxmox host IP and your SSH key path
(the range VM IPs and grouping usually don't change).

Fill in `vault.yml`:
- `vault_windows_admin_password` — the shared built-in Administrator password
  baked into the templates. Get it on the Proxmox host:
  `qm cloudinit dump <any-range-vmid> user`.
- `vault_provision_password` — any strong password you choose for the
  `svc-provision` automation account the build creates.

Then encrypt it and point Ansible at the vault password:

```bash
ansible-vault encrypt inventory/group_vars/windows_vms/vault.yml
# store the vault password where ansible.cfg's vault_password_file expects it
```

Set the SQL media vars in `inventory/host_vars/sql1.yml` and `sql2.yml`
(see Prerequisite 3).

**Check:** `ansible-inventory -i inventory/hosts.yml --list >/dev/null && echo OK`
parses cleanly, and
`ansible windows_vms -i inventory/hosts.yml -m win_ping -e ansible_user=Administrator -e ansible_password=<admin-pw>`
returns `pong` from all 7 (using the built-in Administrator, since
`svc-provision` doesn't exist yet — the next step creates it).

### 4. Build the clean domain

```bash
ansible-playbook -i inventory/hosts.yml playbooks/base-domain.yml
```

This creates the `svc-provision` account, sets hostnames, promotes dc1 (forest
root) and dc2, configures DNS, joins the 5 member servers, installs the
Enterprise CA + Web Enrollment on ca, and installs SQL Server + SSMS on
sql1/sql2. It's idempotent — safe to re-run. It reboots hosts as needed
(promotion, joins), so it takes a while.

**Check:**
```bash
ansible dc1 -i inventory/hosts.yml -m win_shell -a "(Get-ADDomain).DNSRoot; (Get-ADForest).ForestMode"
```
prints `cyberhawks.lab` / `Windows2016Forest`. `ansible windows_vms -m win_ping`
now succeeds as the default `svc-provision` account (no `-e` overrides).

### 5. Build the vulnerable range

```bash
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml
```

This layers on every intentional misconfiguration (starter accounts, delegation,
ADCS ESC templates, SQL misconfig, the web portal, NTLM relay triggers, etc.).
`range_monitoring` stays `false` (the default), so no host-side detection
logging is turned on. Idempotent.

The generated answer key (which pool account plays which role, service
passwords) lands in `ansible/generated/` — gitignored, treat it as the
solutions file.

**Check:** the range briefing lists the starter credentials
([../../README.md](../../README.md) links it). From an attacker box, confirm the
day-one account works, e.g. `nxc smb 10.0.2.2 -u user -p password`.

### 6. (Optional) Attacker VMs

To hand students their own Kali/Windows attacker pair, use
[scripts/create_testing_vms.sh](../../scripts/create_testing_vms.sh) on the
Proxmox host with a roster CSV (see its `--help` and CLAUDE.md's "Student
attacker/testing VMs"). The templates come from
[AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs). If you're just
attacking it yourself, any Kali box on the range network works.

---

## Done

You have a fully vulnerable `cyberhawks.lab`. To add the monitoring stack later,
follow [range-with-monitoring.md](range-with-monitoring.md) from its
"Turn on host-side logging" step — you don't rebuild anything.

Re-running any playbook is safe. To reset a VM to a clean point, roll back to a
Proxmox snapshot (see CLAUDE.md for the snapshot names taken at each milestone).
