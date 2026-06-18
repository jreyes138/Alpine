# Changelog

All notable changes to `setup-cosmic-alpine.sh` are recorded here.
Versions are date-stamped (`vYYYY-MM-DD-rN`); the live file
`setup-cosmic-alpine.sh` is always the latest.

## v2026-06-17-r1  (2026-06-17 21:42)

- initial release
- 538 lines, sha256: a15136010bd7
- covers: preflight, community repo, eudev, dbus, polkit, seatd/elogind
  auto-detect, user creation with desktop groups, full cosmic-* install
  (greetd + cosmic-greeter), greetd config rewrite, lightdm cleanup,
  udev seat-tag fix for /dev/input/event*, sanity checks, optional restart
- verified on alpine-cosmic VM (192.168.122.220, Alpine 3.24.1): after
  restart, cosmic-greeter came up and cosmic-session launched with all
  14+ panel applets active for user joser
- introduces `save-version.sh` for date-stamped snapshots
## v2026-06-17-r2  (2026-06-17 21:53:56)

- add flatpak + flathub + default apps (Brave, Tutanota); user.namespaces check
- snapshot: `versions/setup-cosmic-alpine.v2026-06-17-r2.sh`
- sha256: `2fc18d45e53f`
- lines: 642

## v2026-06-17-r3  (2026-06-17 22:00:56)

- fix flatpak app detection (Tutanota name has space, broke awk $2 match); tighten error handling around rc capture
- snapshot: `versions/setup-cosmic-alpine.v2026-06-17-r3.sh`
- sha256: `23f2addc885a`
- lines: 657

## v2026-06-18-r1  (2026-06-18 08:42:57)

- fix cosmic-greeter crashloop: pam-rundir + gnome-keyring-pam + kwallet-pam, patch /usr/lib/pam.d/{base-auth,base-session,cosmic-greeter}, add cosmic-greeter user to seat/video/input/audio. Was panic with RuntimeDirNotSet / PermissionDenied
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r1.sh`
- sha256: `434cf35eefa3`
- lines: 789

## v2026-06-18-r1  (2026-06-18 09:12:02)

- user-login fix: pam_rundir in /usr/lib/pam.d/cosmic-greeter (no - prefix), ensures /run/user/UID is created at session open. Without this, joser logs in without XDG_RUNTIME_DIR, cosmic-comp fails to acquire session, exits 1, cosmic-session retries and gives up with 137.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r1.sh` (unchanged from previous)
- sha256: `434cf35eefa3`
- lines: 789

## v2026-06-18-r2  (2026-06-18 09:24:57)

- add bluez (bluetooth applet backend), elogind default (loginctl for power applet), flatpak appstream cache (cosmic-store browse), align_cosmic_greeter_initd (elogind dep).
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r2.sh`
- sha256: `9535e900a442`
- lines: 874

## v2026-06-18-r3  (2026-06-18 09:29:04)

- add setup_xdg_user_dirs() — installs xdg-user-dirs, runs xdg-user-dirs-update as the user, populates Documents/Downloads/Music/Pictures/Videos/Desktop/Templates/Public/Projects so cosmic-files shows them in the sidebar.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r3.sh`
- sha256: `8734a696fe9f`
- lines: 933

## v2026-06-18-r4  (2026-06-18 09:49:00)

- extract fix_cosmic_greeter_user_groups into its own function and call it AFTER install_cosmic_packages (the cosmic-greeter user is created by the package post-install, not before; the previous ordering skipped the group fix on a fresh install).
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r4.sh`
- sha256: `213c617496fd`
- lines: 948

## v2026-06-18-r5  (2026-06-18 09:56:00) — "bare metal" variant

- add `--bare-metal` (`-M`) flag: installs `linux-firmware`,
  `linux-firmware-amd`, `linux-firmware-intel` for real-hardware GPU drivers
  (Intel iGPU, AMD APU, AMD dGPU).  Default is unchanged — works on QEMU VMs.
- post-summary now shows "Bare metal: yes/no" line
- header now states VM + bare-metal support explicitly
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r5.sh`
- sha256: `3e5869a43928`
- lines: 965

## v2026-06-18-r6  (2026-06-18 10:11:00) — GPU auto-detection

- new `install_gpu_firmware()` function: auto-detects GPU vendor via
  `lspci -n` (and `/sys/class/drm/card*/device/vendor` as fallback) and
  installs only the matching firmware package:
    - `0x1002` (AMD)         -> `linux-firmware-amd`
    - `0x8086` (Intel)       -> `linux-firmware-intel`
    - `0x10de` (NVIDIA)      -> `linux-firmware-nvidia` + warn about kernel driver
    - `0x1234` (QEMU)        -> skip (emulated GPU has no firmware)
    - `0x1b36` (virtio-pci)  -> skip
- QEMU/Virtio GPUs detected -> no firmware install
- warns if `non-free` repo is not enabled (most firmware subpackages live there)
- tested on local Intel Raptor Lake: detected `Intel`, selected `linux-firmware-intel`
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r6.sh`
- sha256: `f12fb4fc566a`
- lines: 1070

## v2026-06-18-r6  (2026-06-18 10:13:36)

- fix install_gpu_firmware: use lspci -n for hex vendor IDs (not lspci -mm
  which gives text names); tested on local Intel Raptor Lake, detected correctly

## v2026-06-18-r7  (2026-06-18 10:14:38)

- install pciutils as bare-metal prerequisite so lspci is available for GPU detection
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r7.sh`
- sha256: `fa2852a8b859`
- lines: 1075

## v2026-06-18-r8  (2026-06-18 10:37:18)

- add GPL-3.0-or-later license: LICENSE file (full GPLv3 text), copyright header in script, SPDX identifier
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r8.sh`
- sha256: `9a20a9b59af9`
- lines: 1092

## v2026-06-18-r9  (2026-06-18 10:39:31)

- remove "Lenier" from copyright header; keep year only (Copyright (C) 2026)
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r9.sh`
- sha256: `27d828c9626a`
- lines: 1092

## v2026-06-18-r10  (2026-06-18 10:45:43)

- add --default-password (-P) and --password PASS flags: chpasswd to set a default password, passwd -e to force change on first login. Lets --yes mode actually produce a usable greeter login.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r10.sh`
- sha256: `430c6007edd0`
- lines: 1109

## v2026-06-18-r11  (2026-06-18 10:49:44)

- auto-detect existing user: --user > $SUDO_USER > first non-root account from setup-alpine > "cosmic" (new). Avoids creating a second user when setup-alpine already made one.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r11.sh`
- sha256: `0392d3858f36`
- lines: 1137

## v2026-06-18-r12  (2026-06-18 11:08:44)

- remove firefox (locale issue), add wezterm (terminal), CLI tools (fastfetch, btop, bat, eza, micro, git, wget, curl, htop, nano, sudo), and nerd fonts (font-fira-code-nerd, font-jetbrains-mono-nerd). BROWSER_PKG default is now empty — use --browser or flatpak.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r12.sh`
- sha256: `df6d2ced089e`
- lines: 1161

## v2026-06-18-r13  (2026-06-18 11:18:14)

- add install_audio_stack() — installs pipewire + wireplumber + pipewire-pulse + pipewire-alsa, drops /etc/xdg/autostart/{pipewire,wireplumber}.desktop. Fixes cosmic-osd / cosmic-settings-daemon 100% CPU spin when pipewire is absent (pop-os/cosmic-osd #70, #162). New --no-audio (-S) flag.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r13.sh`
- sha256: `f6dbd51fea84`
- lines: 1241

## v2026-06-18-r14  (2026-06-18 11:29:26)

- add install_power_stack() - installs upower + tuned-ppd, creates custom /etc/init.d/upower (Alpine does not ship one), starts tuned + tuned-ppd for power-profiles DBus. Fixes "Power mode: backend not found" in the COSMIC power applet. New --no-power (-W) flag.
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r14.sh`
- sha256: `b813aafb9b39`
- lines: 1342

## v2026-06-18-r14  (2026-06-18 11:37:47)

- no script changes; only README updated with high-CPU debugging steps (RUST_LOG, DBus interface checks, service status) for the cosmic-osd/settings-daemon issue on AMD Ryzen 7 7840HS
- snapshot: `versions/setup-cosmic-alpine.v2026-06-18-r14.sh` (unchanged from previous)
- sha256: `b813aafb9b39`
- lines: 1342

