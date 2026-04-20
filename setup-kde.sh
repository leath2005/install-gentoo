#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  KDE Plasma 6 Setup for Gentoo Linux
#  OpenRC · AMD (amdgpu/radeonsi) · Wayland · EFI Stub
#
#  Assumes: completed base system with working kernel, VIDEO_CARDS,
#           CPU_FLAGS_X86, and desktop/plasma profile already set.
#
#  Run as root:  chmod +x setup-kde.sh && ./setup-kde.sh
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
step()  { printf "\n${BOLD}${CYAN}── Step %s ──${NC}\n" "$*"; }

# ── Auto-merge config updates ────────────────────────────────────────
# Runs after each emerge to handle ._cfg0000_* files automatically.
# Mode -3: auto-merge configs where the user never modified the original.
# Mode -5: auto-merge ALL (we fall back to this only if -3 leaves files).
auto_merge_configs() {
    if find /etc -name '._cfg0000_*' 2>/dev/null | grep -q .; then
        info "Config file updates detected — auto-merging..."
        etc-update --automode -3 2>/dev/null || true
        # If any remain (user-modified originals), merge those too
        if find /etc -name '._cfg0000_*' 2>/dev/null | grep -q .; then
            warn "Remaining config updates — merging all (new versions win)..."
            etc-update --automode -5 2>/dev/null || true
        fi
        ok "Config files merged."
    fi
}

# ── Safe emerge wrapper ──────────────────────────────────────────────
# Handles autounmask-write + config merging in one call.
safe_emerge() {
    local emerge_args=("$@")

    # First attempt
    if ! emerge "${emerge_args[@]}"; then
        warn "Emerge failed — writing autounmask changes and retrying..."
        emerge --autounmask-write "${emerge_args[@]}" || true
        # Apply any package.use/keywords/license changes Portage wrote
        etc-update --automode -5 2>/dev/null || true
        dispatch-conf 2>/dev/null <<< 'u' || true
        # Retry
        emerge "${emerge_args[@]}"
    fi

    auto_merge_configs
}

# ── Root check ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

# ── Get target username ──────────────────────────────────────────────
read -rp "Enter the non-root username for KDE: " TARGET_USER

if ! id "$TARGET_USER" &>/dev/null; then
    err "User '$TARGET_USER' does not exist."
    exit 1
fi
ok "User '$TARGET_USER' found."

# ══════════════════════════════════════════════════════════════════════
#  STEP 1 — USE flags in make.conf
# ══════════════════════════════════════════════════════════════════════
step "1: Configuring USE flags"

KDE_USE_FLAGS="elogind dbus policykit pipewire alsa bluetooth networkmanager wayland X openrc -systemd -gnome -gtk-doc -test"

# Remove old conflicting flags from USE lines
for flag in qt4 qt5 kde plasma handbook; do
    if grep -qE "^USE=.*\b${flag}\b" /etc/portage/make.conf; then
        warn "Removing conflicting flag '$flag' from USE (profile manages this)."
        sed -i "s/\b${flag}\b//g" /etc/portage/make.conf
    fi
done

# Check if USE flags already present
if grep -q 'elogind' /etc/portage/make.conf && grep -q 'pipewire' /etc/portage/make.conf && grep -q 'networkmanager' /etc/portage/make.conf; then
    ok "KDE USE flags already present in make.conf."
else
    info "Appending USE flags to make.conf..."

    # Remove any existing bare USE= line that we'd conflict with, then add ours
    # If there's already a USE line, merge into it; otherwise append
    if grep -qE '^USE=' /etc/portage/make.conf; then
        # Extract existing USE value (handle multi-line with backslash)
        EXISTING_USE=$(sed -n '/^USE=/,/[^\\]$/p' /etc/portage/make.conf | sed 's/^USE=//;s/"//g;s/\\//g' | tr '\n' ' ' | xargs)
        # Remove old USE block
        sed -i '/^USE=/,/[^\\]$/d' /etc/portage/make.conf
        # Merge: add new flags that aren't already present
        MERGED_USE="$EXISTING_USE"
        for flag in $KDE_USE_FLAGS; do
            if ! echo "$MERGED_USE" | grep -qw -- "$flag"; then
                MERGED_USE="$MERGED_USE $flag"
            fi
        done
        MERGED_USE=$(echo "$MERGED_USE" | xargs)
        printf '\nUSE="%s"\n' "$MERGED_USE" >> /etc/portage/make.conf
    else
        printf '\nUSE="%s"\n' "$KDE_USE_FLAGS" >> /etc/portage/make.conf
    fi
    ok "USE flags set."
fi

# ACCEPT_LICENSE
if ! grep -q '^ACCEPT_LICENSE=' /etc/portage/make.conf; then
    echo 'ACCEPT_LICENSE="*"' >> /etc/portage/make.conf
    ok "ACCEPT_LICENSE added."
else
    ok "ACCEPT_LICENSE already set."
fi

# ACCEPT_KEYWORDS
if ! grep -q '^ACCEPT_KEYWORDS=' /etc/portage/make.conf; then
    echo 'ACCEPT_KEYWORDS="amd64"' >> /etc/portage/make.conf
    ok "ACCEPT_KEYWORDS added."
else
    ok "ACCEPT_KEYWORDS already set."
fi

# ── Package-specific USE flags ───────────────────────────────────────
info "Setting per-package USE flags..."

mkdir -p /etc/portage/package.use

# plasma-login-sessions: keep both Wayland and X11 initially for safety
if [[ ! -f /etc/portage/package.use/plasma-login-sessions ]]; then
    echo "kde-plasma/plasma-login-sessions wayland X" > /etc/portage/package.use/plasma-login-sessions
    ok "plasma-login-sessions USE flags set (wayland + X11 fallback)."
else
    ok "plasma-login-sessions USE flags already configured."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 2 — Pre-install services (--oneshot)
# ══════════════════════════════════════════════════════════════════════
step "2: Installing pre-install services"

info "Installing elogind, dbus, pipewire, wireplumber with --oneshot..."
info "This ensures they exist before plasma-meta resolves dependencies."

safe_emerge --oneshot --noreplace sys-auth/elogind sys-apps/dbus \
    media-video/pipewire media-video/wireplumber

ok "Pre-install services installed."

# ══════════════════════════════════════════════════════════════════════
#  STEP 3 — Install KDE Plasma + Apps + system tools
# ══════════════════════════════════════════════════════════════════════
step "3: Installing KDE Plasma + Apps + system tools"

warn "This is the big emerge — it will take a long time."
read -rp "Proceed with KDE installation? [Y/n]: " reply
[[ "$reply" =~ ^[Nn]$ ]] && { warn "Skipping KDE install."; } || {
    info "Emerging plasma-meta and kde-apps-meta..."
    safe_emerge --verbose kde-plasma/plasma-meta kde-apps/kde-apps-meta

    info "Emerging system tools..."
    safe_emerge --verbose \
        net-misc/networkmanager \
        net-wireless/bluez \
        sys-fs/udisks \
        sys-power/upower \
        app-misc/colord \
        x11-misc/xdg-user-dirs \
        app-admin/sudo \
        gui-libs/display-manager-init

    ok "KDE and system tools installed."
}

# ══════════════════════════════════════════════════════════════════════
#  STEP 4 — Configure display-manager-init
# ══════════════════════════════════════════════════════════════════════
step "4: Configuring display-manager-init"

if [[ -f /etc/conf.d/display-manager ]]; then
    sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="sddm"/' /etc/conf.d/display-manager
    ok "DISPLAYMANAGER set to sddm."
else
    warn "/etc/conf.d/display-manager not found — display-manager-init may not be installed yet."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 5 — SDDM Wayland configuration
# ══════════════════════════════════════════════════════════════════════
step "5: Configuring SDDM for Wayland"

mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/override.conf << 'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SessionDir=/usr/share/wayland-sessions

[Users]
RememberLastUser=true
RememberLastSession=true
EOF

ok "SDDM Wayland config written to /etc/sddm.conf.d/override.conf"

# machine-id
if [[ ! -f /etc/machine-id ]] || [[ ! -s /etc/machine-id ]]; then
    info "Generating /etc/machine-id..."
    if command -v systemd-machine-id-setup &>/dev/null; then
        systemd-machine-id-setup
    else
        uuidgen | tr -d '-' > /etc/machine-id
    fi
    ok "machine-id generated."
else
    ok "machine-id already exists."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 6 — OpenRC services
# ══════════════════════════════════════════════════════════════════════
step "6: Enabling OpenRC services"

# elogind must be in boot, not default
rc-update add elogind boot   2>/dev/null && ok "elogind → boot"   || ok "elogind already in boot"
rc-update add dbus default   2>/dev/null && ok "dbus → default"   || ok "dbus already in default"
rc-update add NetworkManager default 2>/dev/null && ok "NetworkManager → default" || ok "NetworkManager already in default"
rc-update add bluetooth default 2>/dev/null && ok "bluetooth → default" || ok "bluetooth already in default"
rc-update add udisks default 2>/dev/null && ok "udisks → default" || ok "udisks already in default"
rc-update add upower default 2>/dev/null && ok "upower → default" || ok "upower already in default"
rc-update add colord default 2>/dev/null && ok "colord → default" || ok "colord already in default"
rc-update add display-manager default 2>/dev/null && ok "display-manager → default" || ok "display-manager already in default"

# ══════════════════════════════════════════════════════════════════════
#  STEP 7 — Remove netifrc / dhcpcd conflicts
# ══════════════════════════════════════════════════════════════════════
step "7: Removing netifrc conflicts"

FOUND_NETIFRC=0
for x in /etc/runlevels/default/net.* ; do
    [[ -e "$x" ]] || continue
    FOUND_NETIFRC=1
    SVC=$(basename "$x")
    warn "Removing conflicting service: $SVC"
    rc-update del "$SVC" default 2>/dev/null || true
    rc-service --ifstarted "$SVC" stop 2>/dev/null || true
done

if [[ $FOUND_NETIFRC -eq 0 ]]; then
    ok "No netifrc net.* conflicts found."
else
    ok "netifrc services removed."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 8 — User groups
# ══════════════════════════════════════════════════════════════════════
step "8: Setting up user groups for '$TARGET_USER'"

GROUPS_TO_ADD="wheel,audio,video,usb,plugdev,input,bluetooth,seat"
usermod -aG "$GROUPS_TO_ADD" "$TARGET_USER"
ok "Added '$TARGET_USER' to groups: $GROUPS_TO_ADD"

# Enable wheel for sudo (uncomment %wheel line)
if [[ -f /etc/sudoers ]]; then
    if grep -q '^# %wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        ok "Enabled %wheel in sudoers."
    elif grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
        ok "%wheel already enabled in sudoers."
    else
        # Try the other common format
        if grep -q '^# %wheel ALL=(ALL) ALL' /etc/sudoers; then
            sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
            ok "Enabled %wheel in sudoers."
        elif grep -q '^%wheel ALL=(ALL) ALL' /etc/sudoers; then
            ok "%wheel already enabled in sudoers."
        else
            warn "Could not find %wheel line in /etc/sudoers. Run visudo manually."
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 9 — Polkit wheel rule
# ══════════════════════════════════════════════════════════════════════
step "9: Configuring polkit wheel rule"

mkdir -p /etc/polkit-1/rules.d

if [[ ! -f /etc/polkit-1/rules.d/49-wheel.rules ]]; then
    cat > /etc/polkit-1/rules.d/49-wheel.rules << 'EOF'
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:wheel"];
});
EOF
    ok "Polkit wheel rule created."
else
    ok "Polkit wheel rule already exists."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 10 — KWallet PAM integration
# ══════════════════════════════════════════════════════════════════════
step "10: Configuring KWallet PAM for SDDM"

if [[ -f /etc/pam.d/sddm ]]; then
    if ! grep -q 'pam_kwallet5' /etc/pam.d/sddm; then
        printf '\n-auth     optional  pam_kwallet5.so\n-session  optional  pam_kwallet5.so auto_start\n' >> /etc/pam.d/sddm
        ok "KWallet PAM lines added to /etc/pam.d/sddm."
    else
        ok "KWallet PAM already configured in /etc/pam.d/sddm."
    fi
else
    warn "/etc/pam.d/sddm not found — SDDM may not be installed yet."
    warn "Add these lines manually after SDDM is installed:"
    warn "  -auth     optional  pam_kwallet5.so"
    warn "  -session  optional  pam_kwallet5.so auto_start"
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 11 — XDG user directories
# ══════════════════════════════════════════════════════════════════════
step "11: Creating XDG user directories"

su - "$TARGET_USER" -c "xdg-user-dirs-update" 2>/dev/null && \
    ok "XDG user directories created for '$TARGET_USER'." || \
    warn "xdg-user-dirs-update not available yet — will run on first login."

# ══════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════
printf "\n${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}${GREEN}  KDE Plasma setup complete!${NC}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}\n\n"

info "Final verification:"
echo ""

printf "  %-24s " "Profile:"
eselect profile show | tail -1 | xargs
printf "  %-24s " "DISPLAYMANAGER:"
grep '^DISPLAYMANAGER=' /etc/conf.d/display-manager 2>/dev/null || echo "NOT SET"
printf "  %-24s " "machine-id:"
[[ -s /etc/machine-id ]] && echo "present" || echo "MISSING"
printf "  %-24s " "User groups:"
id -nG "$TARGET_USER"
printf "  %-24s " "SDDM config:"
[[ -f /etc/sddm.conf.d/override.conf ]] && echo "present" || echo "MISSING"
printf "  %-24s " "Polkit wheel rule:"
[[ -f /etc/polkit-1/rules.d/49-wheel.rules ]] && echo "present" || echo "MISSING"
printf "  %-24s " "netifrc conflicts:"
ls /etc/runlevels/default/net.* 2>/dev/null && echo "FOUND — remove manually" || echo "clean"

echo ""
info "Services enabled:"
rc-update show 2>/dev/null | grep -E 'elogind|dbus|Network|bluetooth|udisks|upower|colord|display' || true

echo ""
warn "Review /etc/portage/make.conf before rebooting."
warn "After Wayland works, optionally restrict to Wayland-only:"
warn "  echo 'kde-plasma/plasma-login-sessions wayland -X' > /etc/portage/package.use/plasma-login-sessions"
warn "  emerge --changed-use kde-plasma/plasma-login-sessions"
echo ""
printf "${BOLD}${CYAN}  Ready to reboot!${NC}\n\n"
