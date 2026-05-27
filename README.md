# Raspberry Pi 5 Capture Platform

Setup scripts and systemd units for a mobile V2X capture box built on a Pi 5
with an external Atheros 802.11p WiFi card. Records raw IEEE 802.11p ITS-G5
traffic in OCB mode, plus GPS, BT and regular WLAN beacons on the side.
Intended as the field hardware for Build Stage 1 of the CITES project; the
data it produces is analyzed by [CITES](https://github.com/WernersGit/CITES)


## Quickstart

Fresh Raspberry Pi OS Bookworm install (64-bit), all scripts and the
`environment` file in the same directory, then as root:

    sudo bash car2x-00-master-setup.sh

The orchestrator runs nine phases. Most are idempotent so re-running after a
failure is fine. A resume option is built in:

    sudo bash car2x-00-master-setup.sh --resume 4   # pick up at phase 4
    sudo bash car2x-00-master-setup.sh --dry-run -v # just show what would happen

Status is kept in `/var/lib/car2x/setup-status.json`. Total runtime is roughly
15 minutes on a Pi 5 8GB, dominated by the kernel checkout and driver build in
phases 3 and 4. Reboot at the end. Most config only takes effect after that.

The phases:

    1. system prep      apt update/upgrade, build deps, EEPROM PSU rating
    2. user + dirs      car2x user, groups, /home/car2x, base udev rule
    3. kernel patch     clone rpi-linux, checkout rpi-6.12.y, apply 11p patch
    4. driver build     ath9k modules, wireless-regdb, CRDA
    5. peripherals      USB device discovery, stable udev names, WLAN naming,
                        USB archive disk selection
    6. GPS              gpsd + optional Chrony NTP refclock via gpsd SHM
    7. Pico             placeholder, currently exits early (see Caveats)
    8. BT + WLAN beac.  tooling and permissions for monitor-mode sniffing
    9. service deploy   copies runtime scripts + units, enables services


## Hardware

- Raspberry Pi 5
- Atheros AR9XX PCIe WiFi card (ath9k driver) for the 802.11p side -> https://github.com/jfpastrana/802.11p/blob/master/Documentation/Wireless_cards.pdf
- GT-U7 GNSS USB module for GPS, runs at 115200 baud (optional)
- microSD >=64 GB, plus an optional USB stick or HDD for trip archives
- Optionally a Raspberry Pi Pico over USB serial (handler is a placeholder
  right now)

The internal Broadcom chip (brcmfmac, renamed to `wlan1` by udev) is used for
WLAN beacon sniffing only. The external AR9300 (`wlan0`) does the actual
802.11p RX.


## Why the kernel patch

Stock Linux has OCB support in mac80211 but the ath9k driver does not enable
it the way ITS-G5 needs out of the box. The patch comes from HPI Potsdam,
applied to the Pi kernel branch `rpi-6.12.y`:

  https://gitlab.com/hpi-potsdam/osm/g5-on-linux/11p-on-linux

It enables OCB (Outside the Context of a BSS) mode, ITS-G5 Band A at 5900 MHz
with 10 MHz bandwidth, and a regulatory domain via patched CRDA +
wireless-regdb. Phase 4 builds all of it. On my Pi 5 the ath9k step took ~8
minutes, the regdb + CRDA another minute or two.


## Runtime services

Once setup is done and the box has rebooted, these run automatically on every
boot.

Always-on:

- `car2x-startup`              creates the trip folder, exports
                               `CAR2X_DRIVE_PATH`, unblocks WiFi via rfkill
- `car2x-ocb-setup`            loads the custom ath9k modules, puts wlan0 into
                               OCB at 5900 MHz, brings up `mon0`
- `car2x-dumpcap`              capture on `mon0` (so we keep radiotap headers)
                               into `car2x.pcapng` with 100 MB rotation
- `car2x-sysmon`               cpu temp, load, RAM every 10s into `sysMon.csv`
- `car2x-storage-monitor.timer`  daily 02:00 UTC, alert-only, no deletion

Optional, toggled in `/etc/car2x/environment`:

- `car2x-gps`         CAR2X_ENABLE_GPS=1         gpspipe -> jq -> gps.csv
- `car2x-bt-beacon`   CAR2X_ENABLE_BLUETOOTH=1   Python BLE scanner (bleak)
- `car2x-wlan-beacon` CAR2X_ENABLE_WLAN_BEACON=1 iwlist scans -> jsonl
- `car2x-usb-archive` CAR2X_ENABLE_USB_ARCHIVE=1 at shutdown, zips the active
                                                 trip onto /dev/car2x-archive
- `car2x-pico`        CAR2X_ENABLE_PICO=1        placeholder, off by default

The persistent services all carry `Restart=on-failure`, so a crash just brings
them back up and they keep writing into the same trip folder.


## Trip data layout

Each boot makes a new trip folder named `YYYYMMDD_HHMMSS` (UTC):

    /home/car2x/captures/
      20260505_083000/
        manifest.json          written by car2x-startup, status starts as
                               "in_progress"
        car2x.pcapng           802.11p capture, rotated at 100 MB
        gps.csv                ts_utc, lat, lon, alt, speed, track, fix, sats
        sysMon.csv             cpu_temp, load_1m, load_5m, mem totals (kB)
        bt_beacons.jsonl       BLE devices observed per scan window
        wlan_beacons_*.jsonl   iwlist scan results
      last_run.log             shared per-boot log across all services

Nothing is auto-deleted. The storage monitor only warns; freeing space is a
manual step. On a Pi 5 with an Atheros card I see roughly 20-25 GB of pcap per
hour of driving, depending on how busy the channel is.

To zip the active trip onto the USB archive disk manually:

    sudo systemctl start car2x-usb-archive

The unit is also `WantedBy=umount.target` so it runs at shutdown if a USB disk
matching the `/dev/car2x-archive` symlink is present.


## Interface and device naming

udev rules from phase 5 keep names stable across boots regardless of detect
order:

    wlan0              ath9k, AR9300 PCIe, OCB capture
    wlan1              brcmfmac, internal Pi chip, beacon sniffing
    mon0               monitor iface over wlan0, created at boot by ocb-setup,
                       this is what dumpcap actually captures on
    /dev/car2x-gps     GT-U7 USB serial
    /dev/car2x-pico    Pico USB serial
    /dev/car2x-archive USB archive disk (UUID-matched, optional)


## Configuration

Everything lives in `/etc/car2x/environment` as a flat key=value file. Each
variable has a fallback default inside the scripts, so a missing entry is not
fatal. The ones I touch the most:

    CAR2X_DISABLE_GUI=1            # multi-user.target, no desktop
    CAR2X_WLAN_COUNTRY=DE          # needed for wlan1 to leave rfkill
    CAR2X_PSU_MAX_CURRENT=4000     # EEPROM PSU rating, 4000mA is sane with UPS
    CAR2X_CAPTURE_INTERFACE=mon0   # dumpcap binds here
    CAR2X_DUMPCAP_SNAPLEN=0        # 0 = full packet (needed for 1609.2 sec layer)
    CAR2X_DUMPCAP_FILESIZE_MB=100
    CAR2X_GPS_BAUDRATE=115200
    CAR2X_STORAGE_WARNING_GB=40
    CAR2X_STORAGE_CRITICAL_GB=45
    CAR2X_ENABLE_GPS=1
    CAR2X_ENABLE_PICO=0
    CAR2X_ENABLE_BLUETOOTH=1
    CAR2X_ENABLE_WLAN_BEACON=1
    CAR2X_ENABLE_USB_ARCHIVE=1

Change then reboot. The runtime services source the env file at startup, not
on the fly.


## Monitoring

Standard journalctl works. The ones I use most often:

    systemctl status car2x-dumpcap car2x-gps car2x-ocb-setup
    journalctl -u car2x-dumpcap -f
    journalctl -u 'car2x-*' --since '1 hour ago'
    df -h /home/car2x/captures

A quick combined view across services without going through journald lives at
`/home/car2x/captures/last_run.log`. It is per-boot, overwritten each session.


## Privilege model

Most services run as the unprivileged `car2x` user with scoped capabilities
rather than full root.

- `car2x-dumpcap`     car2x, dumpcap binary has CAP_NET_RAW + CAP_NET_ADMIN
                      via setcap (not setuid root, set up in phase 2)
- `car2x-gps`         car2x, dialout group for serial access
- `car2x-sysmon`      car2x, only reads world-readable /proc and /sys
- `car2x-wlan-beacon` car2x, with ambient CAP_NET_RAW + CAP_NET_ADMIN granted
                      by the systemd unit
- `car2x-bt-beacon`   car2x, bluetooth + netdev groups
- `car2x-ocb-setup`   root, needs insmod and iw, oneshot at boot
- `car2x-startup`     root, oneshot, makes the tmpfs env dir at /run/car2x
- `car2x-usb-archive` root, needs mount and umount


## Caveats and known limitations

- The Pico path is unfinished. `car2x-07-pico-setup.sh` and `car2x-15-pico.sh`
  both exit early with a "coming soon" line. The Pico systemd unit ships but
  is off by default (`CAR2X_ENABLE_PICO=0` in environment). To finish it,
  drop your protocol handler into `car2x-pico-protocol.py` and flip the flag.

- Storage handling only warns, it never deletes. Plan SD card size and external
  archive accordingly. The daily timer just writes lines to
  `storage_monitor.log`.

- If you went into phase 1 with the internal WLAN previously disabled via
  `dtoverlay=disable-wifi`, `wlan1` will not show up until the next reboot.
  Phase 8 will warn but continue; redo phase 8 after a reboot to actually
  validate the beacon capture iface.


## Repository layout

    car2x-00-master-setup.sh         orchestrator
    car2x-0[1-9]-*.sh                setup phases 1 through 9
    car2x-1[0-9]-*.sh, car2x-20-*.sh runtime scripts, deployed to
                                     /usr/local/bin
    car2x-99-utilities.sh            shared bash helpers (logging, checks,
                                     status json)
    car2x-*.service, car2x-*.timer   systemd units, deployed to
                                     /usr/lib/systemd/system
    environment                      default config, deployed to
                                     /etc/car2x/environment