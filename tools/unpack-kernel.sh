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

# 2. Extract vmlinuz + initrd directly from kernel.efi
cd "$OUTDIR"
mkdir -p initrd-work
echo "[*] Extracting vmlinuz and initrd from kernel.efi..."
objcopy -O binary -j.linux squashfs-root/kernel.efi initrd-work/vmlinuz
objcopy -O binary -j.initrd squashfs-root/kernel.efi initrd-work/initrd

# 3. Unpack initrd
echo "[*] Running unmkinitramfs..."
unmkinitramfs initrd-work/initrd initrd-work/unpacked

# 4. Preserve or create early.cpio
if [ -f initrd-work/unpacked/early.cpio ]; then
    cp initrd-work/unpacked/early.cpio initrd-work/
    echo "[*] Saved early.cpio"
else
    echo "[!] early.cpio not found, creating empty placeholder"
    (
      cd initrd-work
      echo | cpio -o -H newc > early.cpio 2>/dev/null
    )
    echo "[*] Created empty early.cpio"
fi

echo "[+] Unpack complete."
echo "    - Squashfs: $OUTDIR/squashfs-root/"
echo "    - Initramfs workdir: $OUTDIR/initrd-work/"
