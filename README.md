# setup-cosmic-alpine

A single-file installer for the COSMIC desktop on Alpine Linux (Edge / 3.2x).

## Quick start

```sh
# Fresh Alpine 3.24+ install, as root:
doas setup-apkrepos -c -e
doas apk update
doas apk add curl
curl -O https://raw.githubusercontent.com/jreyes138/Alpine/main/setup-cosmic-alpine.sh
doas sh setup-cosmic-alpine.sh --yes
```

For **bare metal** (real hardware, not a VM), add `--bare-metal` to install
GPU firmware auto-detected via `lspci`:

```sh
doas sh setup-cosmic-alpine.sh --yes --bare-metal
```

Or clone the whole repo (for the versions/ history + skill):

```sh
git clone git@github.com:jreyes138/Alpine.git
cd Alpine
doas sh setup-cosmic-alpine.sh --yes
```

That's it. The script:

1. Preflight (root, internet, free space, edge/community repo)
2. Installs eudev, dbus, polkit
3. Auto-detects seat manager (elogind preferred, seatd fallback)
4. Aligns polkit to the seat manager (polkit-elogind or polkit-noelogind)
5. Creates / upgrades the non-root user with desktop groups
6. Installs `cosmic-session`, `cosmic-comp`, `cosmic-greeter`, greetd, and the
   rest of the `cosmic-*` package family
7. Installs a browser (firefox by default), terminal, file manager
8. Drops a `/etc/udev/rules.d/99-cosmic-seat.rules` seat-tag fix
   (Alpine's stock 71-seat.rules doesn't tag `/dev/input/event*` children;
   without it, libseat / seatd refuses input FDs and the greeter has no
   keyboard / mouse)
9. Patches the broken PAM configs in `cosmic-greeter` and `base-*` (Alpine
   3.24 ships PAM configs that reference `pam_gnome_keyring` as `required`
   and `-session optional pam_rundir` — both fail on Linux-PAM 1.7+)
10. Adds the `cosmic-greeter` service-account user to seat/video/input/audio
    (so cosmic-comp can open DRM, input, and the seat socket)
11. Installs `bluez` for the bluetooth applet backend
12. Populates `/var/lib/flatpak/appstream` so cosmic-store shows the browse
    view (not just search)
13. Creates the XDG user-dirs (Documents, Downloads, etc.) so cosmic-files
    shows the full sidebar (not just "Home")
14. Configures greetd + cosmic-greeter, removes competing DMs
15. On `--bare-metal`: installs `pciutils` + auto-detected GPU firmware
    (`linux-firmware-amd` / `linux-firmware-intel` / `linux-firmware-nvidia`)
16. Reboots

## Options

```
-u, --user NAME      non-root user to use (default: $SUDO_USER, or the first non-root account created by setup-alpine, or "cosmic")
-U, --no-user        skip user creation/upgrade
-b, --browser PKG    optional browser package (default: none; "chromium" to install)
-n, --no-greeter     skip greetd/cosmic-greeter (headless)
-d, --no-udev-fix    skip the udev seat-tag fix
-F, --no-flatpak     skip flatpak + flathub + default apps
-B, --no-bluetooth   skip bluez install
-S, --no-audio       skip pipewire + wireplumber install (audio OSD will spin)
-W, --no-power       skip upower + power-profiles install (battery/power applet broken)
-X, --no-xdg-user-dirs  skip creating Documents/Downloads/Music/etc.
-M, --bare-metal     install linux-firmware for GPU drivers (real hardware)
-A, --flatpak-apps IDS  space-separated flatpak app IDs (default: "com.brave.Browser com.tutanota.Tutanota")
-r, --no-reboot      do not reboot at the end
-y, --yes            assume yes (non-interactive)
-P, --default-password  set a default password ("alpine") and force change on first login
    --password PASS  same, with a custom default password
-h, --help           help
```

## What gets installed

**Native packages (Alpine):**
- COSMIC desktop: `cosmic-session`, `cosmic-comp`, `cosmic-greeter`, all `cosmic-*` apps
- Display/login: `greetd`, `cosmic-greeter`, `xwayland`, `xdg-desktop-portal-cosmic`
- Bluetooth: `bluez`, `bluez-openrc`
- Audio: `pipewire`, `pipewire-pulse`, `pipewire-alsa`, `wireplumber` (autostart via XDG)
- Power: `upower`, `tuned-ppd`, `tuned-ppd-openrc` (custom /etc/init.d/upower for upowerd)
- XDG dirs: `xdg-user-dirs`
- PAM runtime: `gnome-keyring-pam`, `kwallet-pam`, `pam-rundir` (community repo)
- Seat manager: `elogind` (default) or `seatd` (fallback)
- Terminal: `wezterm`
- CLI utilities: `fastfetch`, `btop`, `bat`, `eza`, `micro`, `git`, `wget`, `curl`, `htop`, `nano`, `sudo`
- Nerd fonts: `font-fira-code-nerd`, `font-jetbrains-mono-nerd`
- Browser: NONE by default (use `--browser chromium` or install via flatpak)

**Flatpak (system-wide):**
- Remote: `flathub` (https://dl.flathub.org/repo/flathub.flatpakrepo)
- Default apps: `com.brave.Browser`, `com.tutanota.Tutanota`
- Custom apps: pass `--flatpak-apps "id1 id2 ..."` to override

**GPU firmware** (only with `--bare-metal`):
- Auto-detected via `lspci -n`: AMD/Intel/NVIDIA → matching `linux-firmware-*` package
- Skipped on QEMU/virtio GPUs (emulated, no firmware needed)

## Files in this repo

- `setup-cosmic-alpine.sh` — the live script (always latest)
- `save-version.sh` — snapshot the live script into `versions/` with a date-stamped tag
- `versions/` — date-stamped snapshots (`vYYYY-MM-DD-rN.sh`)
- `CHANGELOG.md` — append-only history
- `README.md` — this file

## Versioning + git workflow

Snapshots are date-stamped; git tracks the live file. The `save-version.sh`
helper handles the snapshotting + CHANGELOG append:

```sh
# Edit setup-cosmic-alpine.sh
./save-version.sh "fix: handle elogind sleep races"
git add -A
git commit -m "fix: handle elogind sleep races"
git push
```

This produces:
- A new entry in `versions/` (e.g. `setup-cosmic-alpine.v2026-06-17-r2.sh`;
  the rN increments if you save twice on the same day)
- A new block in `CHANGELOG.md` with the message, sha256 prefix, line count
- A git commit with the live file + new snapshot

The live `setup-cosmic-alpine.sh` is always the working copy. To roll back,
copy a snapshot over it:

```sh
cp versions/setup-cosmic-alpine.v2026-06-17-r1.sh setup-cosmic-alpine.sh
```

## Tested on

- Alpine 3.24.1 x86_64 (kernel 6.18-lts, OpenRC, eudev)
- COSMIC 1.0.15 (community repo)
- QEMU/KVM VMs (libvirt qxl-vga 64MB, virtio-net, ps2 kbd + USB tablet)
- Intel Raptor Lake (Iris Xe) — `install_gpu_firmware` auto-detection

## Files written (on the target system)

- `/etc/udev/rules.d/99-cosmic-seat.rules` — seat-tag fix
- `/etc/greetd/cosmic-greeter.toml` — managed by the script
- `/etc/greetd/config.toml` — neutered (set to `command = "true"`)
- `/etc/init.d/cosmic-greeter-daemon` — patched (`need seatd` → `need elogind`
  when elogind is the seat manager)
- `/usr/lib/pam.d/{base-auth,base-password,base-session,cosmic-greeter}` —
  rewritten to use `optional` for keyring modules and `session optional
  pam_rundir.so` (no `-` prefix; Linux-PAM 1.7+ ignores the prefix)
- `/home/<user>/.config/user-dirs.dirs` — XDG user dirs (Documents, etc.)
- `/var/log/setup-cosmic-alpine.log` — install log

## Known issues

- **QEMU `qxl` video has no GL acceleration** — cosmic-comp may render with
  EGL_BAD_DISPLAY errors. Use `virtio-vga` (with `virglrenderer=enable`) or
  passthrough a real GPU for full GL.
- **NVIDIA discrete GPUs** — `linux-firmware-nvidia` is installed but the
  kernel module (`nvidia-*` or nouveau) is not. Install manually after reboot.
- **Alpine's stock `cosmic-greeter` PAM config is broken on Linux-PAM 1.7+** —
  script patches it. If you `apk upgrade cosmic-greeter`, the patch is
  re-applied by the script (idempotent).
- **Boot manager not installed** — the script assumes you're booting from
  Alpine's existing setup (syslinux/grub/refind). If installing Alpine
  fresh, configure the bootloader first, then run the script.

## Debugging high CPU on cosmic-osd / cosmic-settings-daemon

If the COSMIC power/OSD/setting daemons are using constant high CPU:

1. **From a user terminal (as the logged-in user, NOT root)**, get the trace
   while the daemons are actually running in cosmic-session:
   ```sh
   # Get the running PIDs first
   pgrep -af cosmic-settings-daemon
   pgrep -af cosmic-osd
   
   # Attach strace to the running daemon (see what syscalls are blocking)
   doas strace -p $(pgrep cosmic-settings-daemon) -c -e trace=all 2>&1 | head -20
   doas strace -p $(pgrep cosmic-osd) -c -e trace=all 2>&1 | head -20
   ```
   Watch for **one syscall type dominating the count** — that's the loop.

2. **If 6.2% is exactly what you see on both daemons:** that's likely
   **normal** on bare metal. Each process has a tokio reactor thread
   and a zbus connection thread; on a 16-thread CPU that's ~6.2% per
   process just for the idle event loop. The fan noise is more likely
   from `cosmic-comp` (the compositor) doing GPU work, not from these
   daemons. Check:
   ```sh
   top -b -n 1 -o %CPU | head -15
   ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu | head -10
   ```
   If `cosmic-comp` is at the top, the fan noise is GPU-driven and
   unrelated to cosmic-osd / settings-daemon.

3. **Check that all services are running:**
   ```sh
   rc-service upower status
   rc-service tuned status
   rc-service tuned-ppd status
   rc-service pipewire status
   pgrep -a pipewire
   pgrep -a wireplumber
   ```
   All should say `started` / have a PID.

4. **Check DBus interfaces respond (no hangs):**
   ```sh
   dbus-send --system --print-reply --dest=org.freedesktop.UPower \
       /org/freedesktop/UPower org.freedesktop.UPower.EnumerateDevices
   dbus-send --system --print-reply --dest=net.hadess.PowerProfiles \
       /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.GetAll \
       string:net.hadess.PowerProfiles
   ```
   If either hangs (5+ seconds), the daemon is in a retry loop.

5. **Common cause on bare metal:** the first user session after the install
   started before some of the new services were picked up. **Log out and log
   back in** so cosmic-session restarts with all DBus services available.

6. **If 100% CPU persists after the above:** kill the daemons and re-launch
   with trace logging from a user terminal:
   ```sh
   pkill -f cosmic-settings-daemon
   pkill -f cosmic-osd
   RUST_LOG=debug cosmic-settings-daemon > /tmp/cosmic-settings.log 2>&1 &
   RUST_LOG=debug cosmic-osd > /tmp/cosmic-osd.log 2>&1 &
   ```
   Wait 30s, then check what they were doing:
   ```sh
   grep -E "WARN|ERROR|warn|error" /tmp/cosmic-{settings,osd}.log | head -30
   ```
   Look for repeating DBus errors — that's the loop.

## License

[GPL-3.0-or-later](LICENSE). Copyright (C) 2026.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
