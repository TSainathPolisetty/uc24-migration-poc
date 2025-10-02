#!/bin/sh
set -eu
# ---------- config ----------
LOG_TAG="[migration-agent]"
LOG_FILE="/run/migration.log"
CONSOLE="/dev/console"
KMSG="/dev/kmsg"

SNAP_NAME="cascade-migration"
SEED_MNT="/run/mnt/ubuntu-seed"
DATA_MNT=""
SNAP_MNT="/mnt/${SNAP_NAME}"
SEED_DEV="/dev/vda2"
# ----------------------------

ts() { date -u +"%Y-%m-%d %H:%M:%S UTC"; }

log() {
    msg="$LOG_TAG [$(ts)] $*"
    printf "*** .. %s .. !!!\n" "$msg" | tee -a "$LOG_FILE" > "$CONSOLE" 2>/dev/null || true
    [ -w "$KMSG" ] && printf "%s\n" "$msg" > "$KMSG" || true
}

fail() { log "[ERROR] $*"; exit 1; }

step_i=0
step() { step_i=$((step_i+1)); log "=== Step ${step_i}: $* ==="; }

on_err() { fail "Unexpected error at line $1"; }
trap 'on_err $LINENO' ERR

log "=== Migration agent started ==="

# --- Step 1: ensure ubuntu-data mount ---
step "ensuring ubuntu-data mount"
if grep -q " /run/mnt/ubuntu-data " /proc/mounts; then
    DATA_MNT="/run/mnt/ubuntu-data"
elif grep -q " /sysroot/writable " /proc/mounts; then
    DATA_MNT="/sysroot/writable"
else
    fail "ubuntu-data not mounted yet, cannot continue"
fi
log "using ubuntu-data at $DATA_MNT"

# --- Adjust for UC layout (system-data/) ---
BASE="$DATA_MNT/system-data"

# --- Step 2: locate snap squashfs ---
step "looking for sideloaded snap file"
SNAP_DIR="$BASE/var/lib/snapd/snaps"
SNAP_FILE="$(ls ${SNAP_DIR}/${SNAP_NAME}_*.snap 2>/dev/null | sort | tail -n1 || true)"
[ -n "$SNAP_FILE" ] || fail "snap file not found in $SNAP_DIR"
log "snap file: $SNAP_FILE"

# --- Step 3: mount snap squashfs ---
step "mounting snap squashfs"
mkdir -p "$SNAP_MNT"
mount -t squashfs -o ro,loop "$SNAP_FILE" "$SNAP_MNT" || fail "cannot mount $SNAP_FILE"
log "mounted at $SNAP_MNT"

# --- Step 4: config ---
CONF_PATH="$SNAP_MNT/etc/migration.conf"
[ -f "$CONF_PATH" ] || fail "migration.conf not found at $CONF_PATH"
log "using config: $CONF_PATH"

. "$CONF_PATH"
[ "${MIGRATE_CORE:-False}" = "True" ] || { step "MIGRATE_CORE not True; exiting"; exit 0; }

# --- Step 5: payload ---
step "resolving payload image inside snap"
IMG_PATH="$SNAP_MNT/payloads/uc24.img"
[ -f "$IMG_PATH" ] || fail "payload image not found at $IMG_PATH"
log "payload found: $IMG_PATH"

# --- Step 6: check partition info (BusyBox safe) ---
step "checking partition info from /proc and /sys"
cat /proc/partitions | while read -r line; do log "    $line"; done
SEED_SECTORS="$(cat /sys/block/vda/vda2/size)"
SEED_SIZE=$((SEED_SECTORS * 512))
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
log "image size: $IMG_SIZE bytes"
log "seed size: $SEED_SIZE bytes"
[ "$IMG_SIZE" -lt "$SEED_SIZE" ] || fail "image too large for $SEED_DEV"

# --- Step 7: unmount seed if mounted ---
if mountpoint -q "$SEED_MNT"; then
    log "unmounting $SEED_MNT before flashing"
    umount -l "$SEED_MNT" || fail "failed to unmount $SEED_MNT"
fi

# --- Step 8: flash with cat ---
step "flashing image with cat (no dd available on minimal Busybox)"
log "running: cat $IMG_PATH > $SEED_DEV"
cat "$IMG_PATH" > "$SEED_DEV" || fail "cat copy failed"
sync
log "flashing complete"

# --- Step 9: finish ---
step "migration complete, rebooting"
log "=== Migration agent finished ==="
reboot -f
