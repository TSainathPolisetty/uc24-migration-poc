#!/bin/bash
set -euo pipefail

OUTDIR=${1:-modkernel}

MAIN_DIR="$OUTDIR/initrd-work/unpacked/main"
EARLY_CPIO="$OUTDIR/initrd-work/early.cpio"
NEW_INITRD="$OUTDIR/initrd-work/new-initrd.img"
VMLINUZ="$OUTDIR/initrd-work/vmlinuz"
NEW_KERNEL="$OUTDIR/initrd-work/new-kernel.efi"

echo "[*] Recompressing modified main/ into main.cpio.gz..."
( cd "$MAIN_DIR" && find . | cpio -H newc -o | gzip -n ) > "$OUTDIR/initrd-work/main.cpio.gz"

echo "[*] Concatenating early.cpio + main.cpio.gz into new initrd..."
cat "$EARLY_CPIO" "$OUTDIR/initrd-work/main.cpio.gz" > "$NEW_INITRD"

echo "[*] Building new kernel.efi..."
ukify build \
  --linux "$VMLINUZ" \
  --initrd "$NEW_INITRD" \
  --output "$NEW_KERNEL"

echo "[*] Replacing kernel.efi inside squashfs-root..."
cp "$NEW_KERNEL" "$OUTDIR/squashfs-root/kernel.efi"

echo "[*] Packing new kernel snap..."
snap pack "$OUTDIR/squashfs-root"

echo "[+] Done! New pc-kernel snap is in $OUTDIR/"
