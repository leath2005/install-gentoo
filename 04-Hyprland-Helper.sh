#!/bin/bash
set -euo pipefail

# ============================================================
#  04-Hyprland-Helper.sh
#  Useful maintenance helpers for tty1 Hyprland workflow:
#  - Toggle tty1 auto-login
#  - Toggle tty1 Hyprland autostart in ~/.bash_profile
#  - Show current status
#  - Open hyprland config in editor
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
fi

usage() {
    cat <<'USAGE'
Usage:
  ./04-Hyprland-Helper.sh status <user>
  ./04-Hyprland-Helper.sh autologin on <user>
  ./04-Hyprland-Helper.sh autologin off
  ./04-Hyprland-Helper.sh autostart on <user>
  ./04-Hyprland-Helper.sh autostart off <user>
  ./04-Hyprland-Helper.sh edit-config <user>
    ./04-Hyprland-Helper.sh reset-config <user>
USAGE
}

require_user() {
    local user="$1"
    if [[ -z "$user" ]]; then
        echo "ERROR: Missing username." >&2
        usage
        exit 1
    fi
    if ! id -u "$user" >/dev/null 2>&1; then
        echo "ERROR: User '$user' does not exist." >&2
        exit 1
    fi
}

user_home() {
    getent passwd "$1" | cut -d: -f6
}

enable_autologin() {
    local user="$1"
    local line="c1:12345:respawn:/sbin/agetty --autologin ${user} --noclear 38400 tty1 linux"
    if grep -q '^c1:' /etc/inittab; then
        sed -i "s|^c1:.*|${line}|" /etc/inittab
    else
        echo "$line" >> /etc/inittab
    fi
    if command -v telinit >/dev/null 2>&1; then
        telinit q >/dev/null 2>&1 || true
    fi
}

disable_autologin() {
    local line="c1:12345:respawn:/sbin/agetty 38400 tty1 linux"
    if grep -q '^c1:' /etc/inittab; then
        sed -i "s|^c1:.*|${line}|" /etc/inittab
    else
        echo "$line" >> /etc/inittab
    fi
    if command -v telinit >/dev/null 2>&1; then
        telinit q >/dev/null 2>&1 || true
    fi
}

enable_autostart() {
    local user="$1"
    local home
    home=$(user_home "$user")
    local profile="$home/.bash_profile"
    local begin="# >>> hyprland-autostart >>>"

    if [[ ! -f "$profile" ]]; then
        touch "$profile"
    fi

    if ! grep -qF "$begin" "$profile"; then
        cat >> "$profile" <<'AUTOSTART'

# >>> hyprland-autostart >>>
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-0}" = "1" ]; then
    exec "$HOME/start-hyprland.sh"
fi
# <<< hyprland-autostart <<<
AUTOSTART
    fi

    chown "$user:$user" "$profile"
}

disable_autostart() {
    local user="$1"
    local home
    home=$(user_home "$user")
    local profile="$home/.bash_profile"
    local begin="# >>> hyprland-autostart >>>"
    local end="# <<< hyprland-autostart <<<"

    if [[ ! -f "$profile" ]]; then
        return
    fi

    sed -i "/${begin//\//\\\/}/,/${end//\//\\\/}/d" "$profile"
    chown "$user:$user" "$profile"
}

status_for_user() {
    local user="$1"
    local home
    home=$(user_home "$user")
    local profile="$home/.bash_profile"

    echo "Hyprland helper status"
    echo "  user: $user"

    if grep -q '^c1:.*--autologin' /etc/inittab; then
        echo "  autologin: enabled"
        grep '^c1:' /etc/inittab | sed 's/^/    /'
    else
        echo "  autologin: disabled"
    fi

    if [[ -f "$profile" ]] && grep -qF '# >>> hyprland-autostart >>>' "$profile"; then
        echo "  autostart: enabled"
    else
        echo "  autostart: disabled"
    fi
}

edit_config() {
    local user="$1"
    local home
    home=$(user_home "$user")
    local cfg="$home/.config/hypr/hyprland.conf"
    local editor="${EDITOR:-nano}"
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: $cfg not found." >&2
        exit 1
    fi
    "$editor" "$cfg"
    chown "$user:$user" "$cfg"
}

reset_config() {
    local user="$1"
    local home
    home=$(user_home "$user")
    local cfg_dir="$home/.config/hypr"
    local cfg="$cfg_dir/hyprland.conf"

    install -d -m 755 "$cfg_dir"

    if [[ -f "$cfg" ]]; then
        cp -f "$cfg" "$cfg.bak"
    fi

    cat > "$cfg" <<'HYPR'
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

    chown -R "$user:$user" "$home/.config"
}

cmd="${1:-}"
action="${2:-}"
user="${3:-}"

case "$cmd" in
    status)
        require_user "$action"
        status_for_user "$action"
        ;;
    autologin)
        case "$action" in
            on)
                require_user "$user"
                enable_autologin "$user"
                echo "Enabled tty1 auto-login for $user."
                ;;
            off)
                disable_autologin
                echo "Disabled tty1 auto-login."
                ;;
            *)
                usage
                exit 1
                ;;
        esac
        ;;
    autostart)
        case "$action" in
            on)
                require_user "$user"
                enable_autostart "$user"
                echo "Enabled tty1 Hyprland autostart for $user."
                ;;
            off)
                require_user "$user"
                disable_autostart "$user"
                echo "Disabled tty1 Hyprland autostart for $user."
                ;;
            *)
                usage
                exit 1
                ;;
        esac
        ;;
    edit-config)
        require_user "$action"
        edit_config "$action"
        ;;
    reset-config)
        require_user "$action"
        reset_config "$action"
        echo "Reset Hyprland config for $action (backup: hyprland.conf.bak if previous config existed)."
        ;;
    *)
        usage
        exit 1
        ;;
esac
