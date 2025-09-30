#!/bin/sh
set -eu
# ---------- config ----------
LOG_TAG="[migration-agent]"
LOG_FILE="/run/migration.log"
CONSOLE="/dev/console"
KMSG="/dev/kmsg"

SEED_MNT="/run/mnt/ubuntu-seed"
DATA_MNT=""
SNAP_NAME="cascade-migration"
IMG_PATH="/snap/${SNAP_NAME}/current/payloads/uc24.img"
# ----------------------------

log() {
    msg="$LOG_TAG $*"
    printf "*** .. %s .. !!!\n" "$msg" | tee -a "$LOG_FILE" > "$CONSOLE" 2>/dev/null || true
    [ -w "$KMSG" ] && printf "%s\n" "$msg" > "$KMSG" || true
}

fail() { log "[ERROR] $*"; exit 1; }

step_i=0
step() { step_i=$((step_i+1)); log "=== Step ${step_i}: $* ==="; }

on_err() { fail "Unexpected error at line $1"; }
trap 'on_err $LINENO' ERR

log "=== Migration agent started at $(date -u) ==="

# --- Step 1: ensure ubuntu-data ---
step "ensuring ubuntu-data mount"
if grep -q " /run/mnt/ubuntu-data " /proc/mounts; then
    DATA_MNT="/run/mnt/ubuntu-data"
elif grep -q " /sysroot/writable " /proc/mounts; then
    DATA_MNT="/sysroot/writable"
else
    fail "ubuntu-data not mounted yet, cannot continue"
fi
log "using ubuntu-data at $DATA_MNT"

# --- Step 2: locate config ---
step "locating migration.conf"
CONF_PATH="$DATA_MNT/var/snap/${SNAP_NAME}/current/migration.conf"
[ -f "$CONF_PATH" ] || fail "migration.conf not found at $CONF_PATH"
log "using config: $CONF_PATH"

# --- Step 3: source config ---
step "loading migration.conf"
cat "$CONF_PATH" | while read -r line; do log "  conf: $line"; done
. "$CONF_PATH"

[ "${MIGRATE_CORE:-False}" = "True" ] || { step "MIGRATE_CORE not True"; exit 0; }

# --- Step 4: resolve image path ---
step "resolving image path"
[ -f "$IMG_PATH" ] || fail "image not found: $IMG_PATH"
log "image found: $IMG_PATH"

# --- Step 5: block devices ---
step "resolving block devices (hardcoded)"
SEED_DEV="/dev/vda2"
log "seed device: $SEED_DEV"

# --- Step 6: validate size ---
step "validating image size vs seed"
stat "$IMG_PATH" 2>&1 | while read -r line; do log "  $line"; done
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
SEED_SIZE="$(blockdev --getsize64 "$SEED_DEV")"
log "seed size: $SEED_SIZE bytes"
log "image size: $IMG_SIZE bytes"
[ "$IMG_SIZE" -lt "$SEED_SIZE" ] || fail "image too large"

# --- Step 7: unmount seed ---
step "unmounting seed before flashing"
if mountpoint -q "$SEED_MNT"; then
    umount "$SEED_MNT" || fail "failed to unmount $SEED_MNT"
fi

# --- Step 8: flash ---
step "flashing image to seed"
dd bs=4M if="$IMG_PATH" of="$SEED_DEV" status=progress || fail "dd failed"
sync
log "flashing complete"

# --- Step 9: finish ---
step "migration complete, rebooting"
log "=== Migration agent finished at $(date -u) ==="
reboot -f
