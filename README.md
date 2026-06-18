# setup-cosmic-alpine

A single-file installer for the COSMIC desktop on Alpine Linux (Edge / 3.2x).

## Quick start

```sh
doas setup-cosmic-alpine --user joser
```

That's it. The script:

1. Preflight (root, internet, free space, edge/community repo)
2. Installs eudev, dbus, polkit
3. Auto-detects seat manager (elogind if present, else installs seatd)
4. Aligns polkit to the seat manager (polkit-elogind or polkit-noelogind)
5. Creates / upgrades the non-root user with desktop groups
6. Installs `cosmic-session`, `cosmic-comp`, `cosmic-greeter`, greetd, and the
   rest of the `cosmic-*` package family
7. Installs a browser (firefox by default), terminal, file manager
8. Drops a `/etc/udev/rules.d/99-cosmic-seat.rules` seat-tag fix
   (Alpine's stock 71-seat.rules doesn't tag `/dev/input/event*` children;
   without it, libseat / seatd refuses input FDs and the greeter has no
   keyboard / mouse)
9. Configures greetd + cosmic-greeter, removes competing DMs
10. Reboots

## Options

```
-u USER     non-root user to create or upgrade (default: $SUDO_USER or "cosmic")
-U          skip user creation
-b PKG      browser package (default: firefox; "" to skip)
-n          skip greetd/cosmic-greeter (headless)
-d          skip the udev seat-tag fix
-r          do not reboot at the end
-y          assume yes (non-interactive)
-h          help
```

## Files

- `setup-cosmic-alpine.sh` — the live script (always latest)
- `save-version.sh` — snapshot the live script into `versions/` with a date-stamped tag
- `versions/` — date-stamped snapshots (`vYYYY-MM-DD-rN.sh`)
- `CHANGELOG.md` — append-only history
- `README.md` — this file

## Versioning

Date-stamped, no git. Before and after any meaningful edit:

```sh
cd /home/joser/Documents/Projects/Cosmic
# ...edit setup-cosmic-alpine.sh...
./save-version.sh "fix: handle elogind sleep races"
```

This produces:
- `versions/setup-cosmic-alpine.v2026-06-17-r2.sh` (the rN increments if you
  save twice on the same day)
- a new `## v2026-06-17-r2` block appended to `CHANGELOG.md` with the
  message, sha256 prefix, and line count

The live `setup-cosmic-alpine.sh` is always the working copy. To roll back,
copy a snapshot over it.

## Rolling back

```sh
cd /home/joser/Documents/Projects/Cosmic
cp versions/setup-cosmic-alpine.v2026-06-17-r1.sh setup-cosmic-alpine.sh
```

## Tested on

- Alpine 3.24.1 x86_64 (kernel 6.18-lts, OpenRC, eudev)
- COSMIC 1.0.15 (community repo)
- libvirt VM with virtio-vga (one DRM device at /dev/dri/card1)
- QEMU `send-key` (PS/2 keyboard) and Spice USB tablet (event1)

## Files written (on the target system)

- `/etc/udev/rules.d/99-cosmic-seat.rules` — seat-tag fix
- `/etc/greetd/cosmic-greeter.toml` — managed by the script
- `/etc/greetd/config.toml` — neutered (set to `command = "true"`)
- `/var/log/setup-cosmic-alpine.log` — install log
