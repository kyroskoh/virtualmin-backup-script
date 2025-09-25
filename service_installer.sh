sudo bash -c '
set -e
install -m 750 /usr/local/sbin/virtualmin_backup.sh /usr/local/sbin/virtualmin_backup.sh 2>/dev/null || true
cat >/etc/systemd/system/virtualmin-backup.service <<EOF
[Unit]
Description=Virtualmin backup (domains + config) with rotation and optional remote upload
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/virtualmin-backup.env
ExecStart=/usr/local/sbin/virtualmin_backup.sh \$BACKUP_ARGS
User=root
Group=root
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/virtualmin-backup.timer <<EOF
[Unit]
Description=Schedule Virtualmin backup

[Timer]
OnCalendar=*-*-* 02:15:00
RandomizedDelaySec=5m
Persistent=true
Unit=virtualmin-backup.service

[Install]
WantedBy=timers.target
EOF

[[ -f /etc/virtualmin-backup.env ]] || cat >/etc/virtualmin-backup.env <<EOF
BACKUP_ARGS="--all --backend s3 --s3-uri s3://my-bucket/virtualmin --keep 7"
EOF

systemctl daemon-reload
systemctl enable --now virtualmin-backup.timer
systemctl list-timers virtualmin-backup.timer
'
