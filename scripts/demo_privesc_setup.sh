#!/bin/bash
# Bakes host-privilege-escalation findings into the "demo" service-abuse box
# (10.1.1.1) for a dedicated low-priv "user" account. Idempotent - safe
# to re-run. Run as root on the demo box itself (via SSH).
set -euo pipefail

DEMO_USER='user'
DEMO_PW='password'

echo "=== Low-priv user account ==="
if ! id "$DEMO_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEMO_USER"
    echo "${DEMO_USER}:${DEMO_PW}" | chpasswd
    echo "Created $DEMO_USER"
else
    echo "$DEMO_USER already exists"
fi

echo "=== sudo to a specific GTFOBins binary (less) ==="
cat > /etc/sudoers.d/cyberhawks-user-less <<'EOF'
user ALL=(root) NOPASSWD: /usr/bin/less
EOF
chmod 440 /etc/sudoers.d/cyberhawks-user-less
visudo -cf /etc/sudoers.d/cyberhawks-user-less
echo "sudo rule for /usr/bin/less installed"

echo "=== SUID on a GTFOBins binary (find, via a dedicated copy) ==="
if [ ! -f /usr/local/bin/sysfind ]; then
    cp /usr/bin/find /usr/local/bin/sysfind
fi
chown root:root /usr/local/bin/sysfind
chmod 4755 /usr/local/bin/sysfind
echo "SUID set on /usr/local/bin/sysfind"

echo "=== Capability on a GTFOBins binary (perl, via a dedicated copy) ==="
if [ ! -f /usr/local/bin/perl5-legacy ]; then
    cp /usr/bin/perl /usr/local/bin/perl5-legacy
fi
setcap cap_setuid+ep /usr/local/bin/perl5-legacy
echo "cap_setuid+ep set on /usr/local/bin/perl5-legacy"

echo "=== sudo LD_PRELOAD env_keep on a custom binary ==="
if [ ! -f /usr/local/bin/sysdiag ]; then
    cat > /usr/local/bin/sysdiag <<'EOF'
#!/bin/bash
echo "sysdiag: system OK, uptime $(uptime -p)"
EOF
    chmod 755 /usr/local/bin/sysdiag
    chown root:root /usr/local/bin/sysdiag
fi
cat > /etc/sudoers.d/cyberhawks-user-ldpreload <<'EOF'
Defaults:user env_keep += "LD_PRELOAD"
user ALL=(root) NOPASSWD: /usr/local/bin/sysdiag
EOF
chmod 440 /etc/sudoers.d/cyberhawks-user-ldpreload
visudo -cf /etc/sudoers.d/cyberhawks-user-ldpreload
echo "sudo LD_PRELOAD rule installed"

echo "=== cron job with wildcard (tar) ==="
mkdir -p /opt/backups
chown "${DEMO_USER}:${DEMO_USER}" /opt/backups
chmod 755 /opt/backups
cat > /etc/cron.d/cyberhawks-backup <<'EOF'
*/5 * * * * root cd /opt/backups && tar -czf /root/backup-$(date +\%s).tar.gz * 2>/dev/null
EOF
chmod 644 /etc/cron.d/cyberhawks-backup
echo "wildcard cron job installed (/opt/backups, every 5 min as root)"

echo "=== cron job relying on a writable PATH directory ==="
mkdir -p /opt/scripts
chown "${DEMO_USER}:${DEMO_USER}" /opt/scripts
chmod 755 /opt/scripts
cat > /etc/cron.d/cyberhawks-report <<'EOF'
PATH=/opt/scripts:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root generate-report.sh 2>/dev/null
EOF
chmod 644 /etc/cron.d/cyberhawks-report
echo "writable-PATH cron job installed (/opt/scripts is first on PATH, every 5 min as root)"

echo "=== systemd service + timer running a modifiable script ==="
mkdir -p /opt/maintenance
if [ ! -f /opt/maintenance/cleanup.sh ]; then
    cat > /opt/maintenance/cleanup.sh <<'EOF'
#!/bin/bash
echo "$(date) - maintenance run" >> /opt/maintenance/cleanup.log
EOF
fi
chown "${DEMO_USER}:${DEMO_USER}" /opt/maintenance/cleanup.sh
chmod 755 /opt/maintenance/cleanup.sh

cat > /etc/systemd/system/cyberhawks-cleanup.service <<'EOF'
[Unit]
Description=CyberHawks maintenance cleanup

[Service]
Type=oneshot
ExecStart=/opt/maintenance/cleanup.sh
User=root
EOF

cat > /etc/systemd/system/cyberhawks-cleanup.timer <<'EOF'
[Unit]
Description=Run CyberHawks maintenance cleanup every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cyberhawks-cleanup.timer
echo "systemd timer cyberhawks-cleanup.timer enabled (script owned by $DEMO_USER)"

echo "=== Docker group membership (container escape) ==="
if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq docker.io
    systemctl enable --now docker
    echo "Installed docker"
else
    echo "docker already installed"
fi
if ! id -nG "$DEMO_USER" | grep -qw docker; then
    usermod -aG docker "$DEMO_USER"
    echo "Added $DEMO_USER to docker group"
else
    echo "$DEMO_USER already in docker group"
fi

echo "=== ALL DONE ==="
