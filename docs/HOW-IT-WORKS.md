# How it works

This is the long version: what actually happens between clicking the toggle and
a phone getting an IP address, and why each piece is the way it is. Nearly every
design decision here was forced by a real failure — those are called out as they
come up.

---

## 1. The constraint everything else follows from

A Wi-Fi card has one radio. A radio can be tuned to exactly one channel at a
time. That single sentence explains the whole design.

When your laptop is connected to a network on channel 149 and you want it to
*also* be an access point, that access point has to be on channel 149 too. There
is no clever software that avoids this — the hardware cannot be in two places
at once.

Your driver states this in machine-readable form:

```
$ iw phy phy0 info | grep -A2 "valid interface combinations"
    * #{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
      total <= 3, #channels <= 1
```

Read it as: *one client interface, plus one AP interface, plus a P2P device —
three interfaces total, but all sharing **one channel**.*

So `linux-hotspot up` reads the channel off the client link every single time it
starts:

```bash
iw dev wlp2s0 info | awk '$1=="channel"{print $2}'
```

and hands that number to hostapd. Join a different network tomorrow and the next
start follows it. Nothing is hard-coded, and nothing needs reconfiguring.

**The exception:** if your internet arrives over ethernet, a USB tether, or a
second Wi-Fi card, the radio is yours alone and any channel will do. The tool
detects this by comparing the default route's interface against the Wi-Fi
client interface, and only then honours a `CHANNEL=` setting.

---

## 2. A second interface on the same radio

We never touch your existing connection. Instead we ask the radio for a second
virtual interface in AP mode:

```bash
iw phy phy0 interface add ap0 type __ap
```

Your `wlp2s0` keeps its association, its IP, its NetworkManager profile. `ap0`
is a separate netdev on the same hardware.

> **Quirk 1 — the type is a suggestion.** iwlwifi (and others) frequently hand
> back an interface in `managed` mode even though `type __ap` was requested. If
> you then start hostapd on it, hostapd tries to fix the mode itself, races the
> driver, and fails. The tool checks the result and forces it:
>
> ```bash
> ip link set ap0 down
> iw dev ap0 set type __ap      # retried a few times; the driver needs it down
> ```
>
> and refuses to continue unless `iw dev ap0 info` really says `type AP`.

> **Quirk 2 — some drivers want a distinct MAC.** By default `ap0` inherits the
> card's address, which is fine on iwlwifi. Drivers that object (some mt76 and
> rtw88 versions refuse the second interface) need a locally-administered
> address instead: set `AP_MAC=02:...` in the config.

---

## 3. hostapd: being an access point

`hostapd` does the actual 802.11 work on `ap0` — beacons, association, the WPA
handshake. Its config is generated fresh at every start into
`/run/linux-hotspot-hostapd.conf`, because the channel is only known at that
moment.

```ini
interface=ap0
driver=nl80211
ssid=MyHotspot
hw_mode=a            # 'g' below 3 GHz, 'a' above
channel=149          # read off the client link
ieee80211n=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=...
```

> **Quirk 3 — why 20 MHz and not 40.** Asking for HT40 (`ht_capab=[HT40+]`) is
> free bandwidth in theory. In practice hostapd must first run a *coexistence
> scan* to check the neighbouring channel is clear — and a scan needs the radio,
> which the client link is also using. The result:
>
> ```
> Could not set interface ap0 flags (UP): Device or resource busy
> Failed to request a scan of neighbouring BSSes ret=-16 (Device or resource busy)
> ```
>
> Roughly one start in five failed this way. hostapd has a `noscan=1` option to
> skip it, but Ubuntu's hostapd 2.10 is not built with it (`unknown
> configuration item 'noscan'`). So the AP runs at 20 MHz deliberately. When you
> are re-sharing a Wi-Fi link, the uplink is the bottleneck anyway.

> **Quirk 4 — `hostapd -B` lies.** With `-B` hostapd forks into the background
> *before* it has finished bringing the radio up. It returns exit status 0 and
> then dies a second later. An early version of this project trusted that exit
> code and cheerfully reported a working hotspot that did not exist.
>
> The only honest test is asking the interface whether it is advertising a
> network:
>
> ```bash
> iw dev ap0 info | grep '^\s*ssid '
> ```
>
> The tool polls that for up to six seconds, and treats a pid file pointing at a
> dead process as definite failure.

> **Quirk 5 — the radio is busy sometimes, and that's normal.** NetworkManager
> scans in the background on your client link. If a scan is in flight when we
> bring `ap0` up, we get `EBUSY`. It is transient, so hostapd is retried up to
> four times with the interface taken down in between. In testing this absorbed
> six failures across twenty start/stop cycles without the user ever seeing one.

---

## 4. dnsmasq: addresses and names

Clients need an IP, a gateway, and a DNS server. `dnsmasq` provides all three,
bound to `ap0` only:

```bash
dnsmasq --interface=ap0 --bind-interfaces --except-interface=lo \
        --dhcp-range=10.42.0.10,10.42.0.100,255.255.255.0,12h \
        --dhcp-option=3,10.42.0.1 --dhcp-option=6,10.42.0.1 \
        --no-resolv --server=1.1.1.1 --server=8.8.8.8
```

`--bind-interfaces` matters: without it dnsmasq listens on every interface and
collides with `systemd-resolved` on port 53.

We run our **own** instance with our own pid file rather than using the
distribution's `dnsmasq.service`, and the installer switches that system service
off. Sharing the packaged service means fighting over `/etc/dnsmasq.conf`,
starting DNS for the whole machine, and racing at boot over an interface that
does not exist yet. A private instance sidesteps all of it.

`--no-resolv` with explicit upstreams avoids depending on whatever
`/etc/resolv.conf` happens to be — a stub resolver, a VPN, a captive portal.

---

## 5. NAT: actually reaching the internet

Traffic arriving on `ap0` has to be forwarded out of the uplink and translated:

```bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o wlp2s0 -j MASQUERADE
iptables -I FORWARD 1 -i ap0 -o wlp2s0 -j ACCEPT
iptables -I FORWARD 1 -i wlp2s0 -o ap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -A FORWARD -o wlp2s0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Details worth knowing:

- Rules are **inserted at the top** of `FORWARD`, not appended. Docker sets the
  `FORWARD` policy to `DROP` and installs its own chains; appending can land
  behind them.
- The MSS clamp prevents the classic "small pages load, big ones hang" symptom
  when the uplink has a reduced MTU (common on tethers and VPNs).
- On systems without `iptables`, the same rules are expressed in `nft` inside a
  dedicated `linux_hotspot` table, so teardown is one `nft delete table`.
- The previous value of `ip_forward` is saved and restored on `down`, so we
  don't silently leave routing enabled on a machine that had it off.

Every rule is added idempotently (`-C` first, or delete-then-recreate for nft)
and removed on `down` — no residue accumulating across restarts.

---

## 6. systemd: lifecycle

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/linux-hotspot up
ExecStop=/usr/local/bin/linux-hotspot down
TimeoutStartSec=90
```

`oneshot` + `RemainAfterExit` fits: `up` starts two daemons and exits, and the
unit stays "active" to represent them.

> **Quirk 6 — boot is a race.** An earlier version failed on every boot with
> `command failed: No such file or directory` from `iw phy phy0`. The service
> was starting before the Wi-Fi driver had registered the radio at all. Two
> fixes: order after `NetworkManager.service`, and have `up` wait (up to 25
> seconds) for the client interface to actually associate before doing anything.
> The phy is also looked up dynamically now instead of assuming `phy0`.

> **Quirk 7 — suspend kills it.** Waking from suspend resets the radio, and the
> client link may reconnect on a *different channel* — which the AP must follow.
> `linux-hotspot-resume.service` is hooked to `suspend.target` and restarts the
> hotspot on wake, but only if it was running when you closed the lid.

`up` is idempotent: starting an already-running hotspot logs "already running"
and exits 0, and any leftovers from a crash are cleaned up before a fresh start.
Without that, systemd and a hand-typed command can trip over each other.

---

## 7. NetworkManager: staying out of the way

NetworkManager sees `ap0` appear and tries to manage it — it shows up as a
second "Wi-Fi" device in the GNOME menu, and NM's own ideas about scanning and
autoconnect start interfering with hostapd. One file prevents all of it:

```ini
# /etc/NetworkManager/conf.d/99-linux-hotspot.conf
[keyfile]
unmanaged-devices=interface-name:ap0
```

> A warning from experience: NetworkManager **refuses to start at all** if a
> file in `conf.d/` cannot be parsed, and a broken one takes your whole network
> with it. If you hand-edit these, check `systemctl status NetworkManager`
> afterwards.

### Following you onto a new network

The channel rule has a sharp edge: while the AP holds the radio, the client
cannot associate with a network on any *other* channel. Joining a different
Wi-Fi simply fails, and the only way through is to stop the hotspot first.

A dispatcher script makes that automatic:

```sh
# /etc/NetworkManager/dispatcher.d/50-linux-hotspot
case "$ACTION" in
    pre-down|down) # free the radio, remember we did
        systemctl is-active --quiet linux-hotspot.service && \
            { touch /run/linux-hotspot.autopaused; systemctl stop linux-hotspot.service; } ;;
    up)            # come back, on whatever channel we landed on
        [ -e /run/linux-hotspot.autopaused ] && \
            { rm -f /run/linux-hotspot.autopaused; systemctl --no-block start linux-hotspot.service; } ;;
esac
```

Switching networks from the desktop produces exactly that down-then-up pair, so
the whole dance happens without anybody asking for it. The flag file matters:
without it, a hotspot you switched off deliberately would come back on by itself
the next time any Wi-Fi connected.

The `down` case is stopped **synchronously** — the radio has to be genuinely free
before NetworkManager attempts the next association — while `up` starts with
`--no-block` so a slow start cannot stall the dispatcher queue. Only wireless
interfaces are considered, so an ethernet cable coming and going never disturbs
an access point that is happily serving clients.

Tested live on the 9260: the machine left a 5 GHz network on channel 149,
joined a 2.4 GHz one on channel 1, and the hotspot came back on channel 1 by
itself. `linux-hotspot roam` does the same thing on demand for people who are
not running NetworkManager.

### Why not just use NetworkManager's own hotspot?

GNOME Settings has a "Turn On Wi-Fi Hotspot" switch, and `nmcli device wifi
hotspot` exists. Both reconfigure **your existing Wi-Fi interface** into an
access point — which disconnects you from the network whose internet you were
trying to share. They are the right tool when your uplink is ethernet, and
useless for the Wi-Fi-to-Wi-Fi case this project exists for.

---

## 8. polkit: a toggle that doesn't nag

Starting a system service from a desktop session normally raises an
authentication dialog. One rule scoped to exactly one unit removes it:

```javascript
polkit.addRule(function (action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "linux-hotspot.service" &&
        subject.active &&
        (subject.isInGroup("sudo") || subject.isInGroup("wheel"))) {
        return polkit.Result.YES;
    }
});
```

It is deliberately narrow: one unit, only for a user who is physically logged in
(`subject.active`) and already able to use `sudo`. Anyone who qualifies could
run the same command with `sudo` anyway, so no new privilege is granted — only
the prompt is skipped.

---

## 9. The GNOME extension

A `QuickMenuToggle` in the quick-settings grid. Clicking it runs `systemctl
start`/`stop` (allowed by the polkit rule above); a 5-second poll of `systemctl
is-active` keeps the tile honest if the hotspot is changed from a terminal. The
menu's "Change password…" opens a dialog that rewrites the `PASSPHRASE=` line in
the config file and restarts the service if it is running — which is why the
installer makes that file group-writable by the desktop user. The extension
never needs root.

> **Quirk 8 — GNOME 45 changed everything.** Shell internals are ES modules now.
> Extensions must use `import ... from 'resource:///org/gnome/shell/ui/*.js'`,
> `import * as Main` (main.js has no default export), and every widget subclass
> must go through `GObject.registerClass`. Legacy `imports.ui.*` code fails with
> a bare `SyntaxError` pointing inside GNOME's own files.

> **Quirk 9 — you cannot reload an extension on Wayland.** The shell scans the
> extensions directory once, at login, and caches the result — including
> failures. `gnome-extensions disable && enable` will not re-import edited code,
> and the D-Bus `ReloadExtension` method answers *"deprecated and does not
> work"*. Only logging out picks up changes.
>
> That makes blind edits expensive, so test in a throwaway shell instead:
>
> ```bash
> timeout 20 dbus-run-session -- gnome-shell --headless --virtual-monitor 1280x720 > log 2>&1
> grep -i extension log
> ```
>
> It uses the same extensions directory and reports the same errors, without
> touching your session.

> **Quirk 10 — enabling a brand-new extension.** `gnome-extensions enable` asks
> the running shell, which has never heard of a just-installed extension and
> refuses. The installer falls back to appending the UUID to the
> `org.gnome.shell enabled-extensions` list directly, so it is enabled and ready
> the moment you log back in.

---

## The complete path of one packet

A phone loads a web page:

1. Phone associates with `ap0`; hostapd runs the WPA handshake.
2. Phone broadcasts DHCP DISCOVER; dnsmasq leases it `10.42.0.37`, gateway and
   DNS `10.42.0.1`.
3. Phone asks `10.42.0.1` to resolve a name; dnsmasq forwards to `1.1.1.1` and
   caches the answer.
4. Phone sends a packet to that address via `10.42.0.1`.
5. The kernel forwards it (`ip_forward=1`), the `FORWARD` rules permit it.
6. `MASQUERADE` rewrites the source to your laptop's Wi-Fi address.
7. It leaves over `wlp2s0` — the same radio the phone is talking to, one channel,
   time-sliced by the hardware.
8. The reply comes back, conntrack matches it, the `RELATED,ESTABLISHED` rule
   lets it through, NAT rewrites the destination, and it goes out `ap0`.
