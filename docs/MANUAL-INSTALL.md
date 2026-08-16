# Manual installation, step by step

For anyone who would rather not pipe a script into `sudo bash` — or who wants to
understand each piece before trusting it. Every command below is exactly what
`install.sh` does, just typed out with the reasoning attached.

Substitute your own values for `MyHotspot` and `supersecret` as you go.

---

## Step 0 — check the hardware first

Nothing else matters if the card cannot do AP mode.

```bash
sudo apt install iw          # or dnf/pacman/zypper install iw
iw phy | grep -A10 "Supported interface modes"
```

You want to see `* AP` in the list. Then check whether the card can do AP *and*
client together:

```bash
iw phy phy0 info | grep -A3 "valid interface combinations"
```

A combination containing `AP` alongside `managed` means yes. If you also see
`#channels <= 1`, the hotspot must share your client link's channel — normal,
and handled automatically.

No `* AP` at all? Stop here — see [COMPATIBILITY.md](COMPATIBILITY.md).

---

## Step 1 — install the dependencies

```bash
# Debian / Ubuntu / Kali / Mint / Pop!_OS
#   dnsmasq-base, NOT dnsmasq — see the warning below
sudo apt update && sudo apt install -y hostapd dnsmasq-base iw iptables

# Fedora / RHEL
sudo dnf install -y hostapd dnsmasq iw

# Arch / Manjaro
sudo pacman -S --needed hostapd dnsmasq iw

# openSUSE
sudo zypper install hostapd dnsmasq iw
```

> **Debian-family users: install `dnsmasq-base`, not `dnsmasq`.** The base
> package ships the `/usr/sbin/dnsmasq` binary, which is all this project needs.
> The full `dnsmasq` package adds a *system-wide DNS daemon* that its postinst
> starts immediately — it grabs port 53 and can take name resolution down on the
> spot, mid-install. If you have already installed it and DNS is broken:
>
> ```bash
> sudo systemctl disable --now dnsmasq
> sudo systemctl restart NetworkManager
> getent hosts github.com          # should print an address again
> ```

---

## Step 2 — switch off the packaged services

Installing `hostapd` usually enables a system-wide service, and if the full
`dnsmasq` package is already on the machine it has one too. This project runs
its own private instances; leaving the packaged ones on means two DHCP servers
and a fight over port 53. (With `dnsmasq-base` there is no dnsmasq service to
switch off — that is the point of using it.)

```bash
sudo systemctl disable --now hostapd
sudo systemctl disable --now dnsmasq
```

This does **not** affect your normal internet — on a desktop system DNS is
handled by `systemd-resolved` or NetworkManager, not by the `dnsmasq` service.

---

## Step 3 — install the tool

```bash
git clone https://github.com/jsticks779/Hotspot-on-linux.git
cd Hotspot-on-linux
sudo install -m 0755 bin/linux-hotspot /usr/local/bin/linux-hotspot
sudo ln -sf /usr/local/bin/linux-hotspot /usr/local/bin/hotspot
```

---

## Step 4 — create the configuration

The directory is `setgid` to your own group so the GNOME password editor can
write to it later without root. Replace `$USER` if you install for someone else.

```bash
sudo install -d -m 2775 -g "$USER" /etc/linux-hotspot
sudo tee /etc/linux-hotspot/hotspot.conf >/dev/null <<'EOF'
SSID=MyHotspot
PASSPHRASE=supersecret
SECURITY=wpa2
EOF
sudo chgrp "$USER" /etc/linux-hotspot/hotspot.conf
sudo chmod 0660 /etc/linux-hotspot/hotspot.conf
```

> Careful with `sudo tee` and here-documents: if you ever write
> `echo password | sudo -S tee file <<EOF`, the here-document replaces the pipe
> as stdin and your **sudo password gets written into the file as line 1**. That
> exact mistake once wrote a password into a NetworkManager config and stopped
> NetworkManager from starting at all.

Everything else — interface names, the radio, the channel, your country — is
detected at start time. See the README for the full list of optional overrides.

---

## Step 5 — try it, before installing any services

```bash
sudo linux-hotspot doctor    # sanity check
sudo linux-hotspot up        # start it
sudo linux-hotspot status    # confirm
```

Connect a phone. If that works, carry on. If it doesn't,
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers every failure this project has
hit in practice.

```bash
sudo linux-hotspot down      # stop it again
```

---

## Step 6 — keep NetworkManager away from the AP interface

Without this, NetworkManager adopts `ap0`, shows it as a second Wi-Fi device in
your desktop menus, and interferes with hostapd.

```bash
sudo tee /etc/NetworkManager/conf.d/99-linux-hotspot.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:ap0
EOF
sudo systemctl reload NetworkManager
```

Then confirm NetworkManager is still healthy — a malformed file in `conf.d/`
stops it from starting and takes your network down with it:

```bash
systemctl is-active NetworkManager     # must print: active
```

---

## Step 7 — the systemd services

```bash
sudo install -m 0644 systemd/linux-hotspot.service        /etc/systemd/system/
sudo install -m 0644 systemd/linux-hotspot-resume.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable linux-hotspot-resume.service   # restores the AP after suspend
sudo systemctl enable --now linux-hotspot.service    # start now + at every boot
```

Check it:

```bash
systemctl status linux-hotspot --no-pager
```

Skip `enable` on `linux-hotspot.service` if you would rather start it by hand or
from the desktop toggle.

---

## Step 8 — toggle it without a password prompt

```bash
sudo install -m 0644 polkit/49-linux-hotspot.rules /etc/polkit-1/rules.d/
```

Test as your normal user — this should complete silently, with no dialog:

```bash
systemctl start linux-hotspot     # note: no sudo
systemctl stop linux-hotspot
```

---

## Step 9 — the GNOME quick-settings toggle (GNOME only)

```bash
UUID=linux-hotspot@jsticks779.github.io
mkdir -p ~/.local/share/gnome-shell/extensions/$UUID
cp gnome-extension/$UUID/* ~/.local/share/gnome-shell/extensions/$UUID/
gnome-extensions enable $UUID
```

If that last command says the extension does not exist, that is expected for a
brand-new one — the running shell only scans at login. Add it to the list
directly instead:

```bash
gsettings get org.gnome.shell enabled-extensions      # see the current list
gsettings set org.gnome.shell enabled-extensions "['existing@one', '$UUID']"
```

**Now log out and back in.** On Wayland there is no way to reload GNOME Shell in
place, and the extension will not appear until you do.

You should then have a Hotspot tile in the quick-settings menu, next to Wi-Fi.

---

## Verifying the whole thing

```bash
sudo linux-hotspot doctor        # every check should pass
sudo linux-hotspot status        # shows connected clients once a device joins
journalctl -u linux-hotspot -n 20 --no-pager
```

A good end-to-end test is to stop and start it a few times — driver races only
show up intermittently:

```bash
for i in $(seq 1 5); do
  sudo systemctl restart linux-hotspot
  iw dev ap0 info | awk '$1=="ssid"'
done
```

You should get five lines of your SSID.
