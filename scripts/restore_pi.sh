#!/usr/bin/env bash
# =============================================================================
# restore_pi.sh — Restore TeslaUSB Pi state from a local Mac backup
#
# Run from the Mac AFTER:
#   1. Flashing a fresh SD card with Raspberry Pi OS
#   2. SSHing in and running: git clone https://github.com/pabloromeu/TeslaUSB.git
#   3. Running: sudo bash setup_usb.sh  (select option 1 for fresh install)
#
# This script restores everything setup_usb.sh doesn't handle:
#   config.yaml, secrets (rclone, WiFi), runtime state, database, media files.
#
# Usage:
#   bash scripts/restore_pi.sh [--host <hostname>] [--backup-dir <path>]
#
# Defaults:
#   PI_HOST     = pablo@teslausb.local
#   BACKUP_DIR  = ~/personal/TeslaUSB-backup
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PI_HOST="${PI_HOST:-pablo@teslausb.local}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/personal/TeslaUSB-backup}"
PI_REPO="/home/pablo/TeslaUSB"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SSH="sshpass -p marian26 ssh $SSH_OPTS"
SCP="sshpass -p marian26 scp $SSH_OPTS"
RSYNC="sshpass -p marian26 rsync -az --exclude='.DS_Store'"

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)       PI_HOST="$2";    shift 2 ;;
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

push_file() {
  local src="$1" remote_dest="$2" label="$3"
  if [[ -s "$src" ]]; then
    $SCP "$src" "$PI_HOST:$remote_dest" 2>/dev/null && ok "$label" || fail "$label (scp failed)"
  else
    skip "$label (not in backup)"
  fi
}

push_file_sudo() {
  # For files that need root ownership on the Pi (copy via /tmp then sudo mv)
  local src="$1" remote_dest="$2" label="$3" owner="${4:-root:root}" mode="${5:-644}"
  if [[ -s "$src" ]]; then
    local tmp="/tmp/restore_$(basename "$src")"
    $SCP "$src" "$PI_HOST:$tmp" 2>/dev/null \
      && $SSH "$PI_HOST" "sudo mv $tmp $remote_dest && sudo chown $owner $remote_dest && sudo chmod $mode $remote_dest" \
      && ok "$label" \
      || fail "$label (failed)"
  else
    skip "$label (not in backup)"
  fi
}

rsync_dir() {
  local src="$1" remote_dest="$2" label="$3"
  if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
    $RSYNC "$src/" "$PI_HOST:$remote_dest/" 2>/dev/null && ok "$label" || fail "$label (rsync failed)"
  else
    skip "$label (empty in backup)"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo " TeslaUSB Pi Restore"
echo " Host:       $PI_HOST"
echo " Backup dir: $BACKUP_DIR"
echo "========================================"
echo ""

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo -e "${RED}ERROR: Backup directory not found: $BACKUP_DIR${NC}"
  exit 1
fi

echo "Checking Pi connectivity..."
if ! $SSH "$PI_HOST" "echo ok" &>/dev/null; then
  echo -e "${RED}ERROR: Cannot reach $PI_HOST. Is the Pi on the network?${NC}"
  exit 1
fi
ok "Pi is reachable"

# Verify setup_usb.sh has been run (repo should exist)
if ! $SSH "$PI_HOST" "test -d $PI_REPO" 2>/dev/null; then
  echo -e "${RED}ERROR: $PI_REPO not found on Pi.${NC}"
  echo "  Please run: git clone https://github.com/pabloromeu/TeslaUSB.git && sudo bash TeslaUSB/setup_usb.sh"
  exit 1
fi
ok "Pi repo exists"
echo ""

# ---------------------------------------------------------------------------
# 1. Config
# ---------------------------------------------------------------------------
echo "[1/6] Config"
push_file "$BACKUP_DIR/config.yaml" "$PI_REPO/config.yaml" "config.yaml"
$SSH "$PI_HOST" "sudo systemctl restart gadget_web.service 2>/dev/null || true"
echo ""

# ---------------------------------------------------------------------------
# 2. Secrets
# ---------------------------------------------------------------------------
echo "[2/6] Secrets"

# machine-id — MUST be restored before cloud_provider.enc in step 3.
# cloud_provider.enc is encrypted with: Pi serial + machine-id + tesla_salt.bin.
# Restoring the original machine-id ensures the token can be decrypted.
if [[ -s "$BACKUP_DIR/secrets/machine-id" ]]; then
  CURRENT_ID=$($SSH "$PI_HOST" "cat /etc/machine-id" 2>/dev/null || echo "")
  BACKUP_ID=$(cat "$BACKUP_DIR/secrets/machine-id")
  if [[ "$CURRENT_ID" == "$BACKUP_ID" ]]; then
    ok "machine-id already matches backup — no change needed"
  else
    push_file_sudo "$BACKUP_DIR/secrets/machine-id" "/etc/machine-id" \
                   "machine-id (restoring original so cloud token decrypts)" \
                   "root:root" "444"
    echo ""
    echo -e "  ${YELLOW}NOTE: machine-id was restored. A reboot is recommended before using cloud sync.${NC}"
  fi
else
  skip "machine-id (not in backup — cloud credentials may not decrypt)"
fi

# rclone.conf is written to tmpfs on-the-fly from cloud_provider.enc — not needed here.
skip "rclone.conf (token stored in cloud_provider.enc, not rclone.conf)"

# WiFi profiles
if [[ -d "$BACKUP_DIR/secrets/wifi" ]] && [[ -n "$(ls -A "$BACKUP_DIR/secrets/wifi" 2>/dev/null)" ]]; then
  for profile in "$BACKUP_DIR/secrets/wifi/"*; do
    name="$(basename "$profile")"
    push_file_sudo "$profile" \
                   "/etc/NetworkManager/system-connections/$name" \
                   "WiFi: $name" \
                   "root:root" "600"
  done
  $SSH "$PI_HOST" "sudo nmcli connection reload 2>/dev/null || true" && ok "NetworkManager reloaded"
else
  skip "WiFi profiles (not in backup)"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Runtime state files
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
  push_file "$BACKUP_DIR/runtime/$f" "$PI_REPO/$f" "$f"
done
# Fix ownership — these files were root-owned on the Pi
$SSH "$PI_HOST" "sudo chown root:pablo $PI_REPO/cloud_provider.enc $PI_REPO/tesla_salt.bin $PI_REPO/cloud_sync.db 2>/dev/null || true"
echo ""

# ---------------------------------------------------------------------------
# 4. Database
# ---------------------------------------------------------------------------
echo "[4/6] Database"
push_file "$BACKUP_DIR/database/geodata.db" "$PI_REPO/geodata.db" "geodata.db"
$SSH "$PI_HOST" "sudo chown root:pablo $PI_REPO/geodata.db 2>/dev/null || true"
echo ""

# ---------------------------------------------------------------------------
# 5. Media files — switch Pi to edit mode, rsync, switch back
# ---------------------------------------------------------------------------
echo "[5/6] Media files"

HAS_MEDIA=false
for d in Chimes LightShow "Media/Boombox" "Media/Wraps" "Media/LicensePlate"; do
  [[ -d "$BACKUP_DIR/$d" ]] && [[ -n "$(ls -A "$BACKUP_DIR/$d" 2>/dev/null)" ]] && HAS_MEDIA=true && break
done

if $HAS_MEDIA; then
  echo "  Switching Pi to edit mode..."
  $SSH "$PI_HOST" "sudo bash $PI_REPO/scripts/edit_usb.sh" &>/dev/null
  ok "Edit mode active"

  rsync_dir "$BACKUP_DIR/Chimes"             "/mnt/gadget/part2/Chimes"        "Chimes/"
  rsync_dir "$BACKUP_DIR/LightShow"          "/mnt/gadget/part2/LightShow"     "LightShow/"
  rsync_dir "$BACKUP_DIR/Media/Wraps"        "/mnt/gadget/part2/Wrap"          "Wraps → Wrap/"
  rsync_dir "$BACKUP_DIR/Media/LicensePlate" "/mnt/gadget/part2/LicensePlate"  "LicensePlate/"
  rsync_dir "$BACKUP_DIR/Media/Boombox"      "/mnt/gadget/part3/Boombox"       "Boombox/"

  echo "  Switching Pi back to present mode..."
  $SSH "$PI_HOST" "sudo bash $PI_REPO/scripts/present_usb.sh" &>/dev/null
  ok "Present mode restored"
else
  skip "No media files found in backup"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo "[6/6] Done"
echo ""
echo -e "${GREEN}Restore complete.${NC}"
echo ""
echo "  Recommended next steps:"
echo "  1. Verify web UI at http://teslausb.local"
echo "  2. If rclone was not restored, run: ssh pablo@teslausb.local 'rclone config'"
echo "  3. Reconnect Tesla to USB to confirm gadget is recognized"
echo ""
