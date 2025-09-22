#!/bin/sh
set -eu

LOG_TAG="[migration-agent]"
log() { printf "%s %s\n" "$LOG_TAG" "$*" | tee -a /run/migration.log >/dev/kmsg; }
fail() { printf "%s [ERROR] %s\n" "$LOG_TAG" "$*" | tee -a /run/migration.log >/dev/kmsg; exit 1; }

# 1) Resolve block devices by label (no hardcoding /dev/vdX)
SEED_DEV="$(blkid -L ubuntu-seed || true)"
DATA_DEV="$(blkid -L ubuntu-data || true)"
[ -n "$SEED_DEV" ] || fail "Device labeled 'ubuntu-seed' not found"
[ -n "$DATA_DEV" ] || fail "Device labeled 'ubuntu-data' not found"

log "Seed device: $SEED_DEV"
log "Data device: $DATA_DEV"

# 2) Locate migration.conf placed by cascade-migration install hook
SNAP_NAME="cascade-migration"
if [ -n "${SNAP_DATA:-}" ]; then
  CONF_PATH="$SNAP_DATA/migration.conf"
else
  # Typical UC paths pre/post pivot
  if   [ -f "/writable/var/snap/$SNAP_NAME/current/migration.conf" ]; then
    CONF_PATH="/writable/var/snap/$SNAP_NAME/current/migration.conf"
  elif [ -f "/var/snap/$SNAP_NAME/current/migration.conf" ]; then
    CONF_PATH="/var/snap/$SNAP_NAME/current/migration.conf"
  else
    fail "migration.conf not found under \$SNAP_DATA or /writable/var/snap/$SNAP_NAME/current/"
  fi
fi
log "Using config: $CONF_PATH"

# 3) Source config and gate on MIGRATE_CORE
# shellcheck disable=SC1090
. "$CONF_PATH"
if [ "${MIGRATE_CORE:-False}" != "True" ]; then
  log "MIGRATE_CORE!=True, exiting without changes"
  exit 0
fi
log "MIGRATE_CORE=True, proceeding"

# 4) Mount ubuntu-data read-only at a private mountpoint
DATA_MNT="/run/migration-data"
mkdir -p "$DATA_MNT"
if ! mountpoint -q "$DATA_MNT"; then
  mount -o ro "$DATA_DEV" "$DATA_MNT" || fail "Mount $DATA_DEV at $DATA_MNT failed"
fi

# 5) Resolve image path on ubuntu-data (default /migration/uc24.img)
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
log "Image: $IMG_PATH"

# 6) Size checks: ensure image fits in ubuntu-seed
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
SEED_SIZE="$(blockdev --getsize64 "$SEED_DEV")"
log "Seed size: $SEED_SIZE bytes"
log "Image size: $IMG_SIZE bytes"

# Must be strictly smaller to avoid overrun into following partitions
if [ "$IMG_SIZE" -ge "$SEED_SIZE" ]; then
  fail "Image too large for ubuntu-seed; rebuild with larger -seed partition"
fi

# 7) Flash image to ubuntu-seed
log "Flashing image to $SEED_DEV (dd bs=4M conv=fsync)…"
dd if="$IMG_PATH" of="$SEED_DEV" bs=4M status=progress conv=fsync || fail "dd failed"
log "Syncing..."
sync

# 8) Cleanup and reboot
if mountpoint -q "$DATA_MNT"; then
  umount "$DATA_MNT" || log "Warning: umount $DATA_MNT failed"
fi
log "Migration complete; rebooting"
reboot -f
