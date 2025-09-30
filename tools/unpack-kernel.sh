#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--reset" ]]; then
    echo "[*] Resetting workspace..."
    rm -rf modkernel
    echo "[+] Workspace cleared."
    exit 0
fi

KERNEL_SNAP=${1:? "Usage: $0 <pc-kernel.snap> [OUTDIR] | --reset"}
OUTDIR=${2:-modkernel}

echo "[*] Preparing workspace at $OUTDIR..."
mkdir -p "$OUTDIR"

# 1. Unsquash the kernel snap
echo "[*] Unsquashing kernel snap..."
unsquashfs -d "$OUTDIR/squashfs-root" "$KERNEL_SNAP"

# 2. Extract initrd + vmlinuz from kernel.efi
cd "$OUTDIR"
mkdir -p initrd-work
echo "[*] Extracting initrd and vmlinuz from kernel.efi..."
ukify extract squashfs-root/kernel.efi --dir=initrd-work

# 3. Unpack initrd
echo "[*] Running unmkinitramfs..."
unmkinitramfs initrd-work/initrd initrd-work/unpacked

# 4. Preserve early.cpio
echo "[*] Saving early.cpio..."
cp initrd-work/unpacked/early.cpio initrd-work/

echo "[+] Unpack complete."
echo "    - Squashfs: $OUTDIR/squashfs-root/"
echo "    - Initramfs workdir: $OUTDIR/initrd-work/"
