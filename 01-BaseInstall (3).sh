#!/bin/bash
set -euo pipefail

# ============================================================
#  01-BaseInstall.sh
#  Partitions the selected drive, formats, mounts, downloads
#  the stage3 tarball, and sets up the chroot environment.
# ============================================================

# --- Privilege check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or via sudo)." >&2
    exit 1
fi

# --- Drive selection ---
echo ""
echo "Available block devices:"
lsblk -d -o NAME,SIZE,MODEL
echo ""
read -rp "Enter the drive to install Gentoo on (e.g. nvme0n1 or sda): " DRIVE

if [[ -z "$DRIVE" ]]; then
    echo "ERROR: No drive entered. Aborting." >&2
    exit 1
fi

if [[ ! -b "/dev/$DRIVE" ]]; then
    echo "ERROR: /dev/$DRIVE is not a valid block device. Aborting." >&2
    exit 1
fi

echo ""
echo "WARNING: This will DESTROY all data on /dev/$DRIVE"
read -rp "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted." >&2
    exit 1
fi

# Determine partition suffix (nvme/mmc devices use 'p' prefix for partitions)
if [[ "$DRIVE" == nvme* || "$DRIVE" == mmcblk* ]]; then
    PART="${DRIVE}p"
else
    PART="${DRIVE}"
fi

# ---- Partition the drive ----
echo ""
echo ">>> Partitioning /dev/$DRIVE ..."

fdisk /dev/$DRIVE <<EOF
g
n
1

+1G
t
1
1
n
2

+8G
t
2
19
n
3


t
3
23
w
EOF

# Give the kernel a moment to register the new partition table
sleep 2
partprobe /dev/$DRIVE

# ---- Format partitions ----
echo ""
echo ">>> Formatting partitions ..."

mkfs.xfs -f -c options=/usr/share/xfsprogs/mkfs/lts_6.18.conf /dev/${PART}3
mkfs.vfat -F 32 /dev/${PART}1
mkswap /dev/${PART}2
swapon /dev/${PART}2

# ---- Mount root ----
echo ""
echo ">>> Mounting root filesystem ..."

mkdir --parents /mnt/gentoo
mount /dev/${PART}3 /mnt/gentoo
cd /mnt/gentoo

# ---- Sync clock ----
echo ""
echo ">>> Syncing system clock ..."
chronyd -q

# ---- Download stage3 ----
echo ""
echo ">>> Downloading stage3 tarball ..."
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/20260412T164603Z/stage3-amd64-desktop-openrc-20260412T164603Z.tar.xz

echo ""
echo ">>> Extracting stage3 tarball ..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# ---- Write make.conf ----
echo ""
echo ">>> Writing /mnt/gentoo/etc/portage/make.conf ..."

cat > /mnt/gentoo/etc/portage/make.conf <<'MAKECONF'
COMMON_FLAGS="-march=znver5 -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
RUSTFLAGS="${RUSTFLAGS} -C target-cpu=znver5"

MAKEOPTS="-j16 -l17"
USE="${USE} networkmanager -systemd"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"
MAKECONF

# ---- Copy resolv.conf and bind-mount pseudo-filesystems ----
echo ""
echo ">>> Copying resolv.conf and bind-mounting filesystems ..."

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# ---- Chroot setup and portage sync ----
echo ""
echo ">>> Entering chroot and running initial portage sync ..."

# Write a helper script that will run inside the chroot
cat > /mnt/gentoo/tmp/chroot-stage1.sh <<CHROOTSCRIPT
#!/bin/bash
set -eo pipefail

set +u
source /etc/profile
set -u

mkdir --parents /efi/EFI/Gentoo
mount /dev/${PART}1 /efi

emerge-webrsync
emerge --sync

emerge --oneshot app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
echo "*/* VIDEO_CARDS: -* amdgpu radeonsi" > /etc/portage/package.use/00video_cards

emerge --verbose --update --deep --changed-use @world
emerge --depclean

ln -sf ../usr/share/zoneinfo/America/Detroit /etc/localtime
CHROOTSCRIPT

chmod +x /mnt/gentoo/tmp/chroot-stage1.sh
chroot /mnt/gentoo /bin/bash /tmp/chroot-stage1.sh
rm /mnt/gentoo/tmp/chroot-stage1.sh

# ---- Done ----
echo ""
echo "============================================================"
echo " 01-BaseInstall has completed successfully."
echo " Proceed to set up the locale configuration by editing:"
echo "   /mnt/gentoo/etc/locale.gen"
echo " manually, then run 02-ConfigurationPart1.sh from the host via chroot."
echo "============================================================"
