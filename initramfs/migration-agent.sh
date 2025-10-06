#!/bin/sh
set -eu

LOG_TAG="[migration-agent]"
LOG_FILE="/run/migration.log"
CONSOLE="/dev/console"
KMSG="/dev/kmsg"

SNAP_NAME="cascade-migration"
SNAP_MNT="/mnt/${SNAP_NAME}"
DISK_DEV="/dev/vda"

# --- minimal, POSIX/BusyBox-safe logging + trap/cleanup ---
ts() { date -u +"%Y-%m-%d %H:%M:%S UTC"; }
log() {
  msg="$LOG_TAG [$(ts)] $*"
  printf "*** .. %s .. !!!\n" "$msg" | tee -a "$LOG_FILE" > "$CONSOLE" 2>/dev/null || true
  [ -w "$KMSG" ] && printf "%s\n" "$msg" > "$KMSG" || true
}

# Track a loop device here only if you add image preflight checks later
LOOP_IMG=""

cleanup() {
  rc=$?
  log "=== cleanup(): exit code $rc ==="
  log "--- active mounts ---"
  awk '{print $2" <- "$1}' /proc/mounts | tee -a "$LOG_FILE" >"$CONSOLE" 2>/dev/null || true

  # Unmount migration snap if still mounted
  if [ -n "${SNAP_MNT:-}" ] && grep -q " $SNAP_MNT " /proc/mounts 2>/dev/null; then
    umount "$SNAP_MNT" || log "warning: failed to unmount $SNAP_MNT"
  fi

  # Detach any loop device created for inspection (unused in this version)
  if [ -n "${LOOP_IMG:-}" ]; then
    losetup -d "$LOOP_IMG" 2>/dev/null || true
  fi

  log "=== cleanup complete ==="
  exit $rc
}

# Trap EXIT (success or error) and common signals; dash may not support ERR reliably
trap 'cleanup' EXIT INT TERM HUP

fail() { log "[ERROR] $*"; exit 1; }
step_i=0
step() { step_i=$((step_i+1)); log "=== Step ${step_i}: $* ==="; }

log "=== Migration agent started ==="

# --- Step 1: locate ubuntu-data mount ---
step "ensuring ubuntu-data mount"
if grep -q " /run/mnt/ubuntu-data " /proc/mounts; then
  DATA_MNT="/run/mnt/ubuntu-data"
elif grep -q " /sysroot/writable " /proc/mounts; then
  DATA_MNT="/sysroot/writable"
else
  fail "ubuntu-data not mounted"
fi
log "using ubuntu-data at $DATA_MNT"
BASE="$DATA_MNT/system-data"

# --- Step 2: find and mount snap ---
step "locating sideloaded snap"
SNAP_FILE="$(ls ${BASE}/var/lib/snapd/snaps/${SNAP_NAME}_*.snap 2>/dev/null | sort | tail -n1 || true)"
[ -n "$SNAP_FILE" ] || fail "no snap found"
mkdir -p "$SNAP_MNT"
mount -t squashfs -o ro,loop "$SNAP_FILE" "$SNAP_MNT" || fail "cannot mount snap"
log "mounted snap at $SNAP_MNT"

# --- Step 3: payload image ---
IMG_PATH="$SNAP_MNT/payloads/uc24.img"
[ -f "$IMG_PATH" ] || fail "no payload at $IMG_PATH"
IMG_SIZE="$(stat -c%s "$IMG_PATH")"
log "payload image: $IMG_PATH ($IMG_SIZE bytes)"

# --- Step 3.5: unmount unnecessary partitions and snaps by PARTNAME ---
step "unmounting non-data partitions and snaps"

for dev in /dev/vda*; do
  [ -b "$dev" ] || continue
  sysbase="/sys/class/block/$(basename "$dev")"
  [ -f "$sysbase/uevent" ] || continue
  label="$(grep '^PARTNAME=' "$sysbase/uevent" | cut -d= -f2 || true)"
  case "$label" in
    ubuntu-seed|ubuntu-boot|ubuntu-save)
      mp="$(awk -v d="$dev" '$1==d {print $2}' /proc/mounts)"
      if [ -n "$mp" ]; then
        umount "$dev" || log "warning: failed to unmount $label ($dev)"
      fi
      ;;
    ubuntu-data)
      log "keeping ubuntu-data mounted ($dev)"
      ;;
  esac
done

# Unmount all snaps except migration snap
for mp in $(awk '$2 ~ /^\/snap\// {print $2}' /proc/mounts); do
  case "$mp" in
    $SNAP_MNT) log "keeping migration snap mounted at $SNAP_MNT";;
    *) umount "$mp" || log "warning: failed to unmount $mp";;
  esac
done

sync
log "finished unmounting by PARTNAME; only ubuntu-data and migration snap remain"

# --- Step 4: flash whole block device with dd ---
step "flashing image to $DISK_DEV"
log "starting: dd if=$IMG_PATH of=$DISK_DEV bs=4M conv=fsync status=progress"
dd if="$IMG_PATH" of="$DISK_DEV" bs=4M conv=fsync status=progress || fail "dd failed"
sync
log "flashing complete"

# --- Step 5: reboot ---
step "rebooting"
reboot -f
