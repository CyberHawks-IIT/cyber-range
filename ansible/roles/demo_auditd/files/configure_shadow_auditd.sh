#!/bin/bash
set -euo pipefail

# auditd isn't installed by default on this Debian box -- without it, neither
# the file watch nor the PAM USER_LOGIN correlation the splunk-detections
# backlog's /etc/shadow-read detection depends on exist at all.
if ! dpkg -s auditd >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y auditd audispd-plugins
    echo "Installed auditd"
else
    echo "auditd already installed"
fi

RULE_FILE=/etc/audit/rules.d/shadow-read.rules
if [ ! -f "$RULE_FILE" ] || ! grep -q '/etc/shadow' "$RULE_FILE"; then
    echo '-w /etc/shadow -p r -k shadow_read' > "$RULE_FILE"
    echo "Wrote $RULE_FILE"
else
    echo "$RULE_FILE already present"
fi

augenrules --load
systemctl enable --now auditd
echo "DONE"
