# Virtualmin Backup Script

> **Created by [Kyros Koh](https://github.com/kyroskoh)**

A robust shell script for backing up **Virtualmin domains (virtual servers)** and **Webmin/Virtualmin configuration**, with support for:

- Backing up **one domain** (e.g., `example.com`) or **all domains**
- Optionally including **Webmin/Virtualmin configuration**
- **Rotation** of local backups (keep last N, default 7)
- Upload to **S3**, **SCP**, or **rsync**
- Optional **remote rotation** (S3 natively, SCP/rsync via SSH prune)

---

## ✨ Features

- **Domain backups** with `virtualmin backup-domain`
- **Config backups** with `backup-config.pl` (auto-detected if present)
- **Rotation**: keep only the last *N* backups
- **Remote upload**:
  - **S3** via AWS CLI
  - **SCP** to any SSH server
  - **rsync** to a remote server
- **Remote rotation**: prunes old backups on remote if enabled

---

## ⚙️ Requirements

- Virtualmin installed with `virtualmin` CLI
- `bash`, `awk`, `find`, `sort`
- For **S3**:
  - `awscli` installed (`apt install awscli` or `yum install awscli`)
  - Configured credentials (`aws configure` or `--aws-profile`)
- For **SCP/rsync**:
  - Working SSH access to remote
  - Optional SSH key if passwordless auth desired

---

## 🚀 Usage

Make the script executable:

```bash
chmod +x virtualmin_backup.sh
```

Run it:
```bash
# Backup a single domain
sudo ./virtualmin_backup.sh example.com

# Backup all domains
sudo ./virtualmin_backup.sh --all
```

Options
| Option            | Description                                                  |
| ----------------- | ------------------------------------------------------------ |
| `--dest <path>`   | Local base dir (default: `/root/virtualmin_backups`)         |
| `--keep <N>`      | Keep last N backups locally (default: 7)                     |
| `--no-config`     | Skip Webmin/Virtualmin config backup                         |
| `--backend`       | Destination backend: `local` (default), `s3`, `scp`, `rsync` |
| `--remote-rotate` | Prune remote to keep only last N backups                     |

S3 Backend
```bash
sudo ./virtualmin_backup.sh --all \
  --backend s3 \
  --s3-uri s3://mybucket/virtualmin \
  --keep 7
```

Options:
`--s3-uri <s3://bucket/prefix>`
`--aws-profile <profile>` (optional)

SCP Backend
```bash
sudo ./virtualmin_backup.sh example.com \
  --backend scp \
  --scp-user root \
  --scp-host backup.example.com \
  --scp-path /srv/backups/vmin \
  --remote-rotate
```

Options:
`--scp-user <user>`
`--scp-host <host>`
`--scp-port <port>` (default: 22)
`--scp-path <remote-path>`
`--scp-key <private-key>` (optional)

rsync Backend
```bash
sudo ./virtualmin_backup.sh --all \
  --backend rsync \
  --rsync-dest backup@host:/srv/backups/vmin \
  --rsync-opts "-avz --partial" \
  --keep 14 \
  --remote-rotate
```

Options:
`--rsync-dest <user@host:/path>`
`--rsync-opts "<opts>"` (default: `-av`)
`--remote-rotate` (SSH prune on remote)

---

## 🔄 Rotation

- Local: keeps last N backups (default 7) per domain/ALL directory
- Remote:
  - S3: prunes by filename order
  - SCP/rsync: SSH `ls -1t | awk 'NR>N' | xargs rm -f`

---

## 🗃 Restore
- Restore a domain:
```bash
virtualmin restore-domain --source /root/virtualmin_backups/example.com/example.com-backup-YYYYMMDD_HHMMSS.tar.gz
```

- Restore all domains:
```bash
virtualmin restore-domain --source /root/virtualmin_backups/ALL/virtualmin-domains-YYYYMMDD_HHMMSS.tar.gz --all-domains
```

- Restore config (if backed up):
  - Webmin UI → **Webmin Configuration** → **Backup Configuration** → **Restore**
  - Or via CLI: `restore-config.pl <archive>`

---

## 📝 Notes
- If backup-config.pl is missing, the script continues gracefully (domain backups are unaffected).
- Recommended: test restores on a staging Virtualmin server before production use.
- Consider scheduling with cron for automatic daily/weekly backups.

---

## 📖 Example Cron Job
Edit root’s cron:
```bash
sudo crontab -e
```
Add:
```bash
0 2 * * * /root/virtualmin_backup.sh --all --backend s3 --s3-uri s3://mybucket/virtualmin --keep 7 >> /var/log/virtualmin_backup.log 2>&1
```
This runs every night at 2AM.

---

## 🔐 Security
- Ensure backup archives are stored securely (consider GPG encryption).
- When using SCP/rsync, prefer SSH keys with restricted permissions.
- For S3, use IAM users with least-privilege policies.

---

## 📦 Auto Service Installer
Refer [service_installer.sh](service_installer.sh)

- Overrides: To change schedule without editing files:
```bash
sudo systemctl edit virtualmin-backup.timer
```
Then place a drop-in with a new OnCalendar= line.

---

## 👨‍💻 Author

**Kyros Koh**
- GitHub: [@kyroskoh](https://github.com/kyroskoh)
- Email: me@kyroskoh.com
- Portfolio: [kyroskoh.com](https://kyroskoh.com)

---

*Built with ❤️ by Kyros Koh*
