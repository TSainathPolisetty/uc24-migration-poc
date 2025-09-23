#!/bin/sh
set -eu

LOG_TAG="[migration-agent]"
LOG_FILE="/run/migration.log"
log() { printf "%s %s\n" "$LOG_TAG" "$*" | tee -a "$LOG_FILE" >/dev/kmsg; }
fail() { printf "%s [ERROR] %s\n" "$LOG_TAG" "$*" | tee -a "$LOG_FILE" >/dev/kmsg; exit 1; }

log "=== Migration agent started at $(date) ==="

# 0) Verify cascade-migration snap presence
if [ ! -d "/writable/var/snap/cascade-migration" ] && [ ! -d "/var/snap/cascade-migration" ]; then
    log "No cascade-migration snap found. Exiting without action."
    exit 0
fi
log "cascade-migration snap detected."

# 1) Resolve block devices by label
SEED_DEV="$(blkid -L ubuntu-seed || true)"
DATA_DEV="$(blkid -L ubuntu-data || true)"
[ -n "$SEED_DEV" ] || fail "Device labeled 'ubuntu-seed' not found"
[ -n "$DATA_DEV" ] || fail "Device labeled 'ubuntu-data' not found"

log "Seed device: $SEED_DEV"
log "Data device: $DATA_DEV"

# 2) Locate config
SNAP_NAME="cascade-migration"
CONF_PATH=""
for path in \
    "${SNAP_DATA:-}" \
    "/writable/var/snap/$SNAP_NAME/current" \
    "/var/snap/$SNAP_NAME/current"
do
    if [ -n "$path" ] && [ -f "$path/migration.conf" ]; then
        CONF_PATH="$path/migration.conf"
        break
    fi
done
[ -n "$CONF_PATH" ] || fail "migration.conf not found in SNAP_DATA or /var/snap paths"
log "Using config: $CONF_PATH"

# 3) Source config
. "$CONF_PATH"
log "Config loaded: MIGRATE_CORE=${MIGRATE_CORE:-unset}, SEED_LOCATION=${SEED_LOCATION:-unset}"

if [ "${MIGRATE_CORE:-False}" != "True" ]; then
    log "MIGRATE_CORE!=True → no migration performed."
    exit 0
fi
log "MIGRATE_CORE=True → migration will proceed."

# 4) Mount ubuntu-data
DATA_MNT="/run/migration-data"
mkdir -p "$DATA_MNT"
if ! mountpoint -q "$DATA_MNT"; then
    mount -o ro "$DATA_DEV" "$DATA_MNT" || fail "Mount $DATA_DEV at $DATA_MNT failed"
fi
log "Mounted $DATA_DEV at $DATA_MNT"

# 5) Resolve image path
IMG_REL_DEFAULT="/migration/uc24.img"
if [ -n "${SEED_LOCATION:-}" ]; then
    case "$SEED_LOCATION" in
        /*) IMG_PATH="$DATA_MNT$SEED_LOCATION" ;;
        *)  IMG_PATH="$DATA_MNT/$SEED_LOCATION" ;;
    esac
else
    IMG_PATH="$DATA_MNT$IMG_REL_DEFAULT"
fi
[ -f "$IMG_PATH" ] || fail "Target image not found: $IMG_PATH"
log "Image found: $IMG_PATH"

# 6) Size checks
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
SEED_SIZE="$(blockdev --getsize64 "$SEED_DEV")"
log "Seed size: $SEED_SIZE bytes"
log "Image size: $IMG_SIZE bytes"
if [ "$IMG_SIZE" -ge "$SEED_SIZE" ]; then
    fail "Image too large for ubuntu-seed; aborting"
fi

# 7) Flash image
log "Flashing $IMG_PATH to $SEED_DEV"
dd if="$IMG_PATH" of="$SEED_DEV" bs=4M status=progress conv=fsync || fail "dd failed"
sync
log "Flashing complete"

# 8) Cleanup
if mountpoint -q "$DATA_MNT"; then
    umount "$DATA_MNT" || log "Warning: umount $DATA_MNT failed"
fi

log "Migration complete. Rebooting now."
reboot -f
