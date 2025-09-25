#!/bin/bash
# virtualmin_backup.sh
# Backup a specified Virtualmin domain (or all) + Webmin/Virtualmin configuration,
# rotate (keep N), and optionally upload to S3 / SCP / rsync.
#
# Usage examples:
#   sudo ./virtualmin_backup.sh example.com
#   sudo ./virtualmin_backup.sh --all
#   sudo ./virtualmin_backup.sh example.com --no-config
#   sudo ./virtualmin_backup.sh --all --dest /backup/vmin --keep 10
#   sudo ./virtualmin_backup.sh example.com --backend s3 --s3-uri s3://mybucket/virtualmin --keep 7
#   sudo ./virtualmin_backup.sh --all --backend scp --scp-user root --scp-host backup.example.com --scp-path /srv/backups/vmin
#   sudo ./virtualmin_backup.sh --all --backend rsync --rsync-dest backup@example.com:/srv/backups/vmin
#
# Remote rotation:
#   - S3: automatic (requires awscli)
#   - SCP/rsync: SSH prune if user/host/path provided (--remote-rotate)

set -euo pipefail

# ---------- Defaults ----------
DATE="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="/root/virtualmin_backups"
KEEP_COUNT=7
DO_CONFIG=true
BACKEND="local"   # local | s3 | scp | rsync
REMOTE_ROTATE=false

S3_URI=""         # e.g., s3://bucket/prefix
AWS_PROFILE=""    # optional

SCP_USER=""       # e.g., root
SCP_HOST=""       # e.g., backup.example.com
SCP_PORT="22"
SCP_PATH=""       # e.g., /srv/backups/vmin
SCP_KEY=""        # optional: /root/.ssh/id_ed25519

RSYNC_DEST=""     # e.g., backup@host:/srv/backups/vmin
RSYNC_OPTS="-av"

# ---------- Helpers ----------
log() { echo -e "[virtualmin-backup] $*"; }
die() { echo -e "[virtualmin-backup][ERROR] $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 <domain>|--all [options]

Options:
  --dest <path>              Local base dir (default: ${BASE_DIR})
  --keep <N>                 Keep last N backups locally (default: ${KEEP_COUNT})
  --no-config                Skip Webmin/Virtualmin config backup
  --backend <local|s3|scp|rsync>  Destination backend (default: local)

S3 options (when --backend s3):
  --s3-uri <s3://bucket/prefix>   S3 bucket/prefix for uploads
  --aws-profile <name>            AWS CLI profile (optional)

SCP options (when --backend scp):
  --scp-user <user>
  --scp-host <host>
  --scp-port <port>               (default: 22)
  --scp-path <remote-path>
  --scp-key <private-key>         (optional)
  --remote-rotate                 Prune remote to keep last N (via SSH)

rsync options (when --backend rsync):
  --rsync-dest <user@host:/path>  rsync destination
  --rsync-opts "<opts>"           (default: "-av")
  --remote-rotate                 Prune remote to keep last N (via SSH)

Examples:
  $0 example.com
  $0 --all --backend s3 --s3-uri s3://mybucket/vmin --keep 10
  $0 example.com --backend scp --scp-user root --scp-host backup --scp-path /srv/backups/vmin --remote-rotate
  $0 --all --backend rsync --rsync-dest backup@host:/srv/backups/vmin --rsync-opts "-avz --partial"
EOF
}

# ---------- Arg parsing ----------
if [[ $# -lt 1 ]]; then usage; exit 1; fi

DOMAIN_ARG="$1"; shift || true
case "${DOMAIN_ARG}" in
  --help|-h) usage; exit 0;;
  --all|*) : ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) BASE_DIR="$2"; shift 2;;
    --keep) KEEP_COUNT="$2"; shift 2;;
    --no-config) DO_CONFIG=false; shift;;
    --backend) BACKEND="$2"; shift 2;;
    --s3-uri) S3_URI="$2"; shift 2;;
    --aws-profile) AWS_PROFILE="$2"; shift 2;;
    --scp-user) SCP_USER="$2"; shift 2;;
    --scp-host) SCP_HOST="$2"; shift 2;;
    --scp-port) SCP_PORT="$2"; shift 2;;
    --scp-path) SCP_PATH="$2"; shift 2;;
    --scp-key) SCP_KEY="$2"; shift 2;;
    --rsync-dest) RSYNC_DEST="$2"; shift 2;;
    --rsync-opts) RSYNC_OPTS="$2"; shift 2;;
    --remote-rotate) REMOTE_ROTATE=true; shift;;
    --help|-h) usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

# ---------- Setup paths ----------
if [[ "${DOMAIN_ARG}" == "--all" ]]; then
  TARGET_DIR="${BASE_DIR}/ALL"
  DOM_ARCHIVE_BASENAME="virtualmin-domains-${DATE}.tar.gz"
else
  TARGET_DIR="${BASE_DIR}/${DOMAIN_ARG}"
  DOM_ARCHIVE_BASENAME="${DOMAIN_ARG}-backup-${DATE}.tar.gz"
fi
mkdir -p "${TARGET_DIR}"

DOM_BACKUP="${TARGET_DIR}/${DOM_ARCHIVE_BASENAME}"
CONFIG_BACKUP="${TARGET_DIR}/webmin-config-${DATE}.tar.gz"
SHARED_PREFIX_FILTER="*virtualmin-domains-*.tar.gz *-backup-*.tar.gz webmin-config-*.tar.gz"

# ---------- Preflight ----------
command -v virtualmin >/dev/null 2>&1 || die "'virtualmin' CLI not found in PATH"

# ---------- Backup: domains ----------
if [[ "${DOMAIN_ARG}" == "--all" ]]; then
  log "Backing up ALL Virtualmin domains to ${DOM_BACKUP} ..."
  virtualmin backup-domain --all-domains --all-features --dest "${DOM_BACKUP}"
else
  log "Backing up domain '${DOMAIN_ARG}' to ${DOM_BACKUP} ..."
  virtualmin backup-domain --domain "${DOMAIN_ARG}" --all-features --dest "${DOM_BACKUP}"
fi
log "✔ Domain backup created."

# ---------- Backup: Webmin/Virtualmin config (best effort) ----------
if [[ "${DO_CONFIG}" == true ]]; then
  # Try common locations; fallback to find
  CANDIDATES=(
    "/usr/libexec/webmin/backup-config.pl"
    "/usr/lib/webmin/backup-config.pl"
    "/usr/share/webmin/backup-config.pl"
    "/usr/share/webmin/webmin/backup-config.pl"
    "/opt/webmin/backup-config.pl"
  )
  BACKUP_CONFIG_BIN=""
  for p in "${CANDIDATES[@]}"; do
    [[ -x "$p" ]] && BACKUP_CONFIG_BIN="$p" && break
  done
  if [[ -z "${BACKUP_CONFIG_BIN}" ]]; then
    BACKUP_CONFIG_BIN="$(find /usr /opt -type f -name backup-config.pl 2>/dev/null | head -n1 || true)"
    [[ -n "${BACKUP_CONFIG_BIN}" && -x "${BACKUP_CONFIG_BIN}" ]] || BACKUP_CONFIG_BIN=""
  fi

  if [[ -n "${BACKUP_CONFIG_BIN}" ]]; then
    log "Backing up Webmin/Virtualmin config via ${BACKUP_CONFIG_BIN} ..."
    # Most builds: backup-config.pl --all <outfile>
    "${BACKUP_CONFIG_BIN}" --all "${CONFIG_BACKUP}" || log "⚠ Config backup returned non-zero (continuing)."
    [[ -f "${CONFIG_BACKUP}" ]] && log "✔ Config backup created: ${CONFIG_BACKUP}" || log "⚠ Config archive not found after run (skipping)."
  else
    log "⚠ Could not find 'backup-config.pl'; skipping config backup (domain backup is still valid)."
  fi
else
  log "Skipping config backup (--no-config)."
fi

# ---------- Local rotation ----------
rotate_local() {
  local dir="$1"
  local keep="$2"
  # List matching backups by mtime desc, skip the newest $keep, delete the rest
  local files
  mapfile -t files < <(find "$dir" -maxdepth 1 -type f \( -name "virtualmin-domains-*.tar.gz" -o -name "*-backup-*.tar.gz" -o -name "webmin-config-*.tar.gz" \) -printf "%T@ %p\n" \
                        | sort -rn | awk '{print $2}')
  local count="${#files[@]}"
  if (( count > keep )); then
    for (( i=keep; i<count; i++ )); do
      rm -f "${files[$i]}" && log "Pruned old local backup: ${files[$i]}"
    done
  fi
}
log "Applying local rotation: keep last ${KEEP_COUNT} in ${TARGET_DIR} ..."
rotate_local "${TARGET_DIR}" "${KEEP_COUNT}"
log "✔ Local rotation done."

# ---------- Upload: S3 / SCP / rsync ----------
upload_s3() {
  [[ -n "${S3_URI}" ]] || die "Missing --s3-uri for S3 backend."
  command -v aws >/dev/null 2>&1 || die "'aws' CLI not found. Install awscli or change backend."

  local args=()
  [[ -n "${AWS_PROFILE}" ]] && args+=(--profile "${AWS_PROFILE}")

  log "Uploading to S3: ${S3_URI}"
  aws "${args[@]}" s3 cp "${DOM_BACKUP}" "${S3_URI}/" >/dev/null
  [[ -f "${CONFIG_BACKUP}" ]] && aws "${args[@]}" s3 cp "${CONFIG_BACKUP}" "${S3_URI}/" >/dev/null || true
  log "✔ S3 upload complete."

  # Remote rotation (S3): keep last N by lexicographic sort (filenames include datetime)
  log "Applying S3 rotation (keep ${KEEP_COUNT}) under ${S3_URI} ..."
  # shellcheck disable=SC2207
  keys=( $(aws "${args[@]}" s3 ls "${S3_URI}/" | awk '{print $4}' | grep -E '(virtualmin-domains-|webmin-config-|-backup-).*.tar.gz' | sort -r) )
  total="${#keys[@]}"
  if (( total > KEEP_COUNT )); then
    for (( i=KEEP_COUNT; i<total; i++ )); do
      aws "${args[@]}" s3 rm "${S3_URI}/${keys[$i]}" >/dev/null && log "Pruned old S3 backup: ${keys[$i]}"
    done
  fi
  log "✔ S3 rotation done."
}

upload_scp() {
  [[ -n "${SCP_USER}" && -n "${SCP_HOST}" && -n "${SCP_PATH}" ]] || die "SCP requires --scp-user, --scp-host, --scp-path."
  local scp_opts=(-P "${SCP_PORT}")
  [[ -n "${SCP_KEY}" ]] && scp_opts+=(-i "${SCP_KEY}")

  log "Uploading via SCP to ${SCP_USER}@${SCP_HOST}:${SCP_PATH}"
  ssh "${SCP_USER}@${SCP_HOST}" -p "${SCP_PORT}" "mkdir -p '${SCP_PATH}'"
  scp "${scp_opts[@]}" "${DOM_BACKUP}" "${SCP_USER}@${SCP_HOST}:${SCP_PATH}/"
  [[ -f "${CONFIG_BACKUP}" ]] && scp "${scp_opts[@]}" "${CONFIG_BACKUP}" "${SCP_USER}@${SCP_HOST}:${SCP_PATH}/" || true
  log "✔ SCP upload complete."

  if [[ "${REMOTE_ROTATE}" == true ]]; then
    log "Pruning remote via SSH: keep ${KEEP_COUNT}"
    ssh -p "${SCP_PORT}" ${SCP_KEY:+-i "${SCP_KEY}"} "${SCP_USER}@${SCP_HOST}" \
      "cd '${SCP_PATH}' && ls -1t ${SHARED_PREFIX_FILTER} 2>/dev/null | awk 'NR>${KEEP_COUNT}' | xargs -r rm -f" \
      && log "✔ Remote rotation done." || log "⚠ Remote rotation skipped/failed (no matching files?)."
  fi
}

upload_rsync() {
  [[ -n "${RSYNC_DEST}" ]] || die "rsync requires --rsync-dest"
  log "Uploading via rsync to ${RSYNC_DEST}"
  rsync ${RSYNC_OPTS} "${DOM_BACKUP}" "${RSYNC_DEST}/"
  [[ -f "${CONFIG_BACKUP}" ]] && rsync ${RSYNC_OPTS} "${CONFIG_BACKUP}" "${RSYNC_DEST}/" || true
  log "✔ rsync upload complete."

  if [[ "${REMOTE_ROTATE}" == true ]]; then
    # Try to infer remote host:path for SSH prune (only works for remote, not local paths)
    local remote_host="${RSYNC_DEST%%:*}"
    local remote_path="${RSYNC_DEST#*:}"
    if [[ "${remote_host}" != "${RSYNC_DEST}" && -n "${remote_path}" ]]; then
      log "Pruning remote via SSH: keep ${KEEP_COUNT}"
      ssh "${remote_host}" "cd '${remote_path}' && ls -1t ${SHARED_PREFIX_FILTER} 2>/dev/null | awk 'NR>${KEEP_COUNT}' | xargs -r rm -f" \
        && log "✔ Remote rotation done." || log "⚠ Remote rotation skipped/failed (no matching files?)."
    else
      log "⚠ Remote rotation not possible (rsync dest not remote or unparsable)."
    fi
  fi
}

case "${BACKEND}" in
  local)   log "Backend: local (no upload).";;
  s3)      upload_s3;;
  scp)     upload_scp;;
  rsync)   upload_rsync;;
  *)       die "Unknown backend: ${BACKEND}";;
esac

log "✅ Backup workflow completed."
log "Local dir: ${TARGET_DIR}"
[[ "${BACKEND}" != "local" ]] && log "Remote backend: ${BACKEND}"
