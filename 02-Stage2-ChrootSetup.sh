#!/bin/bash
set -euo pipefail

# ============================================================
#  02-Stage2-ChrootSetup.sh
#  Invoke from the HOST via:
#    chroot /mnt/gentoo /bin/bash /tmp/02-Stage2-ChrootSetup.sh && /mnt/gentoo/tmp/gentoo-cleanup.sh
#
#  Unified chroot phase (old Part1 + Part2):
#  - Firmware + installkernel/dracut setup
#  - CachyOS overlay and kernel install (autounmask-assisted)
#  - fstab, hostname, networking, services, users
#  - Writes cleanup script at /tmp/gentoo-cleanup.sh inside chroot
#    (host path: /mnt/gentoo/tmp/gentoo-cleanup.sh)
# ============================================================

# --- Privilege check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root inside the chroot." >&2
    exit 1
fi

# --- Sanity check: are we actually inside a chroot? ---
if [[ ! -f /etc/gentoo-release ]]; then
    echo "ERROR: /etc/gentoo-release not found. Are you running this inside the Gentoo chroot?" >&2
    exit 1
fi

# --- Helpers ---
auto_merge_configs() {
    if ! command -v etc-update >/dev/null 2>&1; then
        return
    fi

    if find /etc -name '._cfg*' 2>/dev/null | grep -q .; then
        echo "    Merging pending config updates ..."
        etc-update --automode -5 >/dev/null 2>&1 || true
    fi
}

safe_emerge() {
    if emerge "$@"; then
        auto_merge_configs
        return 0
    fi

    echo "    emerge failed; attempting autounmask workflow ..."
    emerge --autounmask-write "$@" || true

    auto_merge_configs

    if command -v dispatch-conf >/dev/null 2>&1; then
        dispatch-conf >/dev/null 2>&1 <<< 'u' || true
    fi

    emerge "$@"
    auto_merge_configs
}

# ---- Re-source profile ----
set +u
export DEBUGINFOD_URLS=""
env-update && source /etc/profile
set -u
export PS1="(chroot) \${PS1}"

INSTALL_MODE="full"
if [[ -f /etc/install-mode ]]; then
    INSTALL_MODE=$(tr -d '[:space:]' < /etc/install-mode)
fi
if [[ "$INSTALL_MODE" != "speed" ]]; then
    INSTALL_MODE="full"
fi
echo ">>> Install mode: $INSTALL_MODE"
if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo "    Profile: quick testing path (binary kernel, minimal compile time)."
else
    echo "    Profile: full path (Cachy overlay kernel, tuned performance setup)."
fi

# ---- Locale ----
echo ""
echo ">>> Finalizing locale configuration ..."
SYSTEM_LANG="en_US.UTF-8"

cat > /etc/locale.gen <<LOCALEGEN
${SYSTEM_LANG} UTF-8
LOCALEGEN

locale-gen

cat > /etc/env.d/02locale <<LOCALE
LANG="${SYSTEM_LANG}"
LOCALE

set +u
env-update && source /etc/profile
set -u
echo "    Wrote /etc/locale.gen for ${SYSTEM_LANG}."
echo "    Selected LANG=${SYSTEM_LANG}"

# ---- Firmware ----
echo ""
echo ">>> Installing linux-firmware and sof-firmware ..."
safe_emerge sys-kernel/linux-firmware
safe_emerge sys-firmware/sof-firmware

# ---- Kernel tooling ----
echo ""
echo ">>> Configuring and installing sys-kernel/installkernel with dracut + efistub ..."
mkdir --parents /etc/portage/package.use
echo "sys-kernel/installkernel dracut efistub" > /etc/portage/package.use/installkernel
safe_emerge sys-kernel/installkernel

# ---- Detect root and EFI partition devices ----
echo ""
echo ">>> Detecting root and EFI partition devices ..."
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ -z "$ROOT_DEV" ]]; then
    echo "ERROR: Could not determine root device via findmnt." >&2
    exit 1
fi

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
if [[ -z "$ROOT_UUID" ]]; then
    echo "ERROR: Could not retrieve UUID for $ROOT_DEV." >&2
    exit 1
fi

ROOT_PARENT=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -n 1)
if [[ -z "$ROOT_PARENT" ]]; then
    echo "ERROR: Could not determine parent disk for $ROOT_DEV." >&2
    exit 1
fi

EFI_DEV=$(lsblk -rno PATH,PKNAME,PARTLABEL | awk -v root_parent="$ROOT_PARENT" '$2 == root_parent && $3 == "EFI" {print $1; exit}')
if [[ -z "$EFI_DEV" ]]; then
    echo "ERROR: Could not determine EFI partition on /dev/$ROOT_PARENT." >&2
    exit 1
fi

echo "    Root device : $ROOT_DEV"
echo "    Root UUID   : $ROOT_UUID"
echo "    EFI device  : $EFI_DEV"

# ---- Mount EFI partition and prepare bootloader directory ----
echo ""
echo ">>> Mounting EFI partition at /efi and preparing /efi/EFI/Gentoo ..."
mkdir --parents /efi
if mountpoint -q /efi; then
    EFI_MOUNT_SOURCE=$(findmnt -n -o SOURCE /efi)
    if [[ "$EFI_MOUNT_SOURCE" == /dev/* && "$EFI_MOUNT_SOURCE" != "$EFI_DEV" ]]; then
        echo "ERROR: /efi is already mounted from $EFI_MOUNT_SOURCE, expected $EFI_DEV." >&2
        exit 1
    fi
    echo "    /efi already mounted from $EFI_MOUNT_SOURCE."
else
    mount "$EFI_DEV" /efi
    echo "    Mounted $EFI_DEV at /efi."
fi
mkdir --parents /efi/EFI/Gentoo
echo "    /efi/EFI/Gentoo ready for kernel installation."

# ---- Write dracut kernel cmdline config ----
echo ""
echo ">>> Writing /etc/dracut.conf.d/00-installkernel.conf ..."
mkdir --parents /etc/dracut.conf.d
cat > /etc/dracut.conf.d/00-installkernel.conf <<DRACUT
kernel_cmdline=" root=UUID=${ROOT_UUID} rw "
efi_dir="/efi/EFI/Gentoo"
DRACUT

echo "    Written: kernel_cmdline=\" root=UUID=${ROOT_UUID} rw \""
echo "    Written: efi_dir=\"/efi/EFI/Gentoo\""

# ---- Kernel install ----
echo ""
if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo ">>> SPEED-RUN: Installing Gentoo binary kernel ..."
    safe_emerge sys-kernel/gentoo-kernel-bin
    KERNEL_TRACK="sys-kernel/gentoo-kernel-bin"
else
    echo ">>> Installing eselect-repository, git, sudo, vim, and neofetch; enabling CachyOS-kernels overlay ..."
    safe_emerge app-eselect/eselect-repository dev-vcs/git app-admin/sudo app-editors/vim app-misc/neofetch
    eselect repository enable CachyOS-kernels >/dev/null 2>&1 || true
    emaint sync -r CachyOS-kernels

    mkdir --parents /etc/portage/package.accept_keywords
    cat > /etc/portage/package.accept_keywords/cachyos-kernel <<'KEYWORDS'
sys-kernel/cachyos-kernel::CachyOS-kernels ~amd64
KEYWORDS

    echo ">>> Installing CachyOS kernel (auto-handles autounmask where possible) ..."
    safe_emerge --autounmask sys-kernel/cachyos-kernel
    KERNEL_TRACK="sys-kernel/cachyos-kernel::CachyOS-kernels"
fi

echo "    Kernel path selected: $KERNEL_TRACK"

# ---- Depclean ----
echo ""
if [[ "$INSTALL_MODE" == "speed" ]]; then
    echo ">>> SPEED-RUN: skipping emerge --depclean ..."
else
    echo ">>> Running emerge --depclean ..."
    emerge --depclean || true
fi

# ---- Write /etc/fstab ----
echo ""
echo ">>> Generating /etc/fstab with genfstab from active mounts ..."
safe_emerge sys-fs/genfstab
genfstab -t PARTUUID / > /etc/fstab
echo "    fstab entries generated:"
grep -E '^[^#[:space:]]' /etc/fstab || true

# ---- Hostname ----
echo ""
echo ">>> Setting hostname to 'gentoo' ..."
echo "gentoo" > /etc/hostname
cat > /etc/conf.d/hostname <<'HOSTCONF'
hostname="gentoo"
HOSTCONF

# ---- /etc/hosts ----
echo ""
echo ">>> Writing /etc/hosts ..."
cat > /etc/hosts <<'HOSTS'
127.0.0.1     gentoo.homenetwork gentoo localhost
::1           gentoo.homenetwork gentoo localhost
HOSTS

# ---- Networking ----
echo ""
echo ">>> Installing and enabling NetworkManager ..."
safe_emerge net-misc/networkmanager
rc-update add NetworkManager default

# Avoid conflicts with NetworkManager by removing legacy dhcpcd/netifrc services.
rc-update del dhcpcd default 2>/dev/null || true
for svc_path in /etc/runlevels/default/net.*; do
    [[ -e "$svc_path" ]] || continue
    svc_name=$(basename "$svc_path")
    rc-update del "$svc_name" default 2>/dev/null || true
done

safe_emerge net-wireless/iw net-wireless/wpa_supplicant

# ---- Root password ----
echo ""
echo ">>> Set root password (interactive) ..."
passwd root

# ---- System services ----
echo ""
echo ">>> Installing and enabling syslog, cron, locate, bash-completion, chrony, io-scheduler ..."
safe_emerge app-admin/sysklogd
rc-update add sysklogd default

safe_emerge sys-process/cronie
rc-update add cronie default

safe_emerge sys-apps/mlocate
safe_emerge app-shells/bash-completion

safe_emerge net-misc/chrony
rc-update add chronyd default

safe_emerge sys-block/io-scheduler-udev-rules

# ---- User account ----
read -rp "Enter username to create (default: leathdav): " NEW_USER
NEW_USER=${NEW_USER:-leathdav}

echo ""
if id -u "$NEW_USER" >/dev/null 2>&1; then
    echo ">>> User '$NEW_USER' already exists; skipping account creation."
else
    echo ">>> Creating user '$NEW_USER' ..."
    USER_GROUPS=()
    MISSING_GROUPS=()
    for group_name in users wheel audio video usb cron; do
        if getent group "$group_name" >/dev/null 2>&1; then
            USER_GROUPS+=("$group_name")
        else
            MISSING_GROUPS+=("$group_name")
        fi
    done

    if (( ${#USER_GROUPS[@]} > 0 )); then
        USER_GROUP_LIST=$(IFS=,; echo "${USER_GROUPS[*]}")
        useradd -m -G "$USER_GROUP_LIST" -s /bin/bash "$NEW_USER"
    else
        useradd -m -s /bin/bash "$NEW_USER"
    fi

    if (( ${#MISSING_GROUPS[@]} > 0 )); then
        echo "    Skipping missing groups: ${MISSING_GROUPS[*]}"
    fi
fi

echo ">>> Set password for '$NEW_USER' (interactive) ..."
passwd "$NEW_USER"

# ---- Write host-side cleanup script ----
echo ""
echo ">>> Writing cleanup script ..."
cat > /tmp/gentoo-cleanup.sh <<'CLEANUP'
#!/bin/bash
set -euo pipefail
echo ""
echo ">>> Unmounting Gentoo filesystems ..."
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true
echo ""
echo "============================================================"
echo " Unified configuration has completed successfully."
echo " All filesystems have been unmounted."
echo " You may now type: reboot"
echo "============================================================"
rm -- "$0"
CLEANUP
chmod +x /tmp/gentoo-cleanup.sh

# ---- Done ----
echo ""
echo "============================================================"
echo " 02-Stage2-ChrootSetup has completed successfully."
echo " Install mode: $INSTALL_MODE"
echo " Kernel path: $KERNEL_TRACK"
echo " Run the cleanup from the HOST shell:"
echo "   /mnt/gentoo/tmp/gentoo-cleanup.sh"
echo "============================================================"
exit
