# Setup 1: Range only

Build just the vulnerable `cyberhawks.lab` range. That's 7 Windows VMs you
attack from a Kali or Windows box, with no monitoring stack.

If you want the Zeek and Splunk monitoring layer too, follow
[range-with-monitoring.md](range-with-monitoring.md) instead. It's a superset of
this guide.

Every step ends with a **Check** so you can confirm it worked before moving on.

## What runs where

- **Proxmox host.** You run the VM-cloning script here. It drives `qm`.
- **Control node.** A Linux box with Ansible that reaches the range VMs over
  WinRM. This project uses WSL2 (Kali) on a Windows workstation, but a plain
  Linux box works too. All `ansible-playbook` commands run here.

## Prerequisites

### 1. Proxmox and templates

- A Proxmox host with room for 7 Windows VMs (4 vCPU and 4 GB each. sql1 and
  sql2 get 48 GB disks, the rest 32 GB), on a bridge or vnet for the range
  network (`10.0.2.0/24`, gateway `10.0.2.1`). See
  [../network-and-infrastructure.md](../network-and-infrastructure.md).
- The four VM **templates** built and reachable, with cloud-init or
  cloudbase-init: Windows Server 2016, 2019, 2022, and Windows 11. These come
  from the [vm-templates](https://github.com/CyberHawks-IIT/vm-templates) repo,
  which also builds the Kali and Windows attacker templates. Note the template
  VMIDs. The clone script defaults to `300`, `301`, `302`, and `304`, and you
  override them with `--tmpl-*`.

### 2. Control node

- Ansible (core 2.15 or newer) with `pywinrm` (`apt-get install -y ansible`
  pulls in `python3-winrm`). Install the Windows collection with
  `ansible-galaxy collection install ansible.windows`.
- An SSH keypair for the Proxmox host. This project uses `id_ed25519_cyberrange`.
- This node's `TrustedHosts` (on Windows or WSL) or WinRM client must allow the
  7 range IPs. The range VMs speak WinRM over NTLM.

### 3. SQL Server media (manual download)

sql1 and sql2 install SQL Server from **Evaluation-edition ISOs** you download
once. They're login-free, but the automation won't fetch them for you. This is
the same stance defense-tooling takes for Splunk. Matched to each host's OS you
need:

- **sql1** (Windows Server 2016): SQL Server 2016 Evaluation ISO.
- **sql2** (Windows Server 2022): SQL Server 2022 Evaluation ISO.
- **SSMS** (SQL Server Management Studio) installer, for both. This is optional.
  Set `mssql_install_ssms: false` to skip it. On Server 2016, SSMS also needs
  .NET Framework 4.7.2 or newer installed first. Server 2022 already has it.

**Download the files now** and note where they are, either a URL or a local
path. You point the playbook at them in **Step 3b** below. There's nothing to
configure at this stage. For the ISO, and for SSMS if you want it, you'll pick
one of two ways to hand it to the SQL host:

- **By URL.** The range VM downloads it itself. Easiest if you have a stable
  download link.
- **By staged file.** You copy the file onto the range VM first (over RDP, or
  with `scp` or `Copy-Item`), then give its path as seen on that VM, for example
  `C:\media\sql2022.iso`.

You don't need both. Pick whichever is convenient per file.

## Steps

### 1. Clone the repos side by side

```bash
mkdir cyberhawks && cd cyberhawks
git clone https://github.com/CyberHawks-IIT/cyber-range.git
git clone https://github.com/CyberHawks-IIT/vm-templates.git   # optional, for attacker VMs
```

**Check:** `ls` shows `cyber-range/` (and `vm-templates/`).

### 2. Create the range VMs

Copy the clone script to the Proxmox host and run it there:

```bash
scp cyber-range/scripts/create_range_vms.sh root@<proxmox>:/root/
ssh root@<proxmox>
./create_range_vms.sh --dry-run          # preview
./create_range_vms.sh                     # clone dc1,dc2,ca,web,sql1,sql2,workstation
```

Override the defaults if your templates or bridge differ, for example
`--tmpl-2016 300 --tmpl-2019 301 --tmpl-2022 302 --tmpl-win11 304 --bridge ad`.
Add `--start-vms` to power them on right away.

**Check:** `qm list | grep -E 'dc1|dc2|ca|web|sql1|sql2|workstation'` shows all
7. Start them if you didn't use `--start-vms`. Give them a few minutes, then
confirm each got its static IP with `qm guest exec <vmid> -- ipconfig`. If a
2016 or 2022 clone came up on APIPA, the script's closing notes have the
one-line `netsh` fix.

### 3. Configure the inventory and vault

On the control node, in `cyber-range/ansible`:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/windows_vms/vault.yml.example inventory/group_vars/windows_vms/vault.yml
```

Edit `inventory/hosts.yml` to set your Proxmox host IP and your SSH key path.
The range VM IPs and grouping usually don't change.

Fill in `vault.yml`:

- `vault_windows_admin_password` is the shared built-in Administrator password
  baked into the templates. Get it on the Proxmox host with
  `qm cloudinit dump <any-range-vmid> user`. After the domain is built, the
  domain `CYBERHAWKS\Administrator` inherits this same password, and that's what
  every playbook after `base-domain.yml` connects as.

Then encrypt it and point Ansible at the vault password:

```bash
ansible-vault encrypt inventory/group_vars/windows_vms/vault.yml
# store the vault password where ansible.cfg's vault_password_file expects it
```

**Check:** `ansible-inventory -i inventory/hosts.yml --list >/dev/null && echo OK`
parses cleanly, and
`ansible windows_vms -i inventory/hosts.yml -m win_ping -e ansible_user=Administrator`
returns `pong` from all 7. This uses the built-in local Administrator. The
default `CYBERHAWKS\Administrator` only works once the domain is built.

### 3b. Point the SQL hosts at your SQL media

This is where you plug in the files from Prerequisite 3. Edit these two files.
They already exist in the repo, pre-filled with empty placeholders and comments:

- `inventory/host_vars/sql1.yml` for the SQL Server **2016** media on sql1.
- `inventory/host_vars/sql2.yml` for the SQL Server **2022** media on sql2.

Each file has four variables. **Fill in exactly one of each pair** and leave the
other as `""`:

| Variable | Set it to |
|---|---|
| `mssql_iso_url` | a download URL for the SQL Server ISO, **or** leave `""` |
| `mssql_iso_guest_path` | the ISO's path on the SQL VM, if you staged it there, **or** leave `""` |
| `mssql_ssms_url` | a download URL for the SSMS installer, **or** leave `""` |
| `mssql_ssms_guest_path` | the SSMS installer's path on the SQL VM, **or** leave `""` |

Example. `inventory/host_vars/sql2.yml`, with the ISO by URL and SSMS staged on
the VM:

```yaml
mssql_iso_url: "https://download.microsoft.com/…/SQLServer2022-x64-ENU.iso"
mssql_iso_guest_path: ""
mssql_ssms_url: ""
mssql_ssms_guest_path: "C:\\media\\SSMS-Setup-ENU.exe"
```

Notes:

- A `guest_path` is a path on the SQL range VM, not on your control node. Stage
  the file there first (an RDP copy, `scp`, `Copy-Item`, or a mounted share).
- A `_url` is fetched by the range VM itself, so the VM must be able to reach it.
- To skip SSMS entirely, add `mssql_install_ssms: false` to that host's file and
  leave both SSMS variables `""`.
- Nothing else references these. `base-domain.yml` reads them straight from these
  host_vars files in Step 4. If you set none and SQL isn't installed yet, the
  playbook stops with a clear message telling you to set them here.

### 4. Build the clean domain

```bash
ansible-playbook -i inventory/hosts.yml playbooks/base-domain.yml
```

This sets hostnames, promotes dc1 (forest root) and dc2, configures DNS, joins
the 5 member servers, installs the Enterprise CA and Web Enrollment on ca, and
installs SQL Server and SSMS on sql1 and sql2. It's idempotent, so it's safe to
re-run. It reboots hosts as needed for promotion and joins, so it takes a while.

**Check:**

```bash
ansible dc1 -i inventory/hosts.yml -m win_shell -a "(Get-ADDomain).DNSRoot; (Get-ADForest).ForestMode" -e ansible_user=Administrator
```

prints `cyberhawks.lab` and `Windows2016Forest`. `ansible windows_vms -m win_ping`
now succeeds as the default `CYBERHAWKS\Administrator` with no `-e` overrides,
because the hosts are domain-joined.

### 5. Build the vulnerable range

```bash
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml
```

This layers on every intentional misconfiguration: starter accounts, delegation,
ADCS ESC templates, SQL misconfig, the web portal, NTLM relay triggers, and
more. `range_monitoring` stays `false` (the default), so no host-side detection
logging is turned on. It's idempotent.

The generated answer key (which pool account plays which role, plus service
passwords) lands in `ansible/generated/`. It's gitignored. Treat it as the
solutions file.

**Check:** the range briefing lists the starter credentials, and
[../../README.md](../../README.md) links it. From an attacker box, confirm the
day-one account works, for example `nxc smb 10.0.2.2 -u user -p password`.

### 6. Attacker VMs (optional)

To hand students their own Kali and Windows attacker pair, use
[scripts/create_testing_vms.sh](../../scripts/create_testing_vms.sh) on the
Proxmox host with a roster CSV. See its `--help` and CLAUDE.md's "Student
attacker/testing VMs". The templates come from
[vm-templates](https://github.com/CyberHawks-IIT/vm-templates). If you're just
attacking the range yourself, any Kali box on the range network works.

## Done

You have a fully vulnerable `cyberhawks.lab`. To add the monitoring stack later,
follow [range-with-monitoring.md](range-with-monitoring.md) from its "Turn on
host-side logging" step. You don't rebuild anything.

Re-running any playbook is safe. To reset a VM to a clean point, roll back to a
Proxmox snapshot. CLAUDE.md lists the snapshot names taken at each milestone.
