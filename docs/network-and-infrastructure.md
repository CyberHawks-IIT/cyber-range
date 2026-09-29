# Network and infrastructure layout

The full Proxmox network layout this project runs on. It's based on the team's
own network diagram below plus what's actually live on the hypervisor today. For
the AD domain itself, see the main [README](../README.md) and
[CLAUDE.md](../CLAUDE.md).

![Network diagram](network-diagram.jpg)

## The shape of it

One Proxmox host runs everything. A single **pfSense VM is the router for every
segment** below, and nothing on one segment reaches another except through it.
There are three ways in. **WAN** is the internet-facing path. **NetBird VPN** is
this project's own control-host access. **HackTheBox OpenVPN** is a separate
access path this repo doesn't use.

| Zone | Segment | Subnet | Gateway | Hosts |
|---|---|---|---|---|
| **Corporate** | `services` | 10.0.1.0/24 | 10.0.1.1 | Standalone servers |
| | `ad` | 10.0.2.0/24 | 10.0.2.1 | **This repo**, `cyberhawks.lab` |
| | `student` (aka `cptc11`) | 10.0.3.0/24 | 10.0.3.1 | Student-created network (see note below) |
| **Demo** | `demo` | 10.1.1.0/24 | 10.1.1.254 | Demo Box at 10.1.1.1 |
| **Blue Team** | `defense` | 10.0.10.0/24 | 10.0.10.1 | Splunk at 10.0.10.2, Zeek at 10.0.10.3 (see note below) |
| | `defenders` | 10.0.11.0/24 | 10.0.11.1 | Defender workstations, **planned, not built yet** |
| **Red Team** | `offense` | 192.168.0.0/24 | 192.168.0.1 | SysReptor .2, Nessus .3, BloodHound .4, C2 team server .5 |
| | `attacker` | 192.168.1.0/24 | 192.168.1.1 | Attacker workstations (per-student pairs) |
| **Admin** | `admin` | 10.0.0.0/24 | 10.0.0.1 | Manager at 10.0.0.2 |

Everything outside **Corporate, `ad`** is out of this repo's scope and managed
separately. It's listed here for orientation, not because this repo touches it.

**Two notes worth flagging:**

- **`defense` (10.0.10.3) runs Zeek, not Suricata.** The team's diagram labels
  this box "Suricata" as a general name for "the IDS host." Zeek is what's
  actually deployed and verified there. See
  [defense-tooling](https://github.com/CyberHawks-IIT/defense-tooling).
- **`student` / `cptc11` is the student-created network by design.** It
  currently happens to hold a leftover environment from last year's Collegiate
  Penetration Testing Competition. That content is incidental and irrelevant to
  this project. It is not a second team's infrastructure to avoid.

## Manual setup this repo doesn't script

- **Windows VM templates and cloudbase-init.** Built and documented in
  [vm-templates](https://github.com/CyberHawks-IIT/vm-templates), not here.
- **Two unfixed template bugs** (workarounds in [CLAUDE.md](../CLAUDE.md)).
  Templates 300 and 302 sometimes skip their static-IP cloud-init on first boot.
  Template 304 can hit a stale Cloudbase-Init execution-state key that skips
  networking entirely.
- **Defense tooling's prerequisites** (privileged-container gotchas, the
  `snippets` storage type, and Splunk's login-gated downloads) live in
  [defense-tooling's docs](https://github.com/CyberHawks-IIT/defense-tooling/tree/main/docs).
