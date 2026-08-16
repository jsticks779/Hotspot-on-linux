#!/usr/bin/env bash
#
# Removes linux-hotspot. Your settings are kept unless you pass --purge.
#
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge
#
# https://github.com/jsticks779/Hotspot-on-linux

set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" = 0 ] || { echo "please run this with sudo" >&2; exit 1; }

EXT_UUID="linux-hotspot@jsticks779.github.io"
CONF_DIR=/etc/linux-hotspot

echo ":: stopping the hotspot"
systemctl disable --now linux-hotspot.service >/dev/null 2>&1 || true
systemctl disable --now linux-hotspot-resume.service >/dev/null 2>&1 || true
if [ -x /usr/local/bin/linux-hotspot ]; then
    /usr/local/bin/linux-hotspot down >/dev/null 2>&1 || true
fi

echo ":: removing files"
rm -f /etc/systemd/system/linux-hotspot.service /etc/systemd/system/linux-hotspot-resume.service
rm -f /etc/polkit-1/rules.d/49-linux-hotspot.rules
rm -f /etc/NetworkManager/conf.d/99-linux-hotspot.conf
rm -f /etc/NetworkManager/dispatcher.d/50-linux-hotspot
rm -f /usr/local/bin/linux-hotspot /usr/local/bin/hotspot
rm -f /run/linux-hotspot* /var/lib/misc/linux-hotspot.leases
if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi

# The desktop toggle lives in the user's home, not in /usr.
for home in /home/*; do
    ext="$home/.local/share/gnome-shell/extensions/$EXT_UUID"
    if [ -d "$ext" ]; then
        rm -rf "$ext"
        echo ":: removed the GNOME toggle from $home"
    fi
done

if systemctl is-active NetworkManager >/dev/null 2>&1; then
    systemctl reload NetworkManager >/dev/null 2>&1 || true
fi

if [ "$PURGE" = 1 ]; then
    rm -rf "$CONF_DIR"
    echo ":: purged $CONF_DIR"
else
    echo ":: kept your settings in $CONF_DIR (use --purge to delete them)"
fi

echo
echo "Done. hostapd and dnsmasq were left installed — remove them with your"
echo "package manager if you no longer want them."
