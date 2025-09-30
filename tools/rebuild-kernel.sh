#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--reset" ]]; then
    echo "[*] Resetting build artifacts..."
    rm -f modkernel/initrd-work/{main.cpio.gz,new-initrd.img,new-kernel.efi}
    rm -f modkernel/test_kernel_*.snap
    rm -f .kernel_snap_counter
    echo "[+] Artifacts cleared."
    exit 0
fi

OUTDIR=${1:-modkernel}

MAIN_DIR="$OUTDIR/initrd-work/unpacked/main"
EARLY_CPIO="$OUTDIR/initrd-work/early.cpio"
NEW_INITRD="$OUTDIR/initrd-work/new-initrd.img"
VMLINUZ="$OUTDIR/initrd-work/vmlinuz"
NEW_KERNEL="$OUTDIR/initrd-work/new-kernel.efi"

# --- Step 1: Recompress main ---
echo "[*] Recompressing modified main/ into main.cpio.gz..."
( cd "$MAIN_DIR" && find . | cpio -H newc -o | gzip -n ) > "$OUTDIR/initrd-work/main.cpio.gz"

# --- Step 2: Combine early + main ---
echo "[*] Concatenating early.cpio + main.cpio.gz into new initrd..."
if [ -f "$EARLY_CPIO" ]; then
    cat "$EARLY_CPIO" "$OUTDIR/initrd-work/main.cpio.gz" > "$NEW_INITRD"
else
    echo "[!] No early.cpio found, using only main.cpio.gz"
    cp "$OUTDIR/initrd-work/main.cpio.gz" "$NEW_INITRD"
fi

# --- Step 3: Build new kernel.efi ---
echo "[*] Building new kernel.efi..."
ukify build \
  --linux "$VMLINUZ" \
  --initrd "$NEW_INITRD" \
  --output "$NEW_KERNEL"

# --- Step 4: Replace kernel.efi in squashfs ---
echo "[*] Replacing kernel.efi inside squashfs-root..."
cp "$NEW_KERNEL" "$OUTDIR/squashfs-root/kernel.efi"

# --- Step 5: Pack snap with auto-incremented name ---
if [ ! -f .kernel_snap_counter ]; then
    echo 1 > .kernel_snap_counter
fi
COUNT=$(cat .kernel_snap_counter)
NEXT_COUNT=$((COUNT + 1))
echo "$NEXT_COUNT" > .kernel_snap_counter

SNAP_NAME="test_kernel_${COUNT}.snap"
echo "[*] Packing new kernel snap as $SNAP_NAME..."
snap pack "$OUTDIR/squashfs-root" --filename="$SNAP_NAME"

echo "[+] Done! Built $SNAP_NAME"
