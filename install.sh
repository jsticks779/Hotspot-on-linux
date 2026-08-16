#!/usr/bin/env bash
#
# linux-hotspot installer.
#
#   One command, interactive:
#     curl -fsSL https://raw.githubusercontent.com/jsticks779/Hotspot-on-linux/main/install.sh | sudo bash
#
#   One command, no questions asked:
#     curl -fsSL https://raw.githubusercontent.com/jsticks779/Hotspot-on-linux/main/install.sh \
#       | sudo bash -s -- --ssid "MyHotspot" --password "supersecret"
#
#   From a clone:
#     sudo ./install.sh --ssid "MyHotspot" --password "supersecret"
#
# https://github.com/jsticks779/Hotspot-on-linux

set -euo pipefail

REPO="jsticks779/Hotspot-on-linux"
REF="${REF:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"

PREFIX=/usr/local/bin
CONF_DIR=/etc/linux-hotspot
CONF="$CONF_DIR/hotspot.conf"
EXT_UUID="linux-hotspot@jsticks779.github.io"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_DIM=""
fi
say()  { echo "${C_BLUE}::${C_RESET} $*"; }
ok()   { echo "${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { echo "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

# ------------------------------------------------------------------- options -
SSID_ARG="${SSID:-}"
PASS_ARG="${PASSWORD:-}"
SECURITY_ARG="${SECURITY:-wpa2}"
WANT_EXTENSION=1
WANT_START=1
WANT_ENABLE=1

usage() {
    cat <<EOF
${C_BOLD}linux-hotspot installer${C_RESET}

  --ssid NAME          the network name devices will see
  --password SECRET    8-63 characters
  --security MODE      wpa2 (default) | wpa3 | mixed
  --no-extension       skip the GNOME quick-settings toggle
  --no-start           install but do not start the hotspot now
  --no-enable          do not bring the hotspot back after a reboot
  -h, --help           this text

Anything you leave out is asked for, or detected.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssid)       SSID_ARG="${2:?--ssid needs a value}"; shift 2 ;;
        --password)   PASS_ARG="${2:?--password needs a value}"; shift 2 ;;
        --security)   SECURITY_ARG="${2:?--security needs a value}"; shift 2 ;;
        --no-extension) WANT_EXTENSION=0; shift ;;
        --no-start)   WANT_START=0; shift ;;
        --no-enable)  WANT_ENABLE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" = 0 ] || die "please run this with sudo"

# --------------------------------------------------------------- the basics -
DESKTOP_USER="${SUDO_USER:-}"
if [ -z "$DESKTOP_USER" ] || [ "$DESKTOP_USER" = root ]; then
    # last resort: the owner of an active graphical session
    DESKTOP_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | head -n1 || true)
fi
DESKTOP_HOME=""
[ -n "$DESKTOP_USER" ] && DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6 || true)

echo
echo "${C_BOLD}linux-hotspot${C_RESET} — share your internet over Wi-Fi"
# shellcheck source=/dev/null
echo "${C_DIM}$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown system}") · kernel $(uname -r)${C_RESET}"
echo

# ---------------------------------------------------------------- questions -
ask_credentials() {
    [ -n "$SSID_ARG" ] && [ -n "$PASS_ARG" ] && return 0

    # `curl | bash` leaves stdin holding the script, so talk to the terminal.
    if [ -r /dev/tty ]; then
        exec 3</dev/tty || true
        if [ -z "$SSID_ARG" ]; then
            local default="${HOSTNAME:-hotspot}"
            printf 'Network name (SSID) [%s]: ' "$default"
            read -r SSID_ARG <&3 || true
            [ -n "$SSID_ARG" ] || SSID_ARG="$default"
        fi
        while [ -z "$PASS_ARG" ] || [ ${#PASS_ARG} -lt 8 ]; do
            printf 'Wi-Fi password (at least 8 characters): '
            read -rs PASS_ARG <&3 || true
            echo
            [ ${#PASS_ARG} -ge 8 ] || echo "  too short, try again"
        done
        exec 3<&- || true
        return 0
    fi

    # Nobody to ask: pick something safe and print it loudly at the end.
    [ -n "$SSID_ARG" ] || SSID_ARG="${HOSTNAME:-hotspot}"
    if [ -z "$PASS_ARG" ]; then
        PASS_ARG=$(tr -dc 'a-z2-9' </dev/urandom | head -c 12)
        GENERATED_PASSWORD=1
    fi
}
GENERATED_PASSWORD=0
ask_credentials

if [ ${#SSID_ARG} -lt 1 ] || [ ${#SSID_ARG} -gt 32 ]; then
    die "the network name must be 1-32 characters"
fi
if [ ${#PASS_ARG} -lt 8 ] || [ ${#PASS_ARG} -gt 63 ]; then
    die "the password must be 8-63 characters"
fi

# ------------------------------------------------------------- dependencies -
install_deps() {
    local pkgs="hostapd dnsmasq iw"
    say "installing $pkgs"
    # $pkgs is deliberately unquoted below: it must split into one argument
    # per package.
    # shellcheck disable=SC2086
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs iptables >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs >/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed $pkgs >/dev/null
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install $pkgs >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        apk add --quiet $pkgs
    else
        warn "unknown package manager — make sure hostapd, dnsmasq and iw are installed"
        return 0
    fi
    ok "dependencies installed"
}
install_deps

for t in iw hostapd dnsmasq; do
    command -v "$t" >/dev/null 2>&1 || die "$t is still missing — install it and re-run"
done

# Distro packages of hostapd and dnsmasq bring their own system-wide services.
# We run our own private instances, so leave the packaged ones switched off or
# they will fight us for the interface and for port 53.
if command -v systemctl >/dev/null 2>&1; then
    for unit in hostapd dnsmasq; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            say "switched off the system-wide $unit service (this project runs its own)"
        fi
    done
fi

# ------------------------------------------------------------------- files --
SRC=""
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    CANDIDATE=$(cd "$(dirname "$SELF")" && pwd)
    [ -f "$CANDIDATE/bin/linux-hotspot" ] && SRC="$CANDIDATE"
fi

if [ -z "$SRC" ]; then
    command -v curl >/dev/null 2>&1 || die "curl is needed to download the project files"
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    say "downloading from github.com/$REPO ($REF)"
    mkdir -p "$SRC/bin" "$SRC/systemd" "$SRC/polkit" "$SRC/gnome-extension/$EXT_UUID"
    for f in bin/linux-hotspot systemd/linux-hotspot.service systemd/linux-hotspot-resume.service \
             polkit/49-linux-hotspot.rules \
             "gnome-extension/$EXT_UUID/metadata.json" "gnome-extension/$EXT_UUID/extension.js"; do
        curl -fsSL "$RAW/$f" -o "$SRC/$f" || die "could not download $f — is the repository public and the branch '$REF' correct?"
    done
    ok "downloaded"
fi

install -m 0755 "$SRC/bin/linux-hotspot" "$PREFIX/linux-hotspot"
ln -sf "$PREFIX/linux-hotspot" "$PREFIX/hotspot"
ok "installed $PREFIX/linux-hotspot (also available as: hotspot)"

# ------------------------------------------------------------------ config --
# The directory is setgid to the desktop user's group so the GNOME toggle can
# rewrite the password without asking for root.
GROUP="root"
if [ -n "$DESKTOP_USER" ] && getent group "$DESKTOP_USER" >/dev/null 2>&1; then
    GROUP="$DESKTOP_USER"
fi
install -d -m 2775 -g "$GROUP" "$CONF_DIR"

if [ -f "$CONF" ]; then
    cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
    say "kept a backup of your previous config"
fi

cat > "$CONF" <<EOF
# linux-hotspot configuration
# Docs: https://github.com/$REPO

SSID=$SSID_ARG
PASSPHRASE=$PASS_ARG

# wpa2 (works everywhere) | wpa3 (modern devices only) | mixed
SECURITY=$SECURITY_ARG

# Everything below is detected automatically. Uncomment only to override.
#STA_IFACE=wlan0
#UPLINK_IFACE=eth0
#AP_IFACE=ap0
#AP_MAC=02:11:22:33:44:55
#CHANNEL=6
#COUNTRY=US
#IPV4_NET=10.42.0
#DNS_SERVERS=1.1.1.1,8.8.8.8
#HIDDEN=0
EOF
chgrp "$GROUP" "$CONF"
chmod 0660 "$CONF"
ok "wrote $CONF"

# ------------------------------------------------------------------ polkit --
if [ -d /etc/polkit-1 ]; then
    install -d -m 0755 /etc/polkit-1/rules.d
    install -m 0644 "$SRC/polkit/49-linux-hotspot.rules" /etc/polkit-1/rules.d/49-linux-hotspot.rules
    ok "installed the polkit rule (toggle without a password prompt)"
fi

# ---------------------------------------------------------- NetworkManager --
if [ -d /etc/NetworkManager ]; then
    install -d -m 0755 /etc/NetworkManager/conf.d
    AP_IFACE=$(awk -F= '/^AP_IFACE=/{print $2}' "$CONF" 2>/dev/null)
    [ -n "$AP_IFACE" ] || AP_IFACE=ap0
    cat > /etc/NetworkManager/conf.d/99-linux-hotspot.conf <<EOF
# The hotspot interface is driven by hostapd, not by NetworkManager. Without
# this, NetworkManager lists it as a second Wi-Fi device and interferes with it.
[keyfile]
unmanaged-devices=interface-name:$AP_IFACE
EOF
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi
    ok "told NetworkManager to leave $AP_IFACE alone"
fi

# ----------------------------------------------------------------- systemd --
HAVE_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAVE_SYSTEMD=1
    install -m 0644 "$SRC/systemd/linux-hotspot.service" /etc/systemd/system/linux-hotspot.service
    install -m 0644 "$SRC/systemd/linux-hotspot-resume.service" /etc/systemd/system/linux-hotspot-resume.service
    systemctl daemon-reload
    systemctl enable linux-hotspot-resume.service >/dev/null 2>&1 || true
    ok "installed the linux-hotspot service (and a resume hook for after suspend)"
    if [ "$WANT_ENABLE" = 1 ]; then
        systemctl enable linux-hotspot.service >/dev/null 2>&1 && ok "it will come back after a reboot"
    fi
else
    warn "no systemd here — start the hotspot with: sudo linux-hotspot up"
fi

# --------------------------------------------------------------- extension --
# A running GNOME Shell only scans the extensions directory at login, so
# `gnome-extensions enable` refuses a brand-new one with "does not exist". The
# setting itself is just a dconf list, and writing it directly works fine — the
# shell picks the extension up next time the user logs in.
enable_gnome_extension() {
    local user=$1 uuid=$2 uid bus current
    uid=$(id -u "$user" 2>/dev/null) || return 1
    bus="unix:path=/run/user/$uid/bus"
    [ -S "/run/user/$uid/bus" ] || return 1

    if sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$bus" \
        gnome-extensions enable "$uuid" >/dev/null 2>&1; then
        return 0
    fi

    current=$(sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$bus" \
        gsettings get org.gnome.shell enabled-extensions 2>/dev/null) || return 1
    case "$current" in
        *"'$uuid'"*) return 0 ;;                 # already listed
        "@as []"|"[]") current="['$uuid']" ;;
        *)             current="${current%]}, '$uuid']" ;;
    esac
    sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$bus" \
        gsettings set org.gnome.shell enabled-extensions "$current" >/dev/null 2>&1
}

EXTENSION_NOTE=""
if [ "$WANT_EXTENSION" = 1 ] && [ -n "$DESKTOP_HOME" ] && command -v gnome-shell >/dev/null 2>&1; then
    EXT_DIR="$DESKTOP_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    install -d -o "$DESKTOP_USER" -g "$GROUP" "$EXT_DIR"
    install -o "$DESKTOP_USER" -g "$GROUP" -m 0644 \
        "$SRC/gnome-extension/$EXT_UUID/metadata.json" \
        "$SRC/gnome-extension/$EXT_UUID/extension.js" "$EXT_DIR/"
    ok "installed the GNOME quick-settings toggle"

    if enable_gnome_extension "$DESKTOP_USER" "$EXT_UUID"; then
        EXTENSION_NOTE="log out and back in to see the Hotspot tile in quick settings"
    else
        EXTENSION_NOTE="after logging back in, run: gnome-extensions enable $EXT_UUID"
    fi
fi

# ------------------------------------------------------------------- start --
echo
if [ "$WANT_START" = 1 ] && [ "$HAVE_SYSTEMD" = 1 ]; then
    say "starting the hotspot"
    if systemctl restart linux-hotspot.service; then
        ok "running"
    else
        warn "it did not start — run ${C_BOLD}sudo linux-hotspot doctor${C_RESET} to find out why"
        warn "details: journalctl -u linux-hotspot -n 30 --no-pager"
    fi
fi

# ----------------------------------------------------------------- summary --
echo
echo "${C_BOLD}────────────────────────────────────────────${C_RESET}"
echo "${C_BOLD} Wi-Fi name ${C_RESET} $SSID_ARG"
echo "${C_BOLD} Password   ${C_RESET} $PASS_ARG"
if [ "$GENERATED_PASSWORD" = 1 ]; then
    echo "${C_YELLOW}            (generated for you — change it with:"
    echo "             sudo linux-hotspot config --password 'new-one')${C_RESET}"
fi
echo "${C_BOLD}────────────────────────────────────────────${C_RESET}"
echo
echo "  sudo linux-hotspot status     see who is connected"
echo "  sudo linux-hotspot doctor     check this machine"
echo "  sudo systemctl stop linux-hotspot"
[ -n "$EXTENSION_NOTE" ] && echo && echo "  ${C_YELLOW}$EXTENSION_NOTE${C_RESET}"
echo
