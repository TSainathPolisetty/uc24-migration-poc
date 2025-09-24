#!/bin/sh
set -eu

# ---------- config ----------
LOG_TAG="[migration-agent]"
LOG_FILE="/run/migration.log"
CONSOLE="/dev/console"
KMSG="/dev/kmsg"

SEED_MNT="/run/mnt/ubuntu-seed"
DATA_MNT="/run/migration-data"
SNAP_MNT="/run/mnt/cascade-snap"           # temp mount for seeded snap (squashfs)
SNAP_NAME="cascade-migration"
DEFAULT_IMG_REL="/migration/uc24.img"      # default image path inside ubuntu-data
# ----------------------------

# live logger:
# - character-per-line to console + dmesg
# - single-line with UTC timestamp to /run/migration.log
log() {
    msg="$LOG_TAG $*"

    for c in $(printf "%s" "$msg" | sed -e 's/./& /g'); do
        [ -w "$KMSG" ]    && printf "%s\n" "$c" > "$KMSG"    || true
        [ -w "$CONSOLE" ] && printf "%s\n" "$c" > "$CONSOLE" || true
    done

    printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

fail() {
    log "[ERROR] $*"
    exit 1
}

step_i=0
step() {
    step_i=$((step_i + 1))
    log "=== Step ${step_i}: $* ==="
}

on_err() { fail "Unexpected error at line $1"; }
trap 'on_err $LINENO' ERR

cleanup_mounts() {
    if mountpoint -q "$SNAP_MNT"; then umount "$SNAP_MNT" || true; fi
    if [ -n "${SNAP_LOOP:-}" ] && losetup "$SNAP_LOOP" >/dev/null 2>&1; then
        losetup -d "$SNAP_LOOP" || true
    fi
    if mountpoint -q "$DATA_MNT"; then umount "$DATA_MNT" || true; fi
}
trap cleanup_mounts EXIT

log "=== Migration agent started at $(date -u) ==="

# --- enumerate mounted snaps from /proc/mounts ---
list_mounted_snaps() {
    awk '$3=="squashfs" && $2 ~ /^\/snap\// {print $2 " -> " $1}' /proc/mounts 2>/dev/null \
      | while read -r line; do log "snap mounted: $line"; done

    if ! awk '$3=="squashfs" && $2 ~ /^\/snap\//' /proc/mounts >/dev/null 2>&1; then
        log "no snaps appear mounted yet (initramfs stage)"
    fi
}

find_seeded_snap() {
    for f in "$SEED_MNT/snaps/${SNAP_NAME}"*.snap \
             "$SEED_MNT/systems"/*/snaps/"${SNAP_NAME}"*.snap; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

find_migration_conf() {
    CANDIDATES="
$DATA_MNT/var/snap/${SNAP_NAME}/current/migration.conf
$DATA_MNT/system-data/var/snap/${SNAP_NAME}/current/migration.conf
$DATA_MNT/var/lib/${SNAP_NAME}/migration.conf
$DATA_MNT/system-data/var/lib/${SNAP_NAME}/migration.conf
"
    for p in $CANDIDATES; do
        if [ -f "$p" ]; then echo "$p"; return 0; fi
    done

    SNAP_FILE="$(find_seeded_snap || true)"
    if [ -n "$SNAP_FILE" ] && [ -f "$SNAP_FILE" ]; then
        mkdir -p "$SNAP_MNT"
        SNAP_LOOP="$(losetup -f --show "$SNAP_FILE")" || fail "losetup failed"
        mount -t squashfs -o ro "$SNAP_LOOP" "$SNAP_MNT" || fail "mount squashfs failed"

        for inside in \
            "$SNAP_MNT/etc/${SNAP_NAME}/migration.conf" \
            "$SNAP_MNT/migration.conf" \
            "$SNAP_MNT/config/migration.conf"
        do
            if [ -f "$inside" ]; then echo "$inside"; return 0; fi
        done

        umount "$SNAP_MNT" || true
        losetup -d "$SNAP_LOOP" || true
        SNAP_LOOP=""
    fi

    echo ""
    return 1
}

# 0. list mounted snaps
step "enumerating snap mounts"
list_mounted_snaps

# 1. check seed mount
step "checking seed mount at $SEED_MNT"
if [ ! -d "$SEED_MNT/snaps" ]; then
    log "seed snaps dir not present, exiting early"
    exit 0
fi

# 2. check for pre-seeded snap
step "checking for ${SNAP_NAME} in seed"
SEEDED_SNAP="$(find_seeded_snap || true)"
if [ -n "$SEEDED_SNAP" ]; then
    log "found seeded snap: $SEEDED_SNAP"
else
    log "no ${SNAP_NAME} snap found in seed, exiting"
    exit 0
fi

# 3. resolve block devices
step "resolving block devices"
SEED_DEV="$(readlink -f /dev/disk/by-label/ubuntu-seed || true)"
DATA_DEV="$(readlink -f /dev/disk/by-label/ubuntu-data || true)"
[ -n "$SEED_DEV" ] || fail "device labeled ubuntu-seed not found"
[ -n "$DATA_DEV" ] || fail "device labeled ubuntu-data not found"
log "seed device: ${SEED_DEV}"
log "data device: ${DATA_DEV}"

# 4. mount ubuntu-data
step "mounting ubuntu-data read-only"
mkdir -p "$DATA_MNT"
if ! mountpoint -q "$DATA_MNT"; then
    mount -o ro "$DATA_DEV" "$DATA_MNT" || fail "mount ${DATA_DEV} failed"
fi
log "mounted ${DATA_DEV} at ${DATA_MNT} (ro)"

# 5. locate config
step "locating migration.conf"
CONF_PATH="$(find_migration_conf || true)"
[ -n "$CONF_PATH" ] || fail "migration.conf not found"
log "using config: ${CONF_PATH}"

# 6. source config
. "$CONF_PATH"
log "config loaded: MIGRATE_CORE=${MIGRATE_CORE:-unset} SEED_LOCATION=${SEED_LOCATION:-unset}"

if [ "${MIGRATE_CORE:-False}" != "True" ]; then
    step "MIGRATE_CORE not True, nothing to do"
    exit 0
fi

# 7. resolve image path
step "resolving image path"
if [ -n "${SEED_LOCATION:-}" ]; then
    case "$SEED_LOCATION" in
        /*) IMG_PATH="${DATA_MNT}${SEED_LOCATION}" ;;
        *)  IMG_PATH="${DATA_MNT}/${SEED_LOCATION}" ;;
    esac
else
    IMG_PATH="${DATA_MNT}${DEFAULT_IMG_REL}"
fi
[ -f "$IMG_PATH" ] || fail "target image not found: ${IMG_PATH}"
log "image found: ${IMG_PATH}"

# 8. size checks
step "validating image size vs seed"
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
SEED_SIZE="$(blockdev --getsize64 "$SEED_DEV")"
log "seed size: ${SEED_SIZE} bytes"
log "image size: ${IMG_SIZE} bytes"
[ "$IMG_SIZE" -lt "$SEED_SIZE" ] || fail "image too large for seed device"

# 9. flash image
step "flashing image to seed"
dd bs=4M status=progress if="$IMG_PATH" of="$SEED_DEV" conv=fsync || fail "dd failed"
sync
log "flashing complete"

# 10. cleanup
step "cleanup"
if mountpoint -q "$SNAP_MNT"; then umount "$SNAP_MNT" || true; fi
if [ -n "${SNAP_LOOP:-}" ]; then losetup -d "$SNAP_LOOP" || true; fi
if mountpoint -q "$DATA_MNT"; then umount "$DATA_MNT" || true; fi

# 11. finish
step "migration complete, rebooting now"
log "=== Migration agent finished at $(date -u) ==="
reboot -f

