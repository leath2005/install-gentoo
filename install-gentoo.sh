#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  Gentoo Linux Installer
#  OpenRC · AMD Zen 5 · XFS · EFI Stub · CachyOS Kernel
#
#  Run from a Gentoo live USB as root:
#    chmod +x install-gentoo.sh && ./install-gentoo.sh
#
#  Two-phase design:
#    Phase 1 — partitioning, formatting, stage3 extraction (live USB)
#    Phase 2 — chroot configuration, kernel, bootloader, services
#
#  Safe to re-run: each step checks before acting.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
step()  { printf "\n${BOLD}${CYAN}═══ %s ═══${NC}\n" "$*"; }

die() { err "$*"; exit 1; }

# ── Auto-merge config updates ────────────────────────────────────────
auto_merge_configs() {
    if find /etc -name '._cfg0000_*' 2>/dev/null | grep -q .; then
        info "Config file updates detected — auto-merging..."
        etc-update --automode -3 2>/dev/null || true
        if find /etc -name '._cfg0000_*' 2>/dev/null | grep -q .; then
            etc-update --automode -5 2>/dev/null || true
        fi
        ok "Config files merged."
    fi
}

# ── Safe emerge wrapper ──────────────────────────────────────────────
safe_emerge() {
    local emerge_args=("$@")
    if ! emerge "${emerge_args[@]}"; then
        warn "Emerge failed — writing autounmask changes and retrying..."
        emerge --autounmask-write "${emerge_args[@]}" || true
        etc-update --automode -5 2>/dev/null || true
        dispatch-conf 2>/dev/null <<< 'u' || true
        emerge "${emerge_args[@]}"
    fi
    auto_merge_configs
}

# ══════════════════════════════════════════════════════════════════════
#  Detect which phase we're in
# ══════════════════════════════════════════════════════════════════════
if [[ "${INSTALL_PHASE:-}" == "chroot" ]]; then
    # ──────────────────────────────────────────────────────────────────
    #  PHASE 2 — Inside chroot
    # ──────────────────────────────────────────────────────────────────
    source /etc/profile
    export PS1="(chroot) ${PS1:-}"

    DISK="${INSTALL_DISK}"
    PART_PREFIX="${INSTALL_PART_PREFIX}"
    HOSTNAME="${INSTALL_HOSTNAME}"
    ROOT_PART="${PART_PREFIX}3"
    EFI_PART="${PART_PREFIX}1"
    SWAP_PART="${PART_PREFIX}2"

    # ── 2.1 Mount EFI ────────────────────────────────────────────────
    step "Phase 2.1: Mount EFI partition"
    mkdir -p /efi/EFI/Gentoo
    if ! mountpoint -q /efi; then
        mount "${EFI_PART}" /efi
    fi
    ok "EFI mounted at /efi"

    # ── 2.2 Sync Portage ─────────────────────────────────────────────
    step "Phase 2.2: Sync Portage tree"
    emerge-webrsync
    emerge --sync
    ok "Portage tree synced."

    # ── 2.3 CPU flags + VIDEO_CARDS ──────────────────────────────────
    step "Phase 2.3: CPU flags and VIDEO_CARDS"
    safe_emerge --oneshot app-portage/cpuid2cpuflags

    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
    ok "CPU flags written to /etc/portage/package.use/00cpu-flags"

    echo "*/* VIDEO_CARDS: -* amdgpu radeonsi" > /etc/portage/package.use/00video_cards
    ok "VIDEO_CARDS written to /etc/portage/package.use/00video_cards"

    # ── 2.4 Update @world ────────────────────────────────────────────
    step "Phase 2.4: Update @world"
    safe_emerge --verbose --update --deep --changed-use @world
    emerge --depclean || true
    ok "@world updated."

    # ── 2.5 Timezone + Locale ────────────────────────────────────────
    step "Phase 2.5: Timezone and locale"
    ln -sf ../usr/share/zoneinfo/America/Detroit /etc/localtime
    ok "Timezone set to America/Detroit"

    # Ensure en_US.UTF-8 is uncommented in locale.gen
    if [[ -f /etc/locale.gen ]]; then
        sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    else
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    fi
    locale-gen

    # Set locale via eselect
    LOCALE_NUM=$(eselect locale list | grep -n 'en_US.utf8' | head -1 | cut -d: -f1)
    if [[ -n "$LOCALE_NUM" ]]; then
        # eselect uses the index shown in brackets, extract it
        LOCALE_IDX=$(eselect locale list | grep 'en_US.utf8' | head -1 | grep -o '\[[0-9]*\]' | tr -d '[]')
        eselect locale set "$LOCALE_IDX"
        ok "Locale set to en_US.UTF-8"
    else
        warn "Could not auto-detect en_US.utf8 index — set manually with: eselect locale set <num>"
    fi

    env-update
    source /etc/profile
    export PS1="(chroot) ${PS1:-}"

    # ── 2.6 Firmware ─────────────────────────────────────────────────
    step "Phase 2.6: Linux firmware"
    safe_emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
    ok "Firmware installed."

    # ── 2.7 installkernel (dracut + efistub) ─────────────────────────
    step "Phase 2.7: installkernel with dracut + efistub"
    mkdir -p /etc/portage/package.use
    echo "sys-kernel/installkernel dracut efistub" > /etc/portage/package.use/installkernel
    safe_emerge sys-kernel/installkernel
    ok "installkernel configured."

    # Get root partition UUID for dracut
    ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
    if [[ -z "$ROOT_UUID" ]]; then
        die "Could not determine UUID for ${ROOT_PART}"
    fi
    ok "Root UUID: ${ROOT_UUID}"

    mkdir -p /etc/dracut.conf.d
    cat > /etc/dracut.conf.d/00-installkernel.conf << DRACUT_EOF
kernel_cmdline=" root=UUID=${ROOT_UUID} rw "
DRACUT_EOF
    ok "Dracut config written with root=UUID=${ROOT_UUID}"

    # ── 2.8 CachyOS Kernel ───────────────────────────────────────────
    step "Phase 2.8: CachyOS kernel"
    safe_emerge app-eselect/eselect-repository dev-vcs/git
    eselect repository enable CachyOS-kernels 2>/dev/null || ok "CachyOS-kernels repo already enabled"
    emaint sync -r CachyOS-kernels

    info "Installing CachyOS kernel..."
    safe_emerge --autounmask sys-kernel/cachyos-kernel
    emerge --depclean || true
    ok "CachyOS kernel installed."

    # ── 2.9 fstab ─────────────────────────────────────────────────────
    step "Phase 2.9: Generate fstab"

    EFI_PARTUUID=$(blkid -s PARTUUID -o value "${EFI_PART}")
    SWAP_PARTUUID=$(blkid -s PARTUUID -o value "${SWAP_PART}")
    ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${ROOT_PART}")

    cat > /etc/fstab << FSTAB_EOF
# <device>                                      <mount>     <type>  <options>                    <dump> <pass>
PARTUUID=${EFI_PARTUUID}   /efi        vfat    umask=0077,tz=UTC            0 2
PARTUUID=${SWAP_PARTUUID}   none        swap    sw                           0 0
PARTUUID=${ROOT_PARTUUID}   /           xfs     defaults,noatime             0 1
FSTAB_EOF
    ok "fstab written with PARTUUIDs."

    # ── 2.10 Hostname ────────────────────────────────────────────────
    step "Phase 2.10: Hostname"
    echo "${HOSTNAME}" > /etc/hostname
    echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname
    ok "Hostname set to '${HOSTNAME}'"

    # ── 2.11 Networking ──────────────────────────────────────────────
    step "Phase 2.11: Networking"
    safe_emerge net-misc/dhcpcd
    rc-update add dhcpcd default 2>/dev/null || true
    ok "dhcpcd installed and enabled."

    safe_emerge --noreplace net-misc/netifrc

    # Detect primary network interface (first non-lo)
    NET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    if [[ -z "$NET_IFACE" ]]; then
        warn "Could not detect network interface — defaulting to eth0"
        NET_IFACE="eth0"
    fi
    ok "Detected network interface: ${NET_IFACE}"

    echo "config_${NET_IFACE}=\"dhcp\"" > /etc/conf.d/net
    ok "DHCP configured for ${NET_IFACE}"

    if [[ ! -e "/etc/init.d/net.${NET_IFACE}" ]]; then
        cd /etc/init.d
        ln -sf net.lo "net.${NET_IFACE}"
        cd /
    fi
    rc-update add "net.${NET_IFACE}" default 2>/dev/null || true
    ok "net.${NET_IFACE} service enabled."

    safe_emerge net-wireless/iw net-wireless/wpa_supplicant
    ok "Wireless tools installed."

    # ── 2.12 Hosts file ──────────────────────────────────────────────
    step "Phase 2.12: Hosts file"
    cat > /etc/hosts << HOSTS_EOF
127.0.0.1     ${HOSTNAME}
127.0.0.1     localhost
::1           localhost
HOSTS_EOF
    ok "/etc/hosts written."

    # ── 2.13 Root password ───────────────────────────────────────────
    step "Phase 2.13: Set root password"
    info "Set the root password:"
    passwd

    # ── 2.14 System tools ────────────────────────────────────────────
    step "Phase 2.14: System tools"
    safe_emerge app-admin/sysklogd
    rc-update add sysklogd default 2>/dev/null || true

    safe_emerge sys-process/cronie
    rc-update add cronie default 2>/dev/null || true

    safe_emerge sys-apps/mlocate
    safe_emerge app-shells/bash-completion
    safe_emerge net-misc/chrony
    rc-update add chronyd default 2>/dev/null || true

    safe_emerge sys-block/io-scheduler-udev-rules
    ok "All system tools installed and services enabled."

    # ── Phase 2 complete ─────────────────────────────────────────────
    printf "\n${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}${GREEN}  Phase 2 (chroot) complete!${NC}\n"
    printf "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n\n"
    info "Phase 2 (chroot) complete — returning to live USB for cleanup."
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────
#  PHASE 1 — Outside chroot (live USB)
# ──────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root."
fi

step "Gentoo Linux Installer"
info "OpenRC · AMD Zen 5 · XFS · EFI Stub · CachyOS Kernel"
echo ""

# ── Select disk ──────────────────────────────────────────────────────
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -v '^loop'
echo ""
read -rp "Enter the disk to install Gentoo on (e.g. nvme0n1, sda): " DISK_NAME
DISK="/dev/${DISK_NAME}"

if [[ ! -b "$DISK" ]]; then
    die "'${DISK}' is not a valid block device."
fi

# Confirm
warn "ALL DATA on ${DISK} will be destroyed!"
read -rp "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || die "Aborted."

# ── Hostname ─────────────────────────────────────────────────────────
read -rp "Enter hostname [gentoo]: " HOSTNAME
HOSTNAME="${HOSTNAME:-gentoo}"

# ── Partition names ──────────────────────────────────────────────────
# Handle both nvme (p1) and sata (1) naming
if [[ "$DISK_NAME" == nvme* ]] || [[ "$DISK_NAME" == mmcblk* ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi
EFI_PART="${PART_PREFIX}1"
SWAP_PART="${PART_PREFIX}2"
ROOT_PART="${PART_PREFIX}3"

# ══════════════════════════════════════════════════════════════════════
#  1.1 — Partition disk
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.1: Partitioning ${DISK}"

info "Creating GPT partition table with sfdisk..."
sfdisk "${DISK}" << SFDISK_EOF
label: gpt

size=1G,   type=uefi
size=8G,   type=swap
           type=linux
SFDISK_EOF

partprobe "${DISK}" 2>/dev/null || sleep 2
ok "Partitions created: EFI=${EFI_PART}  Swap=${SWAP_PART}  Root=${ROOT_PART}"

# ══════════════════════════════════════════════════════════════════════
#  1.2 — Format partitions
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.2: Formatting partitions"

info "Formatting ${ROOT_PART} as XFS..."
mkfs.xfs -f -c options=/usr/share/xfsprogs/mkfs/lts_6.18.conf "${ROOT_PART}"
ok "Root: XFS"

info "Formatting ${EFI_PART} as FAT32..."
mkfs.vfat -F 32 "${EFI_PART}"
ok "EFI: FAT32"

info "Setting up swap on ${SWAP_PART}..."
mkswap "${SWAP_PART}"
swapon "${SWAP_PART}"
ok "Swap: active"

# ══════════════════════════════════════════════════════════════════════
#  1.3 — Mount and download stage3
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.3: Mount root and download stage3"

mkdir -p /mnt/gentoo
if ! mountpoint -q /mnt/gentoo; then
    mount "${ROOT_PART}" /mnt/gentoo
fi
ok "Root mounted at /mnt/gentoo"

cd /mnt/gentoo

# Sync clock
chronyd -q 2>/dev/null || info "chronyd not available — ensure clock is correct"

# Fetch latest stage3 URL automatically
info "Fetching latest stage3 URL..."
STAGE3_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
STAGE3_PATH=$(wget -qO- "${STAGE3_BASE}/latest-stage3-amd64-desktop-openrc.txt" \
    | grep -v '^#' | grep '.tar.xz' | awk '{print $1}')

if [[ -z "$STAGE3_PATH" ]]; then
    die "Could not determine latest stage3 URL. Check your network."
fi

STAGE3_URL="${STAGE3_BASE}/${STAGE3_PATH}"
STAGE3_FILE=$(basename "$STAGE3_PATH")

if [[ -f "/mnt/gentoo/${STAGE3_FILE}" ]]; then
    ok "Stage3 already downloaded: ${STAGE3_FILE}"
else
    info "Downloading: ${STAGE3_URL}"
    wget "${STAGE3_URL}"
    ok "Stage3 downloaded."
fi

# ══════════════════════════════════════════════════════════════════════
#  1.4 — Extract stage3
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.4: Extracting stage3"

if [[ -d /mnt/gentoo/usr/portage ]] || [[ -d /mnt/gentoo/var/db/pkg ]]; then
    ok "Stage3 already extracted — skipping."
else
    tar xpvf "${STAGE3_FILE}" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
    ok "Stage3 extracted."
fi

# ══════════════════════════════════════════════════════════════════════
#  1.5 — Write make.conf
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.5: Writing make.conf"

cat > /mnt/gentoo/etc/portage/make.conf << 'MAKECONF_EOF'
COMMON_FLAGS="-march=znver5 -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
RUSTFLAGS="${RUSTFLAGS} -C target-cpu=znver5"

MAKEOPTS="-j17 -l16"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"
MAKECONF_EOF

ok "make.conf written (Zen 5 / znver5)."

# ══════════════════════════════════════════════════════════════════════
#  1.6 — Prepare chroot
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.6: Preparing chroot environment"

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
ok "DNS config copied."

# Mount pseudo-filesystems (skip if already mounted)
mountpoint -q /mnt/gentoo/proc || mount --types proc /proc /mnt/gentoo/proc
mountpoint -q /mnt/gentoo/sys  || { mount --rbind /sys /mnt/gentoo/sys && mount --make-rslave /mnt/gentoo/sys; }
mountpoint -q /mnt/gentoo/dev  || { mount --rbind /dev /mnt/gentoo/dev && mount --make-rslave /mnt/gentoo/dev; }
mountpoint -q /mnt/gentoo/run  || { mount --bind /run /mnt/gentoo/run && mount --make-slave /mnt/gentoo/run; }
ok "Pseudo-filesystems mounted."

# Copy this script into the chroot
cp "$0" /mnt/gentoo/tmp/install-gentoo.sh
chmod +x /mnt/gentoo/tmp/install-gentoo.sh

# ══════════════════════════════════════════════════════════════════════
#  1.7 — Enter chroot (Phase 2)
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.7: Entering chroot — Phase 2 begins"

INSTALL_PHASE=chroot INSTALL_DISK="${DISK}" INSTALL_PART_PREFIX="${PART_PREFIX}" INSTALL_HOSTNAME="${HOSTNAME}" \
    chroot /mnt/gentoo /bin/bash /tmp/install-gentoo.sh

# ══════════════════════════════════════════════════════════════════════
#  1.8 — Cleanup and reboot
# ══════════════════════════════════════════════════════════════════════
step "Phase 1.8: Cleanup"

cd /
info "Unmounting filesystems..."
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true
ok "Filesystems unmounted."

printf "\n${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}${GREEN}  Gentoo installation complete!${NC}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n\n"

read -rp "Reboot now? [Y/n]: " reply
[[ "$reply" =~ ^[Nn]$ ]] || reboot
