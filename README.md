# Hotspot on Linux

Turn a Linux machine into a Wi-Fi hotspot — **including the hard case: sharing
the same Wi-Fi connection your laptop is using for internet.**

Most guides tell you that a single Wi-Fi card cannot be a client and an access
point at the same time. Most cards actually can, and this project sets it up for
you: a second virtual interface on the same radio, pinned to the same channel as
your client link, with DHCP, DNS and NAT wired up behind it.

```
                    ┌──────────────── your laptop ────────────────┐
                    │                                             │
  ((( router )))────┼──▶ wlp2s0  (client, channel 149) ──┐         │
                    │                                    ├─ NAT ──▶ internet
   phone ───────────┼──▶ ap0     (hotspot, channel 149) ─┘         │
   tablet ──────────┤        one radio, two interfaces            │
                    └─────────────────────────────────────────────┘
```

---

## Install in one command

```bash
curl -fsSL https://raw.githubusercontent.com/jsticks779/Hotspot-on-linux/main/install.sh | sudo bash
```

It asks for a network name and a password, installs what is missing, and starts
the hotspot. That's it.

Prefer to pass everything up front (no questions asked):

```bash
curl -fsSL https://raw.githubusercontent.com/jsticks779/Hotspot-on-linux/main/install.sh \
  | sudo bash -s -- --ssid "MyHotspot" --password "supersecret"
```

Rather read the script before running it as root? Good instinct:

```bash
curl -fsSL -O https://raw.githubusercontent.com/jsticks779/Hotspot-on-linux/main/install.sh
less install.sh
sudo bash install.sh --ssid "MyHotspot" --password "supersecret"
```

Or clone and install from the checkout:

```bash
git clone https://github.com/jsticks779/Hotspot-on-linux.git
cd Hotspot-on-linux
sudo ./install.sh
```

Want to understand every step instead of running one command? That is written
out longhand in **[docs/MANUAL-INSTALL.md](docs/MANUAL-INSTALL.md)**.

---

## What you get

**A command.**

```bash
sudo linux-hotspot up        # start sharing
sudo linux-hotspot down      # stop
sudo linux-hotspot status    # what's running, who is connected
sudo linux-hotspot doctor    # can this machine do it? if not, why not
sudo linux-hotspot config --password 'new-password'
sudo linux-hotspot roam      # pause, join another Wi-Fi, come back on its channel
```

**A service**, so it comes back after a reboot and after suspend:

```bash
sudo systemctl enable --now linux-hotspot
```

**A GNOME toggle**, if you use GNOME — a Hotspot tile in the quick-settings
menu next to Wi-Fi and Bluetooth. One click on/off, no password prompt, and a
"Change password…" item in its menu.

> After installing on GNOME you must **log out and back in once**. GNOME Shell
> only scans for new extensions at login; on Wayland there is no way around it.

---

## Does my hardware support this?

Run this before anything else — it answers the question directly:

```bash
sudo linux-hotspot doctor
```

```
radio
✓ client interface: wlp2s0
✓ radio: phy0
✓ the card supports AP mode
✓ the driver runs an AP alongside the client link
    one channel only — the hotspot must sit on the client's channel
✓ connected on channel 149 — the hotspot will use the same channel
```

If it says the card does not advertise AP mode, no software can fix that — the
driver simply will not do it. See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)
for known-good chipsets and what to do with a card that refuses.

---

## The one rule you cannot escape

**A radio can only be on one channel at a time.**

When the internet you are sharing arrives over the same Wi-Fi card, the hotspot
*must* use the channel your client link is already on. This is physics, not a
limitation of this project, and your card says so itself:

```
$ iw phy phy0 info | grep -A2 "valid interface combinations"
    * #{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
      total <= 3, #channels <= 1        ← one channel for both
```

So the tool reads the channel off your client link at every start and follows
it. Join a different network — 2.4 GHz, 5 GHz, anything — and the next start
picks up the new channel automatically. Nothing to configure.

If your internet arrives some other way (ethernet, a USB tether, a second Wi-Fi
card), that restriction disappears and you can pick any channel you like:

```bash
sudo linux-hotspot config --channel 6
```

### Joining a different Wi-Fi network while the hotspot runs

The same rule has a consequence people hit immediately: **you cannot join a
network on another channel while the hotspot is up.** The radio is pinned to the
AP's channel, so the network shows up in the list, you enter the password, and
the connection quietly fails.

You do not have to do anything about it. A NetworkManager hook steps the hotspot
aside the moment the Wi-Fi link drops, and brings it back on whatever channel
you land on — so switching networks from the desktop menu just works. Verified
live: a machine hopped from a 5 GHz network on channel 149 to a 2.4 GHz one on
channel 1, and the hotspot followed on its own.

If you are not running NetworkManager, or you would rather drive it yourself:

```bash
sudo linux-hotspot roam
```

That pauses the hotspot, waits for you to connect to whatever you like, and
restarts it on the new channel.

---

## Configuration

Everything lives in `/etc/linux-hotspot/hotspot.conf`, and everything except the
name and password is detected automatically.

```ini
SSID=MyHotspot
PASSPHRASE=supersecret
SECURITY=wpa2          # wpa2 (works everywhere) | wpa3 | mixed

#STA_IFACE=wlan0       # the card providing internet   (auto)
#UPLINK_IFACE=eth0     # where the internet comes from (auto: the default route)
#AP_IFACE=ap0          # the virtual interface to create
#AP_MAC=02:11:22:33:44:55   # only if your driver refuses two interfaces sharing a MAC
#CHANNEL=6             # ignored when sharing Wi-Fi — that channel is not ours to pick
#COUNTRY=US            # regulatory domain (auto-detected from your card)
#IPV4_NET=10.42.0      # the hotspot subnet; the host takes .1
#DNS_SERVERS=1.1.1.1,8.8.8.8
#HIDDEN=0              # 1 to stop broadcasting the name
```

Change things with the CLI (it restarts the hotspot for you if it is running):

```bash
sudo linux-hotspot config --ssid "Cafe" --password "flatwhite" --security wpa3
sudo linux-hotspot config            # show the current settings
```

The file is group-writable by the desktop user on purpose — that is how the
GNOME password editor saves without asking for root. It is not world-readable.

---

## How it works

Six moving parts, each doing one job:

| Piece | Job |
|---|---|
| `iw` | creates `ap0`, a second virtual interface on the same radio |
| `hostapd` | speaks 802.11 on `ap0` — beacons, authentication, WPA2/WPA3 |
| `dnsmasq` | hands out addresses on `10.42.0.0/24` and forwards DNS |
| `iptables`/`nft` | masquerades hotspot traffic out through your uplink |
| `systemd` | starts, stops, survives reboot and suspend |
| NM dispatcher | steps the hotspot aside while you switch networks |
| polkit | lets you toggle it from the desktop without a password prompt, and blocks GNOME's own hotspot switch from hijacking the card |

The full walkthrough — why each choice was made, and the driver quirks that
forced them — is in **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)**.

---

## When something goes wrong

```bash
sudo linux-hotspot doctor                      # start here
journalctl -u linux-hotspot -n 30 --no-pager   # what the service actually did
sudo hostapd -d /run/linux-hotspot-hostapd.conf   # hostapd, loudly
```

Every failure this project has actually hit — and the fix — is written up in
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**, including:

- clients connect but have no internet
- "Device or resource busy" when starting
- the hotspot works, then dies after suspend
- you cannot join another Wi-Fi network while it is running
- someone used GNOME Settings' hotspot switch and broke everything
- GNOME shows a second "Wi-Fi (ap0)" device
- the toggle asks for a password every time

---

## Uninstall

```bash
sudo ./uninstall.sh            # keeps your settings
sudo ./uninstall.sh --purge    # removes them too
```

---

## Project layout

```
bin/linux-hotspot                    the whole tool, one shell script
install.sh / uninstall.sh            the one-command installer and its inverse
systemd/linux-hotspot.service        start/stop/boot
systemd/linux-hotspot-resume.service bring it back after suspend
polkit/49-linux-hotspot.rules        toggle without a password prompt
polkit/50-linux-hotspot-no-nm-share.rules  stop GNOME's own hotspot breaking it
networkmanager/50-linux-hotspot      follow the client link onto new channels
gnome-extension/                     the quick-settings tile
docs/                                the long-form documentation
```

## Requirements

- Linux with a Wi-Fi card whose driver supports AP mode (most do — check with `doctor`)
- `hostapd`, `dnsmasq`, `iw` — the installer fetches these for you
- `iptables` or `nftables` for internet sharing
- systemd for the service and the desktop toggle (the CLI works without it)

Tested on Ubuntu 24.04 with an Intel Wireless-AC 9260 and GNOME 46. Built to be
distribution-agnostic; see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for
what that means in practice.

## License

MIT — see [LICENSE](LICENSE).
