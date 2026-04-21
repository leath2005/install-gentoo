#!/bin/bash
set -euo pipefail

# ============================================================
#  03-ConfigurationPart2.sh
#  Invoke from the HOST like so (not manually inside chroot):
#    chroot /mnt/gentoo /bin/bash /path/to/03-ConfigurationPart2.sh && /mnt/gentoo/tmp/gentoo-cleanup.sh
#
#  Configures fstab, hostname, networking, users, and services,
#  then unmounts and prepares for reboot.
# ============================================================

# --- Privilege check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root inside the chroot." >&2
    exit 1
fi

# --- Sanity check ---
if [[ ! -f /etc/gentoo-release ]]; then
    echo "ERROR: /etc/gentoo-release not found. Are you running this inside the Gentoo chroot?" >&2
    exit 1
fi

# ---- Depclean ----
echo ""
echo ">>> Running emerge --depclean ..."
emerge --depclean

# ---- Detect PARTUUIDs ----
echo ""
echo ">>> Detecting partition PARTUUIDs ..."

ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ -z "$ROOT_DEV" ]]; then
    echo "ERROR: Could not determine root device." >&2
    exit 1
fi

# Derive base device and partition suffix style
# e.g. /dev/nvme0n1p3 -> base=/dev/nvme0n1, parts use 'p' prefix
# e.g. /dev/sda3      -> base=/dev/sda,     parts are numbered directly
if [[ "$ROOT_DEV" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p([0-9]+)$ ]]; then
    BASE_DEV="/dev/${BASH_REMATCH[1]}"
    PART_SEP="p"
elif [[ "$ROOT_DEV" =~ (/dev/[a-z]+)([0-9]+)$ ]]; then
    BASE_DEV="${BASH_REMATCH[1]}"
    PART_SEP=""
else
    echo "ERROR: Could not parse root device name: $ROOT_DEV" >&2
    exit 1
fi

get_partuuid() {
    local dev="$1"
    local uuid
    uuid=$(blkid -s PARTUUID -o value "$dev")
    if [[ -z "$uuid" ]]; then
        echo "ERROR: Could not get PARTUUID for $dev" >&2
        exit 1
    fi
    echo "$uuid"
}

PARTUUID1=$(get_partuuid "${BASE_DEV}${PART_SEP}1")
PARTUUID2=$(get_partuuid "${BASE_DEV}${PART_SEP}2")
PARTUUID3=$(get_partuuid "${BASE_DEV}${PART_SEP}3")

echo "    Partition 1 (EFI)  PARTUUID: $PARTUUID1"
echo "    Partition 2 (swap) PARTUUID: $PARTUUID2"
echo "    Partition 3 (root) PARTUUID: $PARTUUID3"

# ---- Write /etc/fstab ----
echo ""
echo ">>> Writing /etc/fstab ..."

cat > /etc/fstab <<FSTAB
# <fs>                                  <mountpoint>  <type>  <opts>                       <dump> <pass>
PARTUUID=${PARTUUID1}   /efi        vfat    umask=0077,tz=UTC            0 2
PARTUUID=${PARTUUID2}   none        swap    sw                           0 0
PARTUUID=${PARTUUID3}   /           xfs     defaults,noatime             0 1
FSTAB

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
echo ">>> Installing and enabling dhcpcd and NetworkManager ..."
emerge net-misc/dhcpcd
rc-update add dhcpcd default

emerge net-misc/networkmanager
rc-update add NetworkManager default

emerge --noreplace net-misc/netifrc

# Detect the primary non-loopback network interface
NET_IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
if [[ -z "$NET_IFACE" ]]; then
    echo "WARNING: Could not auto-detect network interface; defaulting to 'eth0'."
    echo "         Edit /etc/conf.d/net and /etc/init.d/net.* manually after boot."
    NET_IFACE="eth0"
fi
echo "    Detected interface: $NET_IFACE"

echo "config_${NET_IFACE}=\"dhcp\"" > /etc/conf.d/net

cd /etc/init.d
ln -sf net.lo "net.${NET_IFACE}"
rc-update add "net.${NET_IFACE}" default
cd /

emerge net-wireless/iw net-wireless/wpa_supplicant

# ---- Root password ----
echo ""
echo ">>> Setting root password ..."
echo "root:tits" | chpasswd

# ---- System services ----
echo ""
echo ">>> Installing and enabling syslog, cron, locate, bash-completion, chrony, io-scheduler ..."
emerge app-admin/sysklogd
rc-update add sysklogd default

emerge sys-process/cronie
rc-update add cronie default

emerge sys-apps/mlocate
emerge app-shells/bash-completion

emerge net-misc/chrony
rc-update add chronyd default

emerge sys-block/io-scheduler-udev-rules

# ---- User account ----
echo ""
echo ">>> Creating user 'leathdav' ..."
useradd -m -G users,wheel,audio,video,usb,cron -s /bin/bash leathdav
echo "leathdav:tits" | chpasswd

# ---- Write host-side cleanup script, exit chroot, then run it ----
echo ""
echo ">>> Writing cleanup script and exiting chroot ..."

cat > /tmp/gentoo-cleanup.sh <<'CLEANUP'
#!/bin/bash
set -euo pipefail
echo ""
echo ">>> Unmounting Gentoo filesystems ..."
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo
echo ""
echo "============================================================"
echo " 03-ConfigurationPart2 has completed successfully."
echo " All filesystems have been unmounted."
echo " You may now type: reboot"
echo "============================================================"
rm -- "$0"
CLEANUP

chmod +x /tmp/gentoo-cleanup.sh

# Exit the chroot. The host shell will then run the cleanup script
# automatically if this script was invoked as:
#   chroot /mnt/gentoo /bin/bash /path/to/03-ConfigurationPart2.sh && /mnt/gentoo/tmp/gentoo-cleanup.sh
exit
