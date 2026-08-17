# Troubleshooting

Start here, always:

```bash
sudo linux-hotspot doctor
journalctl -u linux-hotspot -n 30 --no-pager
```

If hostapd is the problem, ask it directly — this prints the real reason:

```bash
sudo linux-hotspot up          # generates the config
sudo hostapd -d /run/linux-hotspot-hostapd.conf
```

---

## The hotspot will not start

### `command failed: No such device (-19)` / `could not create ap0`

The card refused to make a second interface. Usually one of:

- **The driver has no AP mode.** Check with `iw phy | grep -A10 "Supported
  interface modes"`. If `* AP` is absent, no configuration can help — see
  [COMPATIBILITY.md](COMPATIBILITY.md).
- **A stale `ap0` is already there.** `sudo iw dev ap0 del` and try again.
  (Note that `ip link delete ap0` does *not* work for wireless interfaces —
  it answers "Operation not supported". Use `iw`.)
- **The driver wants a distinct MAC** for the second interface. Set a
  locally-administered address in `/etc/linux-hotspot/hotspot.conf`:
  ```ini
  AP_MAC=02:11:22:33:44:55
  ```

### `Could not set interface ap0 flags (UP): Device or resource busy`

The radio was busy with something else — almost always a background scan on your
client link — at the moment we tried to bring the AP up. This is transient and
the tool already retries four times. If it fails all four:

```bash
sudo systemctl stop linux-hotspot
nmcli radio wifi off && sleep 2 && nmcli radio wifi on   # settle the radio
sudo systemctl start linux-hotspot
```

Persistent cases are usually a second thing driving the radio — `wpa_supplicant`
running outside NetworkManager, or another hotspot tool (`create_ap`, `nmcli
device wifi hotspot`) still holding an interface.

### `ap0 would not switch into AP mode`

The interface was created but stayed in `managed` mode. The tool takes it down
and retries five times before giving up, so this means the driver is genuinely
refusing. Check whether something re-adopted the interface:

```bash
nmcli device status | grep ap0      # should say "unmanaged"
```

If it isn't unmanaged, the NetworkManager config from step 6 of the manual
install is missing or was not reloaded.

### `hostapd did not come up on channel N`

hostapd started and then died. Run it in the foreground to see why:

```bash
sudo hostapd -d /run/linux-hotspot-hostapd.conf
```

Common causes:

- **An illegal channel for your regulatory domain.** `iw reg get` shows your
  country; some channels are DFS or forbidden. When sharing Wi-Fi the channel is
  inherited from a link that is already legal, so this mostly bites in
  ethernet-uplink mode. Try `sudo linux-hotspot config --channel 6`.
- **A wrong country code.** Set it explicitly: `sudo linux-hotspot config
  --country TZ` (use your own two-letter code).
- **`unknown configuration item 'noscan'`** — you are on an older copy of this
  project. Current versions do not use `noscan`; update.

### `channel N is receive-only under XX regulations`

Your country's rules let the card *join* a network on that channel but never
*start* one. The kernel marks such channels `no IR` — no initiating radiation —
and hostapd refuses them outright:

```
Frequency 5180 (primary) not allowed for AP mode, flags: 0x30053 NO-IR
Could not select hw_mode and channel. (-3)
```

Because the hotspot must share your client link's channel, this means **the
hotspot cannot run while you are connected to a network on that channel.** It is
a legal restriction, not a fault, and no setting bypasses it.

See exactly which channels your card may host on:

```bash
sudo linux-hotspot doctor       # names them when the current channel is blocked
iw phy phy0 info | grep -E "MHz \[" | grep -v "no IR"
```

In many countries the lower 5 GHz band (channels 36-64) and all DFS channels are
receive-only, while 2.4 GHz and the upper 5 GHz band (149+) are free. A concrete
example, Tanzania:

```
5170-5250 (ch 36-48)     PASSIVE-SCAN → no IR → AP forbidden
5250-5730 (ch 52-144)    DFS          → no IR → AP forbidden
5735-5815 (ch 149-163)   clean               → AP allowed
2402-2482 (ch 1-13)      clean               → AP allowed
```

So the fix is to put your uplink on a channel that permits hosting — join the
2.4 GHz network instead of its 5 GHz twin, or a 5 GHz network on channel 149 or
above. Many routers broadcast both bands under the same or similar names.

Note that the card may report a *different* regulatory domain from the system:
`iw reg get` shows the global one, while `iw phy phy0 reg get` shows the card's
own self-managed domain, which is the one actually enforced.

### The service failed at boot but works when started by hand

The radio was not ready yet. The current service waits up to 25 seconds for the
client link to associate and orders itself after NetworkManager. If your Wi-Fi
takes longer than that to connect (slow DHCP, enterprise auth), raise the wait
or just start it from the desktop toggle instead of at boot:

```bash
sudo systemctl disable linux-hotspot
```

---

## Installing broke DNS on the machine itself

Symptom: partway through installation, or right after it, the machine can no
longer resolve names — `curl` reports `Could not resolve host`, apt fails, the
browser stops working.

Cause: the full `dnsmasq` package (as opposed to `dnsmasq-base`) is a
*system-wide DNS daemon*. On Debian-family systems its postinst starts it the
moment it is installed, and it takes port 53. Depending on how the machine
resolves names, that can knock DNS out instantly.

Fix:

```bash
sudo systemctl disable --now dnsmasq
sudo systemctl restart NetworkManager      # or: systemctl restart systemd-resolved
getent hosts github.com                    # should print an address again
```

Current versions of the installer avoid this entirely: on Debian-family systems
they install `dnsmasq-base` (just the binary this project runs itself), guard the
install with `policy-rc.d` so no packaged daemon starts, and check that name
resolution still works afterwards. If you are following the manual instructions,
install `dnsmasq-base`, never `dnsmasq`.

You can leave the full `dnsmasq` package installed once its service is disabled —
the hotspot uses the binary directly and never touches that service.

---

## Devices connect, but there is no internet

This is a routing problem, not a Wi-Fi problem. Work down the list:

```bash
# 1. Does the client have an address? (run on the laptop)
sudo linux-hotspot status          # shows DHCP leases

# 2. Is forwarding on?
sysctl net.ipv4.ip_forward         # must be 1

# 3. Is the NAT rule there?
sudo iptables -t nat -S POSTROUTING | grep 10.42.0

# 4. Is something dropping forwarded traffic?
sudo iptables -S FORWARD | head
```

**Docker is the usual culprit.** It sets the `FORWARD` policy to `DROP`. This
project inserts its rules at the top of the chain to survive that, but if you
have your own firewall rules or a tool like `ufw`, check them:

```bash
sudo ufw status                    # if active, allow forwarding on ap0
```

**firewalld** (Fedora, RHEL) manages its own rules and may drop ours. Add the
interface to the trusted zone and enable masquerading:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=ap0
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --reload
```

**DNS only.** If addresses resolve on the laptop but not on the phone, the
upstream DNS servers may be blocked by the network you are re-sharing. Point
dnsmasq at the network's own resolver:

```ini
# /etc/linux-hotspot/hotspot.conf
DNS_SERVERS=192.168.1.1
```

**Pages load slowly or large ones hang.** An MTU problem on the uplink. The MSS
clamp normally handles it; if the uplink is a VPN, lower the clamp by hand or
reduce the MTU on `ap0`.

---

## I cannot join another Wi-Fi network while the hotspot is on

You can see the network, the password is right, and it still will not connect.
Switch the hotspot off, connect, switch it back on — and it works.

That is the single-radio rule, not a fault. While the hotspot runs, the radio is
pinned to the AP's channel, and the card cannot associate with a network on a
different one. Your own hardware says so:

```bash
iw phy phy0 info | grep -A2 "valid interface combinations"
#   ... #{ managed } <= 1, #{ AP, ... } <= 1, total <= 3, #channels <= 1
#                                                          ^^^^^^^^^^^^^
```

Current versions handle it for you. A NetworkManager dispatcher hook at
`/etc/NetworkManager/dispatcher.d/50-linux-hotspot` pauses the hotspot when the
Wi-Fi link goes down and restarts it once you are connected again — on the new
channel. Switching networks from the desktop produces exactly that down-then-up
pair, so it happens by itself.

If you are not using NetworkManager, drive it manually:

```bash
sudo linux-hotspot roam        # pauses, waits for you to connect, comes back
```

To check the hook is in place:

```bash
ls -l /etc/NetworkManager/dispatcher.d/50-linux-hotspot   # must be root-owned, executable
```

NetworkManager silently ignores dispatcher scripts that are group- or
world-writable. Delete the file if you would rather the hotspot never paused
itself.

---

## It works, then stops

### After suspend

Expected — waking resets the radio, and the client link can even come back on a
different channel. `linux-hotspot-resume.service` handles this. Confirm it is
enabled:

```bash
systemctl is-enabled linux-hotspot-resume
sudo systemctl enable linux-hotspot-resume
```

### After changing Wi-Fi networks

The AP has to move to the new channel, which means a restart:

```bash
sudo systemctl restart linux-hotspot
```

### The service says "active" but nothing is broadcasting

If hostapd is killed from outside, systemd does not notice — the unit is
`oneshot` and keeps its "active" state. Reality check and fix:

```bash
iw dev ap0 info | grep ssid                 # nothing? then it is really down
sudo systemctl restart linux-hotspot
```

---

## Desktop problems

### There is no Hotspot tile in quick settings

Ask `doctor` first — it knows the difference between "not installed", "failed to
load" and "installed, but your session is older than the install":

```bash
sudo linux-hotspot doctor        # look at the "integration" section
```

1. **Did you log out and back in *after* installing?** GNOME Shell only scans
   for extensions at login, and on Wayland there is no way to reload it in
   place. Installing while already logged in — which is what everybody does —
   means the tile cannot appear until the next login. This is the answer nine
   times out of ten, and `doctor` says so explicitly when it applies.

   Note that locking and unlocking the screen is *not* enough; the `gnome-shell`
   process itself has to restart. If you are unsure whether it did:

   ```bash
   ps -o lstart= -C gnome-shell     # when the shell actually started
   ```
2. Check it is enabled and healthy:
   ```bash
   gnome-extensions info linux-hotspot@jsticks779.github.io
   ```
   `State: ERROR` means it failed to load — see the error with:
   ```bash
   journalctl --user -b 0 | grep -i "linux-hotspot@"
   ```
3. Check your GNOME version is supported (45+):
   ```bash
   gnome-shell --version
   ```

> Note that `State: ERROR` is cached for the whole session. After fixing
> anything, you must log out again — `gnome-extensions disable && enable` will
> not re-import the code, and `ReloadExtension` over D-Bus answers "deprecated
> and does not work".

### The toggle asks for a password every time

The polkit rule is missing or does not apply to you:

```bash
ls -l /etc/polkit-1/rules.d/49-linux-hotspot.rules
id | grep -E 'sudo|wheel'          # the rule covers these groups
journalctl -u polkit -n 20 --no-pager
```

### GNOME shows a second "Wi-Fi (ap0)" device

NetworkManager is managing the AP interface. Add the config and reload:

```bash
cat /etc/NetworkManager/conf.d/99-linux-hotspot.conf
sudo systemctl reload NetworkManager
nmcli device status | grep ap0     # want: unmanaged
```

### NetworkManager will not start at all

A file in `/etc/NetworkManager/conf.d/` is malformed. This takes down all
networking, so it looks alarming, but the fix is quick:

```bash
journalctl -u NetworkManager -n 20 --no-pager
```

Look for `Failed to read configuration`. It names the offending file and line.
Fix or delete that file, then `sudo systemctl start NetworkManager`.

---

## Turning it all off

```bash
sudo systemctl disable --now linux-hotspot
sudo linux-hotspot down          # removes ap0 and the firewall rules
```

If something is really stuck:

```bash
sudo pkill -F /run/linux-hotspot-hostapd.pid
sudo pkill -F /run/linux-hotspot-dnsmasq.pid
sudo iw dev ap0 del
```

> Do not reach for `sudo pkill -f linux-hotspot` — the pattern matches the shell
> running the command, and you will kill your own terminal. Use the pid files.

---

## Still stuck?

Collect this and open an issue at
<https://github.com/jsticks779/Hotspot-on-linux/issues>:

```bash
sudo linux-hotspot doctor
iw phy phy0 info | head -40
journalctl -u linux-hotspot -n 50 --no-pager
uname -a; cat /etc/os-release | head -2
```
