#!/usr/bin/env bash
# =============================================================================
# backup_pi.sh — Back up TeslaUSB Pi state to a local Mac directory
#
# Run from the Mac. Pulls config, secrets, runtime state, and media files
# from the Pi over SSH and stores them in BACKUP_DIR.
#
# Usage:
#   bash scripts/backup_pi.sh [--host <hostname>] [--backup-dir <path>]
#
# Defaults:
#   PI_HOST     = pablo@teslausb.local
#   BACKUP_DIR  = ~/personal/TeslaUSB-backup
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override with flags or environment variables)
# ---------------------------------------------------------------------------
PI_HOST="${PI_HOST:-pablo@teslausb.local}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/personal/TeslaUSB-backup}"
PI_REPO="/home/pablo/TeslaUSB"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SSH="sshpass -p marian26 ssh $SSH_OPTS"
SCP="sshpass -p marian26 scp $SSH_OPTS"
RSYNC="sshpass -p marian26 rsync -az --exclude='.DS_Store'"

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --host)       PI_HOST="$2";   shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
skip() { echo -e "  ${YELLOW}–${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }

scp_file() {
  local remote="$1" local_dest="$2" label="$3"
  mkdir -p "$(dirname "$local_dest")"
  if $SSH "$PI_HOST" "test -s $remote" 2>/dev/null; then
    $SCP "$PI_HOST:$remote" "$local_dest" 2>/dev/null && ok "$label" || fail "$label (scp failed)"
  else
    skip "$label (not present or empty on Pi)"
  fi
}

rsync_dir() {
  local remote="$1" local_dest="$2" label="$3"
  mkdir -p "$local_dest"
  $RSYNC "$PI_HOST:$remote/" "$local_dest/" 2>/dev/null && ok "$label" || fail "$label (rsync failed)"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo " TeslaUSB Pi Backup"
echo " Host:       $PI_HOST"
echo " Backup dir: $BACKUP_DIR"
echo "========================================"
echo ""

echo "Checking Pi connectivity..."
if ! $SSH "$PI_HOST" "echo ok" &>/dev/null; then
  echo -e "${RED}ERROR: Cannot reach $PI_HOST. Is the Pi on?${NC}"
  exit 1
fi
ok "Pi is reachable"
echo ""

mkdir -p "$BACKUP_DIR"/{secrets/wifi,database,runtime}

# ---------------------------------------------------------------------------
# 1. Main config
# ---------------------------------------------------------------------------
echo "[1/6] Config"
scp_file "$PI_REPO/config.yaml" "$BACKUP_DIR/config.yaml" "config.yaml"

# Also write to repo .local/ (gitignored, per CLAUDE.md)
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "$REPO_DIR" ]]; then
  mkdir -p "$REPO_DIR/.local"
  scp_file "$PI_REPO/config.yaml" "$REPO_DIR/.local/config.pi.yaml" "config.yaml → .local/config.pi.yaml"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Secrets (rclone, WiFi)
# ---------------------------------------------------------------------------
echo "[2/6] Secrets"
scp_file "/home/pablo/.config/rclone/rclone.conf" \
         "$BACKUP_DIR/secrets/rclone.conf" \
         "rclone.conf (Google Drive token)"

# WiFi profiles (need sudo)
$SSH "$PI_HOST" "sudo ls /etc/NetworkManager/system-connections/" 2>/dev/null \
| while read -r profile; do
  [[ -z "$profile" ]] && continue
  dest="$BACKUP_DIR/secrets/wifi/$profile"
  $SCP "$PI_HOST:/etc/NetworkManager/system-connections/$profile" "$dest" 2>/dev/null \
    && ok "WiFi: $profile" \
    || {
      # nmconnection files are root:root 600, need sudo cat
      $SSH "$PI_HOST" "sudo cat '/etc/NetworkManager/system-connections/$profile'" > "$dest" 2>/dev/null \
        && ok "WiFi: $profile (via sudo)" \
        || fail "WiFi: $profile"
    }
done
echo ""

# ---------------------------------------------------------------------------
# 3. Runtime state files (app data, not code)
# ---------------------------------------------------------------------------
echo "[3/6] Runtime state"
for f in \
    cloud_provider.enc \
    cloud_sync.db \
    tesla_salt.bin \
    chime_groups.json \
    chime_random_config.json \
    chime_scheduler.db \
    fsck_history.json \
    fsck_status.json; do
  scp_file "$PI_REPO/$f" "$BACKUP_DIR/runtime/$f" "$f"
done
echo ""

# ---------------------------------------------------------------------------
# 4. Database
# ---------------------------------------------------------------------------
echo "[4/6] Database"
scp_file "$PI_REPO/geodata.db" "$BACKUP_DIR/database/geodata.db" "geodata.db"
echo ""

# ---------------------------------------------------------------------------
# 5. Media files (Chimes, LightShow, Boombox, Wraps, LicensePlate)
#    Pi must be in present mode — read from RO mounts
# ---------------------------------------------------------------------------
echo "[5/6] Media files"

# Determine correct mount prefix (present mode = *-ro, edit mode = plain)
PART2=$($SSH "$PI_HOST" "
  if mountpoint -q /mnt/gadget/part2 2>/dev/null; then echo /mnt/gadget/part2
  elif mountpoint -q /mnt/gadget/part2-ro 2>/dev/null; then echo /mnt/gadget/part2-ro
  else echo ''; fi
")
PART3=$($SSH "$PI_HOST" "
  if mountpoint -q /mnt/gadget/part3 2>/dev/null; then echo /mnt/gadget/part3
  elif mountpoint -q /mnt/gadget/part3-ro 2>/dev/null; then echo /mnt/gadget/part3-ro
  else echo ''; fi
")

if [[ -n "$PART2" ]]; then
  rsync_dir "$PART2/Chimes"       "$BACKUP_DIR/Chimes"              "Chimes/"
  rsync_dir "$PART2/LightShow"    "$BACKUP_DIR/LightShow"           "LightShow/"
  rsync_dir "$PART2/Wrap"         "$BACKUP_DIR/Media/Wraps"         "Wrap/ → Media/Wraps/"
  rsync_dir "$PART2/LicensePlate" "$BACKUP_DIR/Media/LicensePlate"  "LicensePlate/"
else
  skip "part2 not mounted — skipping Chimes, LightShow, Wrap, LicensePlate"
fi

if [[ -n "$PART3" ]]; then
  rsync_dir "$PART3/Boombox" "$BACKUP_DIR/Media/Boombox" "Boombox/"
else
  skip "part3 not mounted — skipping Boombox"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo "[6/6] Summary"
echo ""
echo "  Backup location: $BACKUP_DIR"
echo ""
echo "  $(find "$BACKUP_DIR/Chimes"             -type f 2>/dev/null | wc -l | tr -d ' ') chime files"
echo "  $(find "$BACKUP_DIR/LightShow"           -type f 2>/dev/null | wc -l | tr -d ' ') light show files"
echo "  $(find "$BACKUP_DIR/Media"               -type f 2>/dev/null | wc -l | tr -d ' ') media files (Boombox/Wraps/LicensePlate)"
echo "  $(find "$BACKUP_DIR/runtime"             -type f 2>/dev/null | wc -l | tr -d ' ') runtime state files"
echo "  $(find "$BACKUP_DIR/secrets"             -type f 2>/dev/null | wc -l | tr -d ' ') secret files"
echo "  $(find "$BACKUP_DIR/database"            -type f 2>/dev/null | wc -l | tr -d ' ') database files"
echo ""

RCLONE_STATUS="$BACKUP_DIR/secrets/rclone.conf"
if [[ -s "$RCLONE_STATUS" ]]; then
  ok "Google Drive token backed up"
else
  skip "Google Drive token not backed up (run rclone config on Pi first)"
fi

echo ""
echo -e "${GREEN}Backup complete.${NC}"
echo ""
echo "  IMPORTANT: $BACKUP_DIR/secrets/ contains WiFi PSKs and cloud tokens."
echo "  Never commit this folder to git."
echo ""
