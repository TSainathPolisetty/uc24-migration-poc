# UC24 Migration PoC – Instructions

This repository demonstrates a migration proof-of-concept (PoC) using a **migration snap**, **initramfs modifications**, and **kernel manipulation tools**.

---

## 1.Migration Snap

### Location
```

migration-snap/
├── payloads/uc24.img.xz
└── snap/
├── hooks/install
├── migration.conf
└── snapcraft.yaml

````

### Build
```bash
cd migration-snap
mkdir payloads && cd payloads
wget http://cdimage.ubuntu.com/ubuntu-core/24/stable/current/ubuntu-core-24-amd64.img.xz
unxz ubuntu-core-24-amd64.img.xz
cd ../
snapcraft
PORT=<PORT>
SOURCE="./cascade-migration_0.1_amd64.snap"
USER="<USERNAME>"
HOST="localhost"
DEST="/home/<USERNAME>"
scp -P "$PORT" "$SOURCE" "$USER@$HOST:$DEST"
````

### Install inside QEMU (Running the image with modified seed partition)

```bash
snap install --dangerous cascade-migration_0.1_amd64.snap
```

During installation:

* Static config (`migration.conf`) is copied into `$SNAP_DATA/migration.conf`.

---

## 2.Initramfs

### Location

```
initramfs/
├── migrate.sh
├── migrate.service
└── README.md
```

### Purpose

* `migrate.sh` → migration logic executed at boot.
* `migrate.service` → systemd unit to run the script during early initramfs stage.

### Usage

After unpacking a kernel snap (see **Tools**), copy these into the unpacked initramfs:

```bash
cp initramfs/migrate.sh modkernel/initrd-work/unpacked/main/bin/
cp initramfs/migrate.service modkernel/initrd-work/unpacked/main/etc/systemd/system/
chmod +x modkernel/initrd-work/unpacked/main/bin/migrate.sh
ln -s /etc/systemd/system/migrate.service \
      modkernel/initrd-work/unpacked/main/etc/systemd/system/sysinit.target.wants/migrate.service

```

These will then be included when the kernel snap is rebuilt.

---

## 3.Tools

### Location

```
tools/
├── unpack-kernel.sh
└── rebuild-kernel.sh
```

### Prerequisites

```bash
sudo apt update
sudo apt install -y squashfs-tools initramfs-tools-core systemd-ukify \
    snapd xz-utils cpio binutils
```

### Workflow

#### 1. Unpack kernel snap

Download the relevant kernel snap:

```bash
    snap download pc-kernel --channel=24/stable
```


```bash
./tools/unpack-kernel.sh pc-kernel_<version>.snap
```

This creates a working directory:

```
modkernel/
 ├── squashfs-root/       # unpacked snap contents
 └── initrd-work/         # initramfs workspace
      ├── vmlinuz
      ├── initrd
      ├── early.cpio
      └── unpacked/main/
```

#### 2. Modify initramfs

Add scripts/services (see **Initramfs** section) into:

```
modkernel/initrd-work/unpacked/main/
```

#### 3. Rebuild kernel snap

```bash
./tools/rebuild-kernel.sh modkernel
```

This produces:

```
test_kernel_1.snap
```

Subsequent runs increment the number (`test_kernel_2.snap`, `test_kernel_3.snap`, …).

#### 4. Reset

To clear artifacts and restart numbering:

```bash
./tools/unpack-kernel.sh --reset
./tools/rebuild-kernel.sh --reset
```

```
```
