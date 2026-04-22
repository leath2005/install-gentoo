#!/bin/bash
set -euo pipefail

# ============================================================
#  02-ConfigurationPart1.sh
#  Invoke from the HOST via:
#    chroot /mnt/gentoo /bin/bash /path/to/02-ConfigurationPart1.sh
#  Installs firmware, kernel tooling, and the CachyOS kernel
#  overlay. Detects the root partition UUID automatically.
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

# ---- Re-source profile ----
set +u
export DEBUGINFOD_URLS=""
env-update && source /etc/profile
set -u
export PS1="(chroot) \${PS1}"

# ---- Firmware ----
echo ""
echo ">>> Installing linux-firmware and sof-firmware ..."
emerge sys-kernel/linux-firmware
emerge sys-firmware/sof-firmware

# ---- Kernel tooling ----
echo ""
echo ">>> Configuring and installing sys-kernel/installkernel with dracut + efistub ..."
echo "sys-kernel/installkernel dracut efistub" > /etc/portage/package.use/installkernel
emerge sys-kernel/installkernel

# ---- Detect root partition UUID ----
echo ""
echo ">>> Detecting root partition UUID ..."

# Find the device mounted at /  (works whether called p3 or sda3)
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

echo "    Root device : $ROOT_DEV"
echo "    Root UUID   : $ROOT_UUID"

# ---- Write dracut kernel cmdline config ----
echo ""
echo ">>> Writing /etc/dracut.conf.d/00-installkernel.conf ..."

mkdir --parents /etc/dracut.conf.d
cat > /etc/dracut.conf.d/00-installkernel.conf <<DRACUT
kernel_cmdline=" root=UUID=${ROOT_UUID} rw "
DRACUT

echo "    Written: kernel_cmdline=\" root=UUID=${ROOT_UUID} rw \""

# ---- CachyOS kernel overlay ----
echo ""
echo ">>> Installing eselect-repository and git, enabling CachyOS-kernels overlay ..."
emerge app-eselect/eselect-repository dev-vcs/git
eselect repository enable CachyOS-kernels
emaint sync -r CachyOS-kernels

# ---- Done ----
echo ""
echo "============================================================"
echo " 02-ConfigurationPart1 has completed successfully."
echo ""
echo " You must now run the following command manually to install"
echo " the CachyOS kernel (autounmask may require extra steps):"
echo ""
echo "   emerge --ask --autounmask sys-kernel/cachyos-kernel"
echo ""
echo " After the kernel is installed, invoke 03-ConfigurationPart2.sh from"
echo " the HOST as:"
echo "   chroot /mnt/gentoo /bin/bash /path/to/03-ConfigurationPart2.sh && /mnt/gentoo/tmp/gentoo-cleanup.sh"
echo "============================================================"
