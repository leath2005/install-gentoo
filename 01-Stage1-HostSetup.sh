#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

if shopt -qo posix; then
    exec /bin/bash "$0" "$@"
fi

set -euo pipefail

# ============================================================
#  01-Stage1-HostSetup.sh
#  Partitions the selected drive, formats, mounts, downloads
#  the stage3 tarball, and sets up the chroot environment.
# ============================================================

# --- Privilege check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or via sudo)." >&2
    exit 1
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_SOURCE" != */* ]]; then
    if SCRIPT_PATH=$(command -v -- "$SCRIPT_SOURCE" 2>/dev/null); then
        SCRIPT_SOURCE="$SCRIPT_PATH"
    else
        SCRIPT_SOURCE="${PWD}/${SCRIPT_SOURCE}"
    fi
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)
STAGE2_SCRIPT_SOURCE="${SCRIPT_DIR}/02-Stage2-ChrootSetup.sh"

if [[ ! -f "$STAGE2_SCRIPT_SOURCE" ]]; then
    echo "ERROR: Could not find 02-Stage2-ChrootSetup.sh next to this script." >&2
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

echo ""
read -rp "Enable SPEED-RUN install for quick testing? (skips @world rebuild and uses binary kernel in stage2) [y/N]: " SPEED_RUN_CONFIRM
if [[ "$SPEED_RUN_CONFIRM" =~ ^[Yy]$ ]]; then
    INSTALL_MODE="speed"
else
    INSTALL_MODE="full"
fi
echo ">>> Selected install mode: $INSTALL_MODE"
if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo "    Mode behavior: quick test install, keep stage3 defaults, skip @world rebuild in stage1."
    echo "    Stage2 kernel path: Gentoo binary kernel (gentoo-kernel-bin)."
else
    echo "    Mode behavior: full install with tuned make.conf and stage1 @world rebuild."
    echo "    Stage2 kernel path: CachyOS kernel from overlay."
fi

SYSTEM_LANG="en_US.UTF-8"
echo ">>> Selected system locale: $SYSTEM_LANG"

# Determine partition suffix (nvme/mmc devices use 'p' prefix for partitions)
if [[ "$DRIVE" == nvme* || "$DRIVE" == mmcblk* ]]; then
    PART="${DRIVE}p"
else
    PART="${DRIVE}"
fi

# ---- Partition the drive ----
echo ""
echo ">>> Partitioning /dev/$DRIVE ..."

sgdisk --zap-all /dev/$DRIVE
sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:"EFI"  /dev/$DRIVE
sgdisk -n 2:0:+8G   -t 2:8200 -c 2:"swap" /dev/$DRIVE
sgdisk -n 3:0:0     -t 3:8304 -c 3:"root" /dev/$DRIVE

# Give the kernel a moment to register the new partition table
sleep 2
partprobe /dev/$DRIVE

# ---- Format partitions ----
echo ""
echo ">>> Formatting partitions ..."

# Use distro-specific mkfs profile when available, otherwise fall back to defaults.
if [[ -f /usr/share/xfsprogs/mkfs/lts_6.18.conf ]]; then
    mkfs.xfs -f -c options=/usr/share/xfsprogs/mkfs/lts_6.18.conf /dev/${PART}3
else
    mkfs.xfs -f /dev/${PART}3
fi
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

STAGE3_BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"
if [[ "$INSTALL_MODE" == "speed" ]]; then
    STAGE3_LATEST_FILE="${STAGE3_BASE_URL}/latest-stage3-amd64-openrc.txt"
    STAGE3_PATTERN='stage3-amd64-openrc-.*\.tar\.xz'
    STAGE3_PROFILE_LABEL="minimal openrc"
else
    STAGE3_LATEST_FILE="${STAGE3_BASE_URL}/latest-stage3-amd64-desktop-openrc.txt"
    STAGE3_PATTERN='stage3-amd64-desktop-openrc-.*\.tar\.xz'
    STAGE3_PROFILE_LABEL="desktop openrc"
fi

STAGE3_PATH=$(wget -qO- "$STAGE3_LATEST_FILE" | awk -v pattern="$STAGE3_PATTERN" '!/^#/ && $1 ~ pattern {print $1; exit}')
if [[ -z "$STAGE3_PATH" ]]; then
    echo "ERROR: Could not determine latest stage3 path from $STAGE3_LATEST_FILE" >&2
    exit 1
fi

STAGE3_TARBALL=$(basename "$STAGE3_PATH")
STAGE3_URL="${STAGE3_BASE_URL}/${STAGE3_PATH}"
STAGE3_DIGESTS_URL="${STAGE3_URL}.DIGESTS"
STAGE3_DIGESTS_FILE="${STAGE3_TARBALL}.DIGESTS"

echo "    Stage3 profile : $STAGE3_PROFILE_LABEL"
echo "    Resolved stage3: $STAGE3_TARBALL"
wget "$STAGE3_URL"
wget -O "$STAGE3_DIGESTS_FILE" "$STAGE3_DIGESTS_URL"

echo ""
echo ">>> Verifying stage3 checksum ..."
EXPECTED_DIGEST_INFO=$(awk -v file="$STAGE3_TARBALL" '
/BLAKE2B/ { algo="BLAKE2B"; next }
/SHA512/  { algo="SHA512"; next }
/SHA256/  { algo="SHA256"; next }
NF >= 2 {
    candidate = $NF
    gsub(/^\*/, "", candidate)
    if (candidate != file) {
        next
    }

    hash = tolower($1)
    if (algo == "BLAKE2B" && hash ~ /^[A-Fa-f0-9]{128}$/) {
        blake2b = hash
    } else if (algo == "SHA512" && hash ~ /^[A-Fa-f0-9]{128}$/) {
        sha512 = hash
    } else if (algo == "SHA256" && hash ~ /^[A-Fa-f0-9]{64}$/) {
        sha256 = hash
    }
}
END {
    if (blake2b != "") {
        print "BLAKE2B " blake2b
        exit
    }
    if (sha512 != "") {
        print "SHA512 " sha512
        exit
    }
    if (sha256 != "") {
        print "SHA256 " sha256
        exit
    }
}
' "$STAGE3_DIGESTS_FILE")

if [[ -z "$EXPECTED_DIGEST_INFO" ]]; then
    echo "ERROR: Could not find a supported checksum for $STAGE3_TARBALL in $STAGE3_DIGESTS_FILE" >&2
    echo "       Expected one of: BLAKE2B, SHA512, or SHA256." >&2
    echo "       Refusing to extract an unverified stage3 tarball." >&2
    exit 1
fi

read -r CHECKSUM_ALGO EXPECTED_CHECKSUM <<< "$EXPECTED_DIGEST_INFO"
case "$CHECKSUM_ALGO" in
    BLAKE2B)
        if ! command -v b2sum >/dev/null 2>&1; then
            echo "ERROR: b2sum is required to verify BLAKE2B digests." >&2
            exit 1
        fi
        ACTUAL_CHECKSUM=$(b2sum "$STAGE3_TARBALL" | awk '{print tolower($1)}')
        ;;
    SHA512)
        ACTUAL_CHECKSUM=$(sha512sum "$STAGE3_TARBALL" | awk '{print tolower($1)}')
        ;;
    SHA256)
        ACTUAL_CHECKSUM=$(sha256sum "$STAGE3_TARBALL" | awk '{print tolower($1)}')
        ;;
    *)
        echo "ERROR: Unsupported checksum algorithm selected: $CHECKSUM_ALGO" >&2
        exit 1
        ;;
esac

if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
    echo "ERROR: stage3 checksum mismatch." >&2
    echo "       Algorithm: $CHECKSUM_ALGO" >&2
    echo "       Expected : $EXPECTED_CHECKSUM" >&2
    echo "       Actual   : $ACTUAL_CHECKSUM" >&2
    exit 1
fi

echo "    Checksum verified ($CHECKSUM_ALGO)."

echo ""
echo ">>> Extracting stage3 tarball ..."
tar xpvf "$STAGE3_TARBALL" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# ---- Write make.conf ----
echo ""
if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo ">>> SPEED-RUN: keeping stage3 make.conf defaults ..."
else
    echo ">>> Writing /mnt/gentoo/etc/portage/make.conf for full install ..."

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
fi

echo "$INSTALL_MODE" > /mnt/gentoo/etc/install-mode

echo ""
echo ">>> Staging 02-Stage2-ChrootSetup.sh in /mnt/gentoo/tmp ..."
install -m 0755 "$STAGE2_SCRIPT_SOURCE" /mnt/gentoo/tmp/02-Stage2-ChrootSetup.sh

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

INSTALL_MODE="${INSTALL_MODE}"
echo ">>> chroot-stage1 running in mode: \\$INSTALL_MODE"

set +u
source /etc/profile
set -u

mkdir --parents /efi
mountpoint -q /efi || mount /dev/${PART}1 /efi
mkdir --parents /efi/EFI/Gentoo

emerge-webrsync
emerge --sync

emerge --oneshot app-portage/cpuid2cpuflags
mkdir --parents /etc/portage/package.use
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
echo "*/* VIDEO_CARDS: -* amdgpu radeonsi" > /etc/portage/package.use/00video_cards

if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo ">>> SPEED-RUN: skipping @world rebuild and depclean."
else
    emerge --verbose --update --deep --changed-use @world
    emerge --depclean
fi

ln -sf ../usr/share/zoneinfo/America/Detroit /etc/localtime
CHROOTSCRIPT

chmod +x /mnt/gentoo/tmp/chroot-stage1.sh
chroot /mnt/gentoo /bin/bash /tmp/chroot-stage1.sh
rm /mnt/gentoo/tmp/chroot-stage1.sh

# ---- Done ----
echo ""
echo "============================================================"
echo " 01-Stage1-HostSetup has completed successfully."
echo " Install mode: $INSTALL_MODE"
echo " Locale will be configured automatically during stage2:"
echo "   LANG=$SYSTEM_LANG"
echo " Stage2 script staged at:"
echo "   /mnt/gentoo/tmp/02-Stage2-ChrootSetup.sh"
echo " Then run from the host:"
echo "   chroot /mnt/gentoo /bin/bash /tmp/02-Stage2-ChrootSetup.sh && /mnt/gentoo/tmp/gentoo-cleanup.sh"
echo "============================================================"
