# Setup 2: Range + defense tooling

Build the vulnerable `cyberhawks.lab` range **and** the Zeek and Splunk
monitoring stack that watches it, so the attacks you run actually light up
detections. You can also push those to Discord.

This is a superset of [range-only.md](range-only.md). Do that guide first (or its
steps 1 through 6), then continue here. If you already have a range-only
deployment, you can add monitoring without rebuilding anything. Start at step A.

Every step ends with a **Check**.

## Extra prerequisites (beyond setup 1)

- **Two Debian 12 hosts** on a monitoring segment. This project uses the
  `defense` vnet (`10.0.10.0/24`). One is a **Splunk indexer** (an ordinary
  container or VM). The other is a **Zeek sensor** (a **privileged** LXC with two
  NICs). See
  [defense-tooling/docs/manual-prerequisites.md](https://github.com/CyberHawks-IIT/defense-tooling/blob/main/docs/manual-prerequisites.md).
- **Traffic mirroring** from the router to the Zeek sensor. Use defense-tooling's
  `scripts/proxmox/setup-mirror.sh`.
- **Splunk downloads**, which are login-gated and manual: the Splunk Enterprise
  `.deb`, the Universal Forwarder installers, and the add-ons. See
  [defense-tooling/docs/add-ons.md](https://github.com/CyberHawks-IIT/defense-tooling/blob/main/docs/add-ons.md).

## Steps

### A. Clone the two extra repos, side by side with cyber-range

```bash
cd cyberhawks    # the parent dir from setup 1
git clone https://github.com/CyberHawks-IIT/defense-tooling.git
git clone https://github.com/CyberHawks-IIT/splunk-detections.git
```

**Check:** `ls` shows `cyber-range/`, `defense-tooling/`, and
`splunk-detections/` as siblings. The defense-tooling defaults assume this
layout.

### B. Turn on host-side logging in the range

By default the range hosts don't audit any of what the detections need. Flip the
`range_monitoring` toggle on and re-run the range playbook. It's idempotent and
only adds the Phase Q logging config:

```bash
cd cyber-range/ansible
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml -e range_monitoring=true
```

You can instead set `range_monitoring: true` in `inventory/group_vars/all.yml`
to make it the default, or run `playbooks/detection-logging.yml` directly.

This turns on the audit policy, SACLs, Sysmon, 1644 LDAP diagnostics, RPC
Firewall, and the SQL, CA, and IIS telemetry. One piece, the
`FullPrivilegeAuditing` LSA setting, needs a reboot to take effect. Reboot the
range VMs after this step if you want the SAM and LSA dump detections live right
away.

**Check:**

```bash
ansible dc1 -i inventory/hosts.yml -m win_shell -a "auditpol /get /category:* | Select-String 'Directory Service Access'"
```

shows it enabled.

### C. Deploy the monitoring stack

In `defense-tooling`:

```bash
cd ../../defense-tooling/ansible
cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
ansible-galaxy collection install -r requirements.yml
```

Edit `inventory/hosts.yml`. The example already lists all 7 AD forwarders plus
zeek and demo, so trim it to what you actually run. Then edit
`inventory/group_vars/all.yml`:

- Set the Splunk `.deb` and forwarder installer paths, and the admin passwords.
  Vault the passwords.
- Set `splunk_detections_app_src: ../../../splunk-detections/app`. This is what
  makes the indexer deploy the detection saved searches. Also set
  `splunk_detections_repo_dir` if you want it to rebuild `savedsearches.conf`
  from the YAMLs first.

Wire up mirroring on the Proxmox host, then run the stack:

```bash
# on the Proxmox host, once:
scripts/proxmox/setup-mirror.sh --help    # then run it for your router and sensor

# from the control node:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

`site.yml` installs the indexer (with the detection content and the
splunk-detections app), the Zeek sensor, and the forwarders on every host.

**Check:** open the Splunk web UI on the indexer. Under **Settings > Searches,
reports, and alerts** you see the CyberHawks detections. Under **Search**,
`index=zeek | head` and `index=windows | head` return recent events.

### D. Verify end to end

From an attacker box, run something a detection covers, such as a ping sweep or a
Kerberoast, against the range. Within a minute it should appear in Splunk under
**Activity > Triggered Alerts** (or search `index=_audit action=alert_fired`).

**Check:** the alert for the technique you ran shows up, with the attacker's IP
resolved.

### E. Discord alerting (optional)

Push every triggered Splunk alert to a Discord channel as a rich embed.

1. In Discord, go to **Server Settings > Integrations > Webhooks > New Webhook**,
   pick the channel, and **Copy Webhook URL**.
2. In `defense-tooling/ansible/inventory/group_vars/all.yml`, set
   `discord_webhook_url` to that URL. Vault it. Then re-run the indexer:

   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/splunk-indexer.yml
   ```

   This installs the Discord alert action and wires every deployed detection to
   it. Each embed's title and fields come from the detection's own definition in
   `splunk-detections`. See
   [defense-tooling's Discord docs](https://github.com/CyberHawks-IIT/defense-tooling/blob/main/docs/discord-alerting.md).

**Check:** re-run the attack from step D. The alert now also lands in your
Discord channel, with the attacker's IP and the detection's fields.

## Done

You have the full stack: a vulnerable range, host-side logging, Zeek and Splunk,
the detection content firing on real attacks, and optionally Discord alerts.

Everything is idempotent and re-runnable. The `range_monitoring` toggle is the
only thing separating this from setup 1. You can turn monitoring off again by
setting it back to `false`, though the host logging config that's already applied
stays until you roll back a snapshot.
