# Compatibility

## Check your own machine first

Do not guess from a table — ask the driver:

```bash
sudo linux-hotspot doctor
```

Or by hand:

```bash
iw phy | grep -A10 "Supported interface modes"        # want to see: * AP
iw phy phy0 info | grep -A3 "valid interface combinations"
```

Three possible answers:

| What you see | What it means |
|---|---|
| `* AP` present, and a combination listing `AP` next to `managed` | Everything works, including sharing your Wi-Fi connection. |
| `* AP` present, but no combination pairs it with `managed` | AP mode works, but not while connected as a client. Use it with an ethernet or tethered uplink. |
| No `* AP` at all | This driver cannot be an access point. Nothing in software fixes it. |

If you see `#channels <= 1` in the combination, the hotspot has to share your
client link's channel. That is the common case and is handled automatically.

---

## Wi-Fi chipsets

Verified by the project:

| Chipset | Driver | Result |
|---|---|---|
| Intel Wireless-AC 9260 | `iwlwifi` | Works, including Wi-Fi → Wi-Fi on one radio. Needs the explicit AP-mode fix-up the tool applies. |

Expected to work, based on driver capabilities (untested here — reports
welcome):

| Family | Driver | Notes |
|---|---|---|
| Intel AX200 / AX201 / AX210 | `iwlwifi` | Same driver and quirks as the 9260. |
| Intel 7260 / 8260 / 9560 | `iwlwifi` | Same family. |
| Atheros ath9k (AR9xxx) | `ath9k` | Historically the best AP-mode support on Linux. |
| Atheros ath10k / ath11k | `ath10k`, `ath11k` | Good AP support; concurrency varies by firmware. |
| MediaTek MT7921 / MT7922 | `mt76` | AP mode works. Some versions need a distinct MAC — set `AP_MAC=`. |
| Realtek RTL8822/8852 | `rtw88`, `rtw89` | AP mode works on recent kernels; older out-of-tree drivers often do not. |
| Broadcom | `brcmfmac` | Mixed. Many consumer chips do AP mode; the `wl` proprietary driver generally does not. |

Known difficult:

- **Broadcom `wl` (`broadcom-sta`)** — no AP mode. Switch to `brcmfmac` if your
  chip supports it, or use a USB adapter.
- **Old Realtek out-of-tree drivers** (`8188eu`, `8821au` and friends) — AP mode
  is often broken or absent even when advertised.
- Anything where `iw phy` does not list `* AP`.

A cheap USB adapter with an `ath9k_htc`, `mt7601u` or `rtl8812au` chipset is the
usual escape hatch, and it also removes the same-channel restriction because the
hotspot then has its own radio.

---

## Distributions

The tool is plain POSIX-ish shell plus `iw`, `hostapd`, `dnsmasq` and
`iptables`/`nft`. The installer knows these package managers:

| Distribution | Package manager | Status |
|---|---|---|
| Ubuntu 24.04 | `apt` | Tested end to end |
| Kali Rolling (kernel 6.19) | `apt` | Tested end to end |
| Debian, Mint, Pop!_OS, elementary | `apt` | Same packages and paths; expected to work |
| Fedora, RHEL, CentOS, Rocky | `dnf` / `yum` | Expected to work; see the firewalld note below |
| Arch, Manjaro, EndeavourOS | `pacman` | Expected to work |
| openSUSE | `zypper` | Expected to work |
| Alpine | `apk` | CLI works; no systemd, so no service or desktop toggle |

Being honest about "expected to work": the code paths are there and the commands
are standard, but only Ubuntu 24.04 and Kali Rolling have been run end to end —
both `apt`-based. The `dnf`, `pacman`, `zypper` and `apk` branches are written
from documented behaviour and have not been executed. If you try another
distribution, `sudo linux-hotspot doctor` plus an issue report is genuinely
useful.

The Kali run is worth noting because nothing about it was hard-coded: its
wireless interface is `wlan0` rather than `wlp2s0`, and detection picked it up
without any configuration.

### Distribution-specific notes

**Fedora / RHEL — firewalld.** firewalld manages the firewall and may override
the rules this tool installs. If clients connect but get no internet:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=ap0
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --reload
```

**Arch — iptables vs nftables.** Arch ships `iptables-nft`, which is fine. If
you have neither `iptables` nor `nft`, install one or the hotspot will carry no
traffic.

**Alpine and other non-systemd systems.** `linux-hotspot up` / `down` work
normally; the systemd unit, the resume hook and the polkit rule do not apply.
Wire `up` into OpenRC or run it by hand.

**Debian.** Installing `hostapd` enables a system-wide service; the installer
disables it (this project runs its own instance). If you install manually, do
`sudo systemctl disable --now hostapd` yourself.

---

## Desktop integration

| Desktop | Toggle |
|---|---|
| GNOME 45–49 | Quick-settings tile, tested on GNOME 46 |
| GNOME 44 and older | Not supported — the quick-settings API predates 45 |
| KDE, XFCE, Cinnamon, others | No tile yet; the CLI and `systemctl` work fine |

The extension is ES-module based, which is why GNOME 45 is the floor: the shell
switched its internals to ES modules in that release and older extension APIs
are gone.

For non-GNOME desktops, a `.desktop` launcher or a panel command running
`systemctl start linux-hotspot` gives you the same one-click behaviour (the
polkit rule means it will not prompt).

---

## Regulatory domains

hostapd needs a country code to know which channels and power levels are legal.
The tool reads yours from the card:

```bash
iw reg get
```

If that reports `country 00` (the world-wide fallback), 5 GHz will be limited.
Set yours explicitly:

```bash
sudo linux-hotspot config --country TZ      # your own two-letter code
```

When sharing a Wi-Fi connection the country code rarely needs setting by hand —
but it decides something important: **which channels you may host on at all.**

Most countries mark part of the 5 GHz band "no IR" (no initiating radiation):
the card may join a network there but not create one. Since the hotspot has to
share your client link's channel, being connected to such a network makes the
hotspot impossible until you move to another one. `doctor` reports this and
lists the channels your card can host on:

```
✗ channel 36 is receive-only under TZ regulations
    channels this card can host on: 1 2 3 ... 11 12 13 149 153 157 161
```

Usually 2.4 GHz and the upper 5 GHz band (channel 149 and above) are free while
channels 36-64 and all DFS channels are not. If your router broadcasts both
bands, joining the 2.4 GHz one is the quickest way through.

Cards with a *self-managed* regulatory domain (most iwlwifi) carry their own,
which overrides the system setting — compare `iw reg get` with
`iw phy phy0 reg get`. The tool reads the card's, because that is the one
enforced.
