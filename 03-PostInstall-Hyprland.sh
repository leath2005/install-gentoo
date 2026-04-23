#!/bin/bash
set -euo pipefail

# ============================================================
#  03-PostInstall-Hyprland.sh
#  Minimal Hyprland desktop setup for Gentoo + OpenRC:
#  - Hyprland compositor + Xwayland
#  - Waybar status bar
#  - Foot terminal
#  - Wofi launcher
#  - Thunar file manager
#  - Mako notifications
#  - PipeWire + WirePlumber audio
#  - xdg-desktop-portal-hyprland portal integration
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (inside the installed Gentoo system)." >&2
    exit 1
fi

if [[ ! -f /etc/gentoo-release ]]; then
    echo "ERROR: /etc/gentoo-release not found. This script is for Gentoo only." >&2
    exit 1
fi

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

echo ""
read -rp "Enter desktop username (default: leathdav): " TARGET_USER
TARGET_USER=${TARGET_USER:-leathdav}

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERROR: User '$TARGET_USER' does not exist." >&2
    exit 1
fi

echo ""
echo ">>> Installing core Hyprland stack ..."
safe_emerge --autounmask \
    gui-wm/hyprland \
    x11-base/xwayland \
    gui-apps/waybar \
    x11-terms/foot \
    x11-misc/wofi \
    xfce-base/thunar \
    gui-apps/mako \
    x11-misc/wl-clipboard \
    media-gfx/grim \
    gui-apps/slurp \
    media-video/pipewire \
    media-sound/wireplumber \
    xdg-desktop-portal/xdg-desktop-portal \
    gui-libs/xdg-desktop-portal-hyprland \
    sys-auth/seatd \
    sys-auth/elogind \
    sys-apps/dbus \
    media-fonts/noto

echo ""
echo ">>> Enabling required services ..."
rc-update add dbus default
rc-update add elogind boot
rc-update add seatd default

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx seat; then
    :
else
    usermod -aG seat "$TARGET_USER"
fi

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: Could not resolve home directory for '$TARGET_USER'." >&2
    exit 1
fi

echo ""
echo ">>> Enabling tty1 auto-login for $TARGET_USER ..."
AUTOLOGIN_LINE="c1:12345:respawn:/sbin/agetty --autologin ${TARGET_USER} --noclear 38400 tty1 linux"
if grep -q '^c1:' /etc/inittab; then
  sed -i "s|^c1:.*|${AUTOLOGIN_LINE}|" /etc/inittab
else
  echo "$AUTOLOGIN_LINE" >> /etc/inittab
fi
rc-update add agetty default >/dev/null 2>&1 || true
if command -v telinit >/dev/null 2>&1; then
  telinit q >/dev/null 2>&1 || true
fi

echo ""
echo ">>> Writing minimal user configs in $USER_HOME/.config ..."
install -d -m 755 "$USER_HOME/.config/hypr" "$USER_HOME/.config/waybar" "$USER_HOME/.config/wofi"

cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'HYPR'
monitor=,preferred,auto,1

$mod = SUPER

exec-once = dbus-update-activation-environment --all
exec-once = pipewire
exec-once = wireplumber
exec-once = waybar
exec-once = mako

input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = true
    }
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    layout = dwindle
}

decoration {
    rounding = 6
}

bind = $mod, RETURN, exec, foot
bind = $mod, D, exec, wofi --show drun
bind = $mod, E, exec, thunar
bind = $mod, Q, killactive
bind = $mod SHIFT, Q, exit
bind = $mod, F, fullscreen

bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

bind = $mod SHIFT, H, movewindow, l
bind = $mod SHIFT, L, movewindow, r
bind = $mod SHIFT, K, movewindow, u
bind = $mod SHIFT, J, movewindow, d
HYPR

cat > "$USER_HOME/.config/waybar/config" <<'WAYBARCFG'
{
  "layer": "top",
  "position": "top",
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["network", "pulseaudio", "battery", "tray"],
  "clock": {
    "format": "{:%Y-%m-%d %H:%M}"
  }
}
WAYBARCFG

cat > "$USER_HOME/.config/waybar/style.css" <<'WAYBARCSS'
* {
  font-family: "Noto Sans", sans-serif;
  font-size: 12px;
}

window#waybar {
  background: rgba(20, 20, 20, 0.9);
  color: #e6e6e6;
}

#workspaces button {
  color: #e6e6e6;
  margin: 2px;
}
WAYBARCSS

cat > "$USER_HOME/.config/wofi/style.css" <<'WOFICSS'
window {
  margin: 0px;
  border: 2px solid #444444;
  background-color: #111111;
}

#input {
  margin: 5px;
  border: none;
  color: #e6e6e6;
  background-color: #222222;
}

#entry {
  padding: 5px;
}

#entry:selected {
  background-color: #2f2f2f;
}
WOFICSS

cat > "$USER_HOME/start-hyprland.sh" <<'START'
#!/bin/sh
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
exec dbus-run-session Hyprland
START
chmod +x "$USER_HOME/start-hyprland.sh"

BASH_PROFILE="$USER_HOME/.bash_profile"
AUTOSTART_BEGIN="# >>> hyprland-autostart >>>"
AUTOSTART_END="# <<< hyprland-autostart <<<"
if [[ ! -f "$BASH_PROFILE" ]]; then
  touch "$BASH_PROFILE"
fi
if ! grep -qF "$AUTOSTART_BEGIN" "$BASH_PROFILE"; then
  cat >> "$BASH_PROFILE" <<'AUTOSTART'

# >>> hyprland-autostart >>>
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-0}" = "1" ]; then
  exec "$HOME/start-hyprland.sh"
fi
# <<< hyprland-autostart <<<
AUTOSTART
fi

chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config" "$USER_HOME/start-hyprland.sh" "$BASH_PROFILE"

echo ""
echo "============================================================"
echo " Hyprland minimal setup complete."
echo " User: $TARGET_USER"
echo " tty1 auto-login: enabled"
echo " tty1 Hyprland autostart: enabled"
echo " Start command (as user): ~/start-hyprland.sh"
echo "============================================================"
