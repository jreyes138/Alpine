#!/bin/sh
# setup-cosmic-alpine.sh
# Install and configure the COSMIC desktop on Alpine Linux (Edge, community repo).
# Reference: https://wiki.alpinelinux.org/wiki/COSMIC
#
# Copyright (C) 2026 Lenier
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Works on both:
#   - QEMU/KVM VMs (libvirt qxl/virtio-vga, no real GPU)
#   - Bare metal (--bare-metal flag installs linux-firmware for AMD/Intel GPU)
#
# What this does, in order:
#   1. Preflight (root check, internet, alpine-edge + community repo, hostname, free space)
#   2. apk update
#   3. Enable community repo if missing
#   4. Install eudev, dbus, udev-init-scripts (prerequisites)
#   5. Auto-detect seat manager: elogind if present/running, else install seatd
#   6. Install polkit (or polkit-elogind when elogind is in use)
#   7. Create or upgrade the non-root user (groups: audio input video netdev wheel seat)
#   8. Install COSMIC packages (cosmic-session meta + cosmic* apps)
#   9. Install a browser (default: firefox), terminal, file manager, screenshot, etc.
#  10. Install greetd + cosmic-greeter (display manager)
#  11. Install Xwayland + xdg-desktop-portal-cosmic
#  12. Drop the broken /etc/udev/rules.d/71-seat.rules seat-tag workaround
#      (Alpine's stock rule matches KERNEL=="input*" (parent) but not event*
#      children, so libseat / seatd refuses to grant input FDs to cosmic-comp.
#      This causes dead keyboard / mouse in the greeter.)
#  13. Install flatpak + add flathub remote + install flatpak apps
#      (default: Brave, Tutanota).  This makes cosmic-store see them too.
#  14. Populate /var/lib/flatpak/appstream so cosmic-store can render
#      the browse/category views (without this, only search works).
#  15. Install bluez + bluetoothd so the bluetooth applet has a backend.
#  16. Enable and start all required OpenRC services
#  17. Remove competing / broken display managers from runlevel
#  18. Print post-install instructions (restart)
#
# Usage:
#   setup-cosmic-alpine.sh [options]
#
# Options:
#   -u, --user NAME         Non-root user to create or upgrade (default: $SUDO_USER or "cosmic")
#   -U, --no-user           Skip user creation (use on a system that already has a desktop user)
#   -b, --browser PKG       Browser package (default: firefox; pass "" to skip)
#   -n, --no-greeter        Skip greetd/cosmic-greeter (use on headless / tty-only installs)
#   -d, --no-udev-fix       Skip the seat-tag udev rule (if you know your setup is fine)
#   -F, --no-flatpak        Skip flatpak + flathub + default apps
#   -B, --no-bluetooth      Skip bluez install (applet will show "no adapter")
#   -X, --no-xdg-user-dirs  Skip creating Documents/Downloads/Music/etc.
#   -M, --bare-metal        Install linux-firmware for GPU drivers (real hardware).
#   -A, --flatpak-apps IDS  Space-separated flatpak app IDs (default: "com.brave.Browser com.tutanota.Tutanota")
#                           Pass "" to install flathub but no apps
#   -r, --no-reboot         Do not restart at the end
#   -y, --yes               Assume yes for any prompts (apk --no-interactive)
#   -h, --help              Show this help
#
# Exit codes:
#   0  success
#   1  generic error
#   2  preflight failure
#   3  package install failure
#   4  bluetooth install failure
#
# Idempotency: safe to re-run.  All steps are gated by "is X already done".

set -eu

# ---------- defaults ----------
TARGET_USER="${SUDO_USER:-cosmic}"
BROWSER_PKG="firefox"
DO_USER=1
DO_GREETER=1
DO_UDEV_FIX=1
DO_FLATPAK=1
DO_BLUETOOTH=1
DO_XDG_USER_DIRS=1
DO_BARE_METAL=0
FLATPAK_APPS="com.brave.Browser com.tutanota.Tutanota"
DO_REBOOT=1
ASSUME_YES=0
SCRIPT_NAME=$(basename "$0")
LOG="/var/log/${SCRIPT_NAME%.sh}.log"
PROJECT_NAME="cosmic-alpine"

# ---------- color output (TTY-only) ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_BOLD=$(tput bold 2>/dev/null || true)
    C_RED=$(tput setaf 1 2>/dev/null || true)
    C_GRN=$(tput setaf 2 2>/dev/null || true)
    C_YEL=$(tput setaf 3 2>/dev/null || true)
    C_CYN=$(tput setaf 6 2>/dev/null || true)
    C_RST=$(tput sgr0 2>/dev/null || true)
else
    C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
fi

say()  { printf '%s==>%s %s\n' "${C_BOLD}${C_CYN}" "${C_RST}" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "${C_GRN}" "${C_RST}" "$*"; }
warn() { printf '%s warn%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit "${2:-1}"; }

# ---------- arg parsing ----------
usage() { sed -n '2,40p' "$0"; }
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)            TARGET_USER="$2"; shift 2 ;;
        -U|--no-user)         DO_USER=0; shift ;;
        -b|--browser)         BROWSER_PKG="$2"; shift 2 ;;
        -n|--no-greeter)      DO_GREETER=0; shift ;;
        -d|--no-udev-fix)     DO_UDEV_FIX=0; shift ;;
        -F|--no-flatpak)      DO_FLATPAK=0; shift ;;
        -B|--no-bluetooth)    DO_BLUETOOTH=0; shift ;;
        -X|--no-xdg-user-dirs) DO_XDG_USER_DIRS=0; shift ;;
        -M|--bare-metal)       DO_BARE_METAL=1; shift ;;
        -A|--flatpak-apps)    FLATPAK_APPS="$2"; shift 2 ;;
        -r|--no-reboot)       DO_REBOOT=0; shift ;;
        -y|--yes)             ASSUME_YES=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

# ---------- logging ----------
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
exec 9>>"$LOG" 2>&1
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&9; }
trap 'log "script interrupted (line $LINENO)"' INT TERM

# ---------- APK flags ----------
APK_FLAGS=""
if [ "$ASSUME_YES" = "1" ]; then
    # When --yes is passed, force apk into non-interactive mode and quiet
    APK_FLAGS="--quiet"
fi

# ---------- preflight ----------
preflight() {
    say "preflight"
    [ "$(id -u)" -eq 0 ] || die "must be run as root (or via doas / sudo)"
    command -v apk >/dev/null 2>&1 || die "apk not found - this script is for Alpine Linux"
    [ -r /etc/alpine-release ] || die "/etc/alpine-release missing - not Alpine"
    local rel
    rel=$(cat /etc/alpine-release)
    log "alpine release: $rel"
    case "$rel" in
        *_edge*|3.2[0-9]*|3.1[0-9]*) ;;  # edge or any 3.1x/3.2x
        *) warn "Alpine $rel - COSMIC is officially supported on Edge and recent 3.x" ;;
    esac
    [ -d /sys/class/drm ] || warn "no /sys/class/drm - this is not a graphics-capable system"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die "neither curl nor wget found - needed for connectivity test"
    if ! curl -sS --max-time 5 -o /dev/null https://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null \
       && ! wget -q --timeout=5 -O /dev/null https://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null; then
        die "no internet to https://dl-cdn.alpinelinux.org - check DNS / firewall"
    fi
    local free_kb
    free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    [ "$free_kb" -gt 5242880 ] || warn "less than 5 GiB free on / - COSMIC + deps are ~1.5 GiB"
    ok "preflight passed"
}

# ---------- repos ----------
ensure_repos() {
    say "repositories"
    if grep -qE '^\s*https?://.*/alpine/v?3\.[0-9]+/community\s*$' /etc/apk/repositories 2>/dev/null \
       || grep -qE '^\s*https?://.*/alpine/edge/community\s*$' /etc/apk/repositories 2>/dev/null; then
        ok "community repo already enabled"
    else
        say "enabling community repo"
        local branch edge_or_v
        if grep -qE '^\s*https?://.*/alpine/edge/' /etc/apk/repositories 2>/dev/null; then
            branch="edge"
        else
            branch="v$(cut -d. -f1,2 /etc/alpine-release)"
        fi
        echo "https://dl-cdn.alpinelinux.org/alpine/${branch}/community" >> /etc/apk/repositories
        ok "added community repo for ${branch}"
    fi
    apk update $APK_FLAGS
    ok "apk index up to date"
}

# ---------- core prereqs ----------
install_prereqs() {
    say "core prerequisites (eudev, dbus)"
    apk add $APK_FLAGS eudev udev-init-scripts dbus polkit || die "core prereq install failed" 3
    ok "eudev, dbus, polkit installed"
}

enable_prereq_services() {
    say "enabling eudev + dbus + polkit"
    for svc in udev udev-trigger udev-settle udev-postmount dbus polkit; do
        if [ -e "/etc/init.d/$svc" ]; then
            rc-update -q add "$svc" default 2>/dev/null || rc-update add "$svc" default
        fi
    done
    # Activate right now (best effort)
    for svc in udev udev-trigger dbus polkit; do
        if [ -e "/etc/init.d/$svc" ]; then
            rc-service "$svc" start >/dev/null 2>&1 || warn "$svc did not start cleanly"
        fi
    done
    ok "eudev, dbus, polkit enabled and started"
}

# ---------- seat manager auto-detect ----------
SEAT_MANAGER=""   # "seatd" or "elogind"

detect_or_install_seat_manager() {
    say "seat manager"
    if rc-service elogind status 2>/dev/null | grep -q started; then
        SEAT_MANAGER="elogind"
        ok "elogind is already running - using elogind"
        return
    fi
    if [ -x /usr/bin/seatd ] && rc-service seatd status 2>/dev/null | grep -q started; then
        SEAT_MANAGER="seatd"
        ok "seatd is already running - using seatd"
        return
    fi
    if apk info -e elogind >/dev/null 2>&1; then
        say "elogind is installed but not running - enabling it"
        rc-update add elogind default
        rc-service elogind start
        SEAT_MANAGER="elogind"
        ok "elogind enabled and started"
        return
    fi
    if apk info -e seatd >/dev/null 2>&1; then
        say "seatd is installed but not running - enabling it"
        rc-update add seatd default
        rc-service seatd start
        SEAT_MANAGER="seatd"
        ok "seatd enabled and started"
        return
    fi
    # Nothing installed - Alpine wiki recommends elogind for COSMIC because
    # it provides loginctl (used by cosmic-settings-daemon for the power
    # applet) and the canonical pam_systemd runtime-dir path.  Fall back to
    # seatd only if elogind install fails (very rare).
    if grep -q '^seatd$' /etc/apk/world 2>/dev/null; then
        say "installing seatd (found in /etc/apk/world)"
        apk add $APK_FLAGS seatd || die "seatd install failed" 3
        rc-update add seatd default
        rc-service seatd start
        SEAT_MANAGER="seatd"
    else
        say "installing elogind (Alpine wiki recommendation for COSMIC)"
        if apk add $APK_FLAGS elogind 2>/dev/null; then
            rc-update add elogind default
            rc-service elogind start
            SEAT_MANAGER="elogind"
            ok "elogind enabled and started"
        else
            warn "elogind install failed; falling back to seatd"
            apk add $APK_FLAGS seatd || die "seatd install failed" 3
            rc-update add seatd default
            rc-service seatd start
            SEAT_MANAGER="seatd"
        fi
    fi
    ok "seat manager: $SEAT_MANAGER"
}

# Ensure polkit matches the seat manager
align_polkit_to_seat() {
    case "$SEAT_MANAGER" in
        elogind)
            # polkit-elogind is the variant that talks to elogind via PAM
            if apk info -e polkit-elogind >/dev/null 2>&1; then
                ok "polkit-elogind already installed"
            else
                apk add $APK_FLAGS polkit-elogind || warn "polkit-elogind install failed - polkit may not authenticate"
            fi
            ;;
        seatd)
            if apk info -e polkit-noelogind-libs >/dev/null 2>&1; then
                ok "polkit (noelogind) already installed"
            else
                apk add $APK_FLAGS polkit-noelogind-libs || warn "polkit-noelogind install failed"
            fi
            ;;
    esac
}

# ---------- user ----------

# Add the cosmic-greeter service-account user to seat/video/input/audio so
# cosmic-comp can open DRM, input devices, and the seatd socket when running
# as that user.  Without these, cosmic-comp panics with PermissionDenied on
# libseat_open.  Idempotent: no-op if the user doesn't exist yet.
fix_cosmic_greeter_user_groups() {
    if ! id cosmic-greeter >/dev/null 2>&1; then
        # cosmic-greeter package not installed yet; nothing to do.
        return
    fi
    for g in seat video input audio; do
        # Create the group if it doesn't exist (Alpine does this lazily)
        getent group "$g" >/dev/null || addgroup "$g" 2>/dev/null || true
        if ! id -nG cosmic-greeter 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
            addgroup cosmic-greeter "$g" 2>/dev/null \
                && ok "cosmic-greeter: added to $g" \
                || warn "cosmic-greeter: could not add to $g"
        fi
    done
}

ensure_user() {
    [ "$DO_USER" = "1" ] || { say "skipping user creation (--no-user)"; return; }
    say "user: $TARGET_USER"
    if id "$TARGET_USER" >/dev/null 2>&1; then
        ok "user $TARGET_USER already exists (uid $(id -u "$TARGET_USER"))"
    else
        say "creating user $TARGET_USER (no password - set it after install)"
        # BusyBox adduser has no -p, so create with -D (no password) and
        # prompt the operator to set one.  In a non-interactive install
        # (--yes), print a follow-up command.
        adduser -D -g "COSMIC User" "$TARGET_USER" 2>/dev/null \
            || die "adduser failed (is '$TARGET_USER' a reserved name?)" 3
        ok "user $TARGET_USER created (no password yet)"
        if [ "$ASSUME_YES" = "1" ]; then
            warn "set a password later: passwd $TARGET_USER"
        else
            say "set a password for $TARGET_USER (or press Ctrl-C to skip)"
            passwd "$TARGET_USER" || warn "password not set - log in via doas / SSH first"
        fi
    fi

    say "adding $TARGET_USER to desktop groups"
    # Groups: wheel (doas), audio, video, input, netdev, seat, tty, games
    for g in wheel audio video input netdev seat games tty cdrom dialout lp; do
        # Create the group if it doesn't exist (Alpine does this lazily)
        getent group "$g" >/dev/null || addgroup "$g" 2>/dev/null || true
        addgroup "$TARGET_USER" "$g" 2>/dev/null || true
    done
    # Verify
    local missing=""
    for g in wheel audio video input netdev; do
        if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$g"; then
            missing="$missing $g"
        fi
    done
    if [ -n "$missing" ]; then
        warn "could not add groups:$missing (continuing anyway)"
    else
        ok "$TARGET_USER has the desktop groups"
    fi

    # The cosmic-greeter user (created by the cosmic-greeter package)
    # also needs seat/video/input/audio so cosmic-comp can open DRM,
    # input devices, and the seatd socket when running as that user.
    # Without these, cosmic-comp panics with PermissionDenied on libseat_open.
    # Idempotent: safely re-runnable.  Also called from main() AFTER
    # install_cosmic_packages because the user is created by the package
    # post-install, not before.
    fix_cosmic_greeter_user_groups
}

# Create the XDG user-dirs config and standard folder set (Documents,
# Downloads, Music, etc.) in $TARGET_USER's home.  Without this, the
# cosmic-files sidebar only shows "Home" - it has no XDG_DESKTOP_DIR etc.
# to populate the categories.  Runs `xdg-user-dirs-update` as the user.
setup_xdg_user_dirs() {
    [ "$DO_USER" = "1" ] || return
    [ "$DO_XDG_USER_DIRS" = "1" ] || { say "skipping xdg-user-dirs (--no-xdg-user-dirs)"; return; }
    say "XDG user dirs ($TARGET_USER)"
    if apk info -e xdg-user-dirs >/dev/null 2>&1; then
        ok "xdg-user-dirs already installed"
    else
        apk add $APK_FLAGS xdg-user-dirs || die "xdg-user-dirs install failed" 3
    fi
    local hdir rc
    hdir=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ -z "$hdir" ] || [ ! -d "$hdir" ]; then
        warn "no home dir for $TARGET_USER - skipping xdg-user-dirs"
        return
    fi
    if [ -s "$hdir/.config/user-dirs.dirs" ]; then
        ok "user-dirs.dirs already present"
    else
        # Run as the user.  xdg-user-dirs-update needs DBus for the locale
        # look-up; we provide a minimal environment.
        rc=0
        su -s /bin/sh "$TARGET_USER" -c "HOME=$hdir XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") xdg-user-dirs-update" \
            || rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$hdir/.config/user-dirs.dirs" ]; then
            ok "user-dirs.dirs written"
        else
            warn "xdg-user-dirs-update failed (rc=$rc); writing config manually"
            # Fallback: write user-dirs.dirs and create the dirs ourselves.
            local lang=en
            mkdir -p "$hdir/Desktop" "$hdir/Documents" "$hdir/Downloads" \
                     "$hdir/Music" "$hdir/Pictures" "$hdir/Videos" \
                     "$hdir/Projects" "$hdir/Public" "$hdir/Templates"
            cat > "$hdir/.config/user-dirs.dirs" <<UDEOF
# Generated by setup-cosmic-alpine.sh fallback
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
XDG_TEMPLATES_DIR="\$HOME/Templates"
XDG_PUBLICSHARE_DIR="\$HOME/Public"
XDG_DOCUMENTS_DIR="\$HOME/Documents"
XDG_MUSIC_DIR="\$HOME/Music"
XDG_PICTURES_DIR="\$HOME/Pictures"
XDG_VIDEOS_DIR="\$HOME/Videos"
XDG_PROJECTS_DIR="\$HOME/Projects"
UDEOF
            chown -R "$TARGET_USER:$TARGET_USER" "$hdir/.config" "$hdir/Desktop" "$hdir/Documents" "$hdir/Downloads" \
                "$hdir/Music" "$hdir/Pictures" "$hdir/Videos" "$hdir/Projects" "$hdir/Public" "$hdir/Templates"
        fi
    fi
}

# ---------- GPU firmware auto-detection ----------
# Detect the GPU vendor from /sys/class/drm/card*/device/vendor and PCI
# subsystem IDs.  PCI vendor IDs:
#   0x1002  AMD / ATI
#   0x8086  Intel
#   0x10de  NVIDIA
#   0x1234  QEMU emulated (Bochs/QXL/Virtio) - no firmware needed
#   0x1b36  Red Hat PCI passthrough
# Also reads /sys/class/drm/card*/device/uevent for descriptive names.
install_gpu_firmware() {
    say "GPU firmware (hardware detection)"

    # First: lspci (lspci from pciutils) is the most reliable if present.
    # Fall back to /sys/class/drm/ if lspci is missing.
    # lspci -mm gives "Class" "Vendor" "Device" (textual names)
    # lspci -n  gives "Class Vendor:Device" (hex IDs) - we use this for matching
    local vendors="" gpu_info=""
    if command -v lspci >/dev/null 2>&1; then
        gpu_info=$(lspci -mm 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)
        # lspci -n: filter class 0300 (VGA) and grab vendor ID (4 hex digits)
        vendors=$(lspci -n 2>/dev/null | awk '/Class 0300/ {print $3}' | cut -d: -f1 | sort -u)
    fi

    # Fallback: walk /sys/class/drm/card*/device/vendor (already in hex)
    if [ -z "$vendors" ]; then
        for f in /sys/class/drm/card*/device/vendor; do
            [ -r "$f" ] || continue
            local v
            v=$(cat "$f" 2>/dev/null)
            [ -n "$v" ] && vendors="$vendors $v"
        done
        vendors=$(echo "$vendors" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    fi

    if [ -z "$vendors" ]; then
        warn "no GPU detected; skipping firmware install"
        return
    fi

    # Map vendor ID -> friendly name + Alpine firmware package
    # 0x1002 = AMD, 0x8086 = Intel, 0x10de = NVIDIA,
    # 0x1234 = QEMU, 0x1b36 = RH virtio, 0x1af4 = Red Hat virtio 1.0
    local amd=0 intel=0 nvidia=0 virt=0 unknown=0
    local vdesc=""
    for v in $vendors; do
        case "$v" in
            0x1002|1002) amd=1;  vdesc="$vdesc AMD " ;;
            0x8086|8086) intel=1; vdesc="$vdesc Intel " ;;
            0x10de|10de) nvidia=1; vdesc="$vdesc NVIDIA " ;;
            0x1234|1234) virt=1;  vdesc="$vdesc QEMU-emulated " ;;
            0x1b36|0x1af4|1b36|1af4) virt=1; vdesc="$vdesc Virtio " ;;
            *) unknown=1; vdesc="$vdesc vendor=$v " ;;
        esac
    done
    say "detected GPU vendors: $vdesc"
    [ -n "$gpu_info" ] && say "  $gpu_info"

    # If only QEMU/virtio: nothing to do (emulated GPU has no firmware).
    if [ "$virt" = "1" ] && [ "$amd" = "0" ] && [ "$intel" = "0" ] && [ "$nvidia" = "0" ]; then
        ok "GPU is virtual/emulated - no firmware needed"
        return
    fi

    # Install the matching firmware packages.  Always install linux-firmware
    # meta if present (pulls in common WiFi/BT firmware, microcode, etc.).
    local pkgs=""
    if [ "$amd" = "1" ]; then
        pkgs="$pkgs linux-firmware-amd"
    fi
    if [ "$intel" = "1" ]; then
        pkgs="$pkgs linux-firmware-intel"
    fi
    if [ "$nvidia" = "1" ]; then
        # NVIDIA: requires the non-free repo.  We install the firmware
        # but flag the kernel-module requirement.
        pkgs="$pkgs linux-firmware-nvidia"
        warn "NVIDIA GPU detected: kernel driver (nvidia or nouveau) is NOT installed by this script"
        warn "After reboot, install one of: apk add nvidia-${NVIDIA_VARIANT:-stable} (proprietary) OR enable nouveau"
    fi
    if [ "$unknown" = "1" ] || [ "$amd" = "1" ] || [ "$intel" = "1" ]; then
        # General fallback: pull the linux-firmware meta which contains
        # most AMD/Intel/WiFi/BT blobs and acts as a safety net.
        if apk search -q linux-firmware >/dev/null 2>&1; then
            pkgs="$pkgs linux-firmware"
        fi
    fi

    if [ -z "$pkgs" ]; then
        ok "no firmware packages to install"
        return
    fi

    # Trim leading/trailing whitespace
    pkgs=$(echo "$pkgs" | xargs)

    # Pre-check: do the packages exist in the configured repos?  linux-firmware
    # lives in main but its subpackages (linux-firmware-amd, -intel, -nvidia)
    # are in the non-free repo.  If non-free is not enabled, install will fail.
    say "installing firmware: $pkgs"
    if apk add $APK_FLAGS $pkgs 2>&1 | sed 's/^/    /'; then
        ok "firmware installed"
    else
        warn "firmware install failed - non-free repo may not be enabled"
        warn "to enable non-free: edit /etc/apk/repositories and uncomment the non-free line, then apk update"
    fi
}

# ---------- COSMIC packages ----------
install_cosmic_packages() {
    say "COSMIC packages (cosmic-session, cosmic-comp, cosmic-greeter, etc.)"
    # cosmic-session pulls cosmic-comp; greetd is the display manager.
    # cosmic-greeter-openrc ships the /etc/init.d/cosmic-greeter service.
    apk add $APK_FLAGS \
        cosmic-session \
        cosmic-comp \
        cosmic-greeter \
        cosmic-greeter-openrc \
        greetd \
        greetd-openrc \
        xdg-desktop-portal-cosmic \
        xwayland \
        wayland \
        mesa-dri-gallium \
        mesa-egl \
        || die "COSMIC core install failed" 3

    # GPU firmware.  On QEMU VMs the GPU is emulated (qxl, virtio-vga)
    # and needs no firmware.  On bare metal, detect the GPU vendor and
    # install the matching firmware package.
    if [ "$DO_BARE_METAL" = "1" ]; then
        # lspci (pciutils) is the cleanest way to detect GPU vendor.
        # Install it on the bare-metal path; on VM path it's a no-op skip.
        if ! command -v lspci >/dev/null 2>&1; then
            apk add $APK_FLAGS pciutils 2>/dev/null || warn "pciutils install failed - will use /sys fallback"
        fi
        install_gpu_firmware
    fi
    ok "COSMIC core installed"

    say "COSMIC apps (cosmic* glob, minus -openrc / -systemd helpers)"
    # Pull in all the user-facing apps without grabbing meta-packages
    # that would pull in systemd.  apk search returns versioned names
    # like cosmic-app-library-1.0.15-r0; strip the suffix because
    # apk add rejects versioned names with "no such package".
    local apps
    apps=$(apk search -e 'cosmic*' 2>/dev/null \
        | grep -E '^cosmic-[a-z]' \
        | grep -vE 'cosmic-(greeter-openrc|greeter-systemd|session-systemd|applets-systemd|initial-setup)$' \
        | sed -E 's/-[0-9].*$//' \
        | sort -u | tr '\n' ' ')
    if [ -n "$apps" ]; then
        # shellcheck disable=SC2086   # intentional word-splitting on $apps
        apk add $APK_FLAGS $apps >/dev/null 2>&1 \
            && ok "COSMIC apps installed ($(echo $apps | wc -w) packages)" \
            || warn "some cosmic-* apps failed to install (continuing)"
    else
        warn "apk search returned no cosmic-* apps (continuing)"
    fi
}

install_optional_apps() {
    if [ -n "$BROWSER_PKG" ]; then
        say "browser: $BROWSER_PKG"
        apk add $APK_FLAGS "$BROWSER_PKG" 2>/dev/null \
            && ok "browser installed: $BROWSER_PKG" \
            || warn "browser $BROWSER_PKG not available, skipping"
    else
        say "skipping browser (--browser set to empty)"
    fi

    say "common utilities (curl, git, htop, nano, sudo)"
    apk add $APK_FLAGS curl git htop nano sudo 2>/dev/null \
        && ok "common utilities installed" \
        || warn "some utilities failed (continuing)"
}

# ---------- flatpak ----------
FLATHUB_REMOTE_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"
FLATHUB_NAME="flathub"

check_unprivileged_userns() {
    # flatpak / bubblewrap uses unprivileged user namespaces for sandboxing.
    # Alpine kernels from 5.x onward have it on by default; older or hardened
    # kernels may not.  Warn the user if disabled - apps will fail to launch.
    local val
    val=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "")
    if [ -n "$val" ] && [ "$val" = "0" ]; then
        warn "kernel.unprivileged_userns_clone=0 - flatpak apps will not launch"
        warn "fix with: sysctl -w kernel.unprivileged_userns_clone=1"
        return 1
    fi
    if [ ! -e /proc/sys/user/max_user_namespaces ] || \
       [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" = "0" ]; then
        warn "max_user_namespaces=0 - flatpak apps will not launch"
        warn "fix with: sysctl -w user.max_user_namespaces=28633"
        return 1
    fi
    return 0
}

install_flatpak() {
    [ "$DO_FLATPAK" = "1" ] || { say "skipping flatpak (--no-flatpak)"; return; }
    say "flatpak"
    if ! command -v flatpak >/dev/null 2>&1; then
        apk add $APK_FLAGS flatpak || die "flatpak install failed" 3
        ok "flatpak installed"
    else
        ok "flatpak already installed"
    fi

    # Add flathub remote if missing (system-wide, since user is system-wide by design here)
    if flatpak remote-list --system 2>/dev/null | grep -q "^${FLATHUB_NAME}\b"; then
        ok "flathub remote already configured"
    else
        say "adding flathub remote (system-wide)"
        flatpak remote-add --system --if-not-exists \
            "$FLATHUB_NAME" "$FLATHUB_REMOTE_URL" \
            || die "failed to add flathub remote"
        ok "flathub remote added"
    fi

    check_unprivileged_userns || true   # warn only, don't fail

    if [ -n "$FLATPAK_APPS" ]; then
        say "flatpak apps: $FLATPAK_APPS"
        # Resolve "installed?" by app id, one by one (idempotent).
        # shellcheck disable=SC2086   # intentional word-splitting on $FLATPAK_APPS
        for app in $FLATPAK_APPS; do
            # `flatpak list` column layout is variable (names with spaces
            # push IDs to different $N), so match on the app id anywhere
            # in the line, anchored on whitespace.
            if flatpak list --system 2>/dev/null | grep -qE "(^|[[:space:]])${app}([[:space:]]|\$)"; then
                ok "flatpak app already installed: $app"
            else
                say "installing flatpak app: $app"
                # flatpak install returns nonzero on "Nothing matches" with -y.
                # Suppress set -e for the call, then capture $? immediately
                # because the next statement (tail) will clobber it.
                tmp=$(mktemp) || tmp=""
                if [ -z "$tmp" ]; then
                    warn "mktemp failed for $app; skipping"
                    continue
                fi
                flatpak install -y --system "$FLATHUB_NAME" "$app" >"$tmp" 2>&1 || rc=$?
                rc=${rc:-0}
                tail -5 "$tmp" || true
                if [ "$rc" -ne 0 ]; then
                    warn "flatpak install failed for: $app (rc=$rc, continuing)"
                else
                    ok "flatpak app installed: $app"
                fi
                rm -f "$tmp"
            fi
        done
    else
        say "no flatpak apps requested (--flatpak-apps set to empty)"
    fi
}

# ---------- display manager ----------
install_and_configure_greeter() {
    [ "$DO_GREETER" = "1" ] || { say "skipping greeter (--no-greeter)"; return; }
    say "greetd + cosmic-greeter"

    # greetd config: use the cosmic-greeter-provided toml, which already
    # has the right vt=1, command, and user settings.
    if [ -e /etc/greetd/cosmic-greeter.toml ]; then
        cp -f /etc/greetd/cosmic-greeter.toml /etc/greetd/cosmic-greeter.toml.dist 2>/dev/null || true
    fi
    cat > /etc/greetd/cosmic-greeter.toml <<'EOF'
# Managed by setup-cosmic-alpine.sh
[terminal]
vt = 1

[general]
service = "cosmic-greeter"

[default_session]
command = "cosmic-greeter-start"
user = "cosmic-greeter"
EOF
    chown root:root /etc/greetd/cosmic-greeter.toml
    chmod 0644 /etc/greetd/cosmic-greeter.toml
    ok "/etc/greetd/cosmic-greeter.toml written"

    # Drop the stock greetd's default config so it doesn't try to run cosmic-comp
    # as the greetd user with no seat.  Leave the file in place but blank.
    if [ -e /etc/greetd/config.toml ]; then
        cat > /etc/greetd/config.toml <<'EOF'
# Stock greetd config disabled by setup-cosmic-alpine.sh.
# We use /etc/greetd/cosmic-greeter.toml via the cosmic-greeter service.
[terminal]
vt = 7
[default_session]
command = "true"
user = "nobody"
EOF
    fi

    # Runlevel: enable cosmic-greeter, drop the stock greetd service.
    rc-update -q del greetd default 2>/dev/null || rc-update del greetd default 2>/dev/null || true
    rc-update add cosmic-greeter default
    rc-service cosmic-greeter restart >/dev/null 2>&1 || rc-service cosmic-greeter start >/dev/null 2>&1 \
        || warn "cosmic-greeter did not start cleanly (check /var/log/messages)"
    ok "cosmic-greeter enabled"
}

# ---------- cosmic-greeter runtime fixes ----------
# Without these three fixes, cosmic-greeter crash-loops:
#
#   1. pam_gnome_keyring and pam_kwallet5 are referenced in
#      /usr/lib/pam.d/{base-auth,base-password,base-session,cosmic-greeter}
#      with "required" or "-" prefixes.  On Linux-PAM 1.7+ the "-" prefix
#      no longer silently ignores missing modules; pam_setcred returns
#      MODULE_UNKNOWN and greetd exits 1.  Fix: install gnome-keyring-pam
#      and kwallet-pam, and rewrite the "required" lines to "optional".
#
#   2. Without elogind, nothing creates /run/user/$UID, so cosmic-comp
#      panics with "RuntimeDirNotSet" and unwrap()s.  pam_rundir is the
#      lightweight fix: it creates /run/user/$UID on session open.
#
#   3. gnome-keyring PAM module fails to start the daemon without a
#      writable runtime dir, so even with pam_rundir installed the
#      module will log an error.  Marking the keyring session modules
#      optional keeps greetd running and lets the user log in.
fix_cosmic_greeter_runtime() {
    [ "$DO_GREETER" = "1" ] || { say "skipping greeter runtime fixes (--no-greeter)"; return; }
    say "greetd runtime: pam-rundir + gnome-keyring-pam + kwallet-pam"
    local missing=0
    for pkg in gnome-keyring-pam kwallet-pam pam-rundir; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            ok "$pkg already installed"
        else
            if apk add $APK_FLAGS "$pkg" >/dev/null 2>&1; then
                ok "installed $pkg"
            else
                warn "could not install $pkg (continuing)"
                missing=$((missing + 1))
            fi
        fi
    done

    # Patch /usr/lib/pam.d/base-auth: rewrite "required pam_gnome_keyring" to
    # "optional" so a missing / failed keyring PAM doesn't block auth.
    # Idempotent: if we already wrote "optional pam_gnome_keyring" in the
    # auth stack, do nothing.
    if grep -q '^auth    optional   pam_gnome_keyring' /usr/lib/pam.d/base-auth 2>/dev/null; then
        ok "/usr/lib/pam.d/{base-auth,base-password,base-session} already patched"
    else
        cat > /usr/lib/pam.d/base-auth <<'PAMEOF'
# Managed by setup-cosmic-alpine.sh.  Original Alpine base-auth uses
# "required pam_gnome_keyring.so" and "-" prefix for missing modules;
# both break on Linux-PAM 1.7+.  Mark all desktop-credential modules optional.
auth    required   pam_unix.so nullok
auth    required   pam_nologin.so
auth    required   pam_env.so
auth    optional   pam_gnome_keyring.so
auth    optional   pam_kwallet5.so
PAMEOF
        cat > /usr/lib/pam.d/base-password <<'PAMEOF'
# Managed by setup-cosmic-alpine.sh.  See base-auth comment.
password required   pam_unix.so nullok sha512 shadow
password optional   pam_gnome_keyring.so use_authtok
password optional   pam_kwallet5.so
PAMEOF
        cat > /usr/lib/pam.d/base-session <<'PAMEOF'
# Managed by setup-cosmic-alpine.sh.  Use pam_rundir to create /run/user/$UID.
session include base-session-noninteractive
session optional   pam_rundir.so
session optional   pam_elogind.so
session optional   pam_systemd.so
session optional   pam_ck_connector.so
session optional   pam_turnstile.so
session optional   pam_dumb_runtime_dir.so
session optional   pam_gnome_keyring.so auto_start
session optional   pam_kwallet5.so
session optional   pam_openrc.so
PAMEOF
        ok "patched /usr/lib/pam.d/{base-auth,base-password,base-session}"
    fi

    # Patch /usr/lib/pam.d/cosmic-greeter: rewrite "required" keyring to
    # "optional" (Alpine cosmic-greeter package ships the broken form).
    if grep -q '^auth       required        pam_gnome_keyring' /usr/lib/pam.d/cosmic-greeter 2>/dev/null; then
        cp /usr/lib/pam.d/cosmic-greeter /usr/lib/pam.d/cosmic-greeter.dist 2>/dev/null || true
        cat > /usr/lib/pam.d/cosmic-greeter <<'PAMEOF'
# Managed by setup-cosmic-alpine.sh.  See base-auth comment for context.
# Original Alpine config used 'required pam_gnome_keyring.so' which
# fails on systems without a writable XDG_RUNTIME_DIR.
auth       required        pam_unix.so nullok
auth       required        pam_nologin.so
auth       required        pam_env.so
auth       optional        pam_gnome_keyring.so
account    required        pam_unix.so
account    required        pam_nologin.so
password   required        pam_unix.so nullok sha512 shadow
password   optional        pam_gnome_keyring.so use_authtok
session    required        pam_env.so
session    required        pam_limits.so
session    required        pam_unix.so
session    optional        pam_rundir.so
session    optional        pam_elogind.so
session    optional        pam_systemd.so
session    optional        pam_ck_connector.so
session    optional        pam_turnstile.so
session    optional        pam_dumb_runtime_dir.so
session    optional        pam_gnome_keyring.so auto_start
PAMEOF
        ok "patched /usr/lib/pam.d/cosmic-greeter"
    else
        ok "/usr/lib/pam.d/cosmic-greeter already patched"
    fi

    if [ "$missing" -gt 0 ]; then
        warn "$missing PAM package(s) failed to install - cosmic-greeter may still crashloop"
        warn "  check 'apk add gnome-keyring-pam kwallet-pam pam-rundir' manually"
    fi
}

# ---------- lightdm cleanup ----------
cleanup_competing_dms() {
    say "removing competing display managers from runlevel"
    for dm in lightdm lightdm-gtk-greeter; do
        if rc-update show default 2>/dev/null | grep -q "$dm"; then
            rc-update -q del "$dm" default 2>/dev/null || rc-update del "$dm" default 2>/dev/null || true
        fi
    done
    # Stop lightdm if it's currently running (supervise-daemon will respawn
    # unless we stop the supervised process; just kill -9 the child)
    if pgrep -x lightdm >/dev/null 2>&1; then
        warn "lightdm is running - killing it (OpenRC's supervise-daemon respawns unless you rc-update del first)"
        pkill -9 -x lightdm 2>/dev/null || true
    fi
    ok "runlevel cleaned"
}

# cosmic-greeter-daemon's OpenRC init ships with `need seatd` hardcoded.
# When we use elogind as the seat manager, we need to patch that.  This is
# idempotent: re-running on a seatd install leaves the file as-is.
align_cosmic_greeter_initd() {
    local f=/etc/init.d/cosmic-greeter-daemon
    [ -f "$f" ] || { ok "cosmic-greeter-daemon init not present (skip)"; return; }
    case "$SEAT_MANAGER" in
        elogind)
            if grep -qE '^\s*need\s+seatd\b' "$f"; then
                sed -i 's/^\(\s*\)need seatd$/\1need elogind/' "$f"
                ok "cosmic-greeter-daemon: seatd -> elogind"
            else
                ok "cosmic-greeter-daemon: already aligned to elogind"
            fi
            ;;
        seatd)
            if grep -qE '^\s*need\s+elogind\b' "$f"; then
                sed -i 's/^\(\s*\)need elogind$/\1need seatd/' "$f"
                ok "cosmic-greeter-daemon: elogind -> seatd"
            else
                ok "cosmic-greeter-daemon: already aligned to seatd"
            fi
            ;;
    esac
}

# Install bluez so the bluetooth applet has a real backend to talk to.
# Without bluetoothd running, the applet shows a broken state even when
# no BT hardware is present.  The init script handles the case where
# no BT controller is found gracefully (it just stays inactive).
install_bluetooth_stack() {
    [ "$DO_BLUETOOTH" = "1" ] || { say "skipping bluetooth (--no-bluetooth)"; return; }
    say "bluetooth stack (bluez)"
    if apk info -e bluez >/dev/null 2>&1; then
        ok "bluez already installed"
    else
        apk add $APK_FLAGS bluez bluez-openrc || die "bluez install failed" 4
    fi
    if rc-service bluetooth status 2>/dev/null | grep -q started; then
        ok "bluetooth already running"
    else
        rc-update add bluetooth default 2>&1 || true
        rc-service bluetooth start 2>&1 || warn "bluetooth did not start (no HW?)"
    fi
}

# Populate /var/lib/flatpak/appstream/<remote>/<arch> so cosmic-store can
# render the browse/category views.  Without this, only the search bar
# works in cosmic-store - the home page is empty.
populate_appstream_cache() {
    [ "$DO_FLATPAK" = "1" ] || { say "skipping appstream (--no-flatpak)"; return; }
    if ! command -v flatpak >/dev/null 2>&1; then
        say "no flatpak binary; skipping appstream"
        return
    fi
    say "appstream metadata for cosmic-store"
    if [ -d /var/lib/flatpak/appstream/flathub/x86_64 ] && \
       [ -s /var/lib/flatpak/appstream/flathub/x86_64/active/sections.xml ] 2>/dev/null; then
        ok "appstream cache already present"
    else
        flatpak update --appstream 2>&1 | sed 's/^/    /' || warn "appstream fetch failed"
    fi
}

# ---------- udev seat-tag workaround ----------
# Alpine's stock /usr/lib/udev/rules.d/71-seat.rules matches
#   SUBSYSTEM=="input", KERNEL=="input*", TAG+="seat"
# but KERNEL=="input*" matches the *parent* device (input0/, input1/),
# not the child /dev/input/event* nodes.  Tags do not inherit, so the
# child event* devices never get the seat tag, and libseat / seatd
# refuses to grant input FDs to the compositor.  This leaves the
# keyboard and USB tablet dead in the greeter.
#
# The fix is a one-line drop-in that matches event* and tags them seat.
udev_seat_tag_fix() {
    [ "$DO_UDEV_FIX" = "1" ] || { say "skipping udev fix (--no-udev-fix)"; return; }
    say "udev seat-tag drop-in"
    local rule=/etc/udev/rules.d/99-cosmic-seat.rules
    if [ -e "$rule" ] && grep -q "TAG+=\"seat\"" "$rule"; then
        ok "seat-tag drop-in already present"
    else
        cat > "$rule" <<'EOF'
# Workaround for Alpine's stock 71-seat.rules not tagging /dev/input/event*
# child devices.  Without the seat tag, libseat / seatd refuses to grant
# FDs for the keyboard and USB tablet to the COSMIC compositor, leaving
# inputs dead in the greeter.  See setup-cosmic-alpine.sh for details.
SUBSYSTEM=="input", KERNEL=="event*", TAG+="seat"
KERNEL=="event*", SUBSYSTEM=="input", ENV{ID_SEAT}="seat0"
EOF
        ok "$rule written"
    fi
    if [ -e /etc/init.d/udev ]; then
        udevadm control --reload >/dev/null 2>&1 || true
        udevadm trigger --action=add /sys/class/input/event* >/dev/null 2>&1 || true
        udevadm settle >/dev/null 2>&1 || true
        ok "udev rules reloaded and event devices re-tagged"
    else
        warn "udev init script not present - rules will apply on next boot"
    fi
}

# ---------- sanity checks ----------
sanity_check() {
    say "sanity checks"
    local fail=0
    for svc in dbus polkit "$SEAT_MANAGER"; do
        if [ -e "/etc/init.d/$svc" ]; then
            if ! rc-service "$svc" status 2>/dev/null | grep -q started; then
                warn "$svc is installed but not started"
                fail=1
            fi
        fi
    done
    if [ -e /usr/bin/cosmic-comp ] && [ -e /usr/sbin/greetd ] && [ -e /usr/bin/cosmic-greeter ]; then
        ok "cosmic-comp, greetd, cosmic-greeter present"
    else
        warn "one of cosmic-comp / greetd / cosmic-greeter is missing"
        fail=1
    fi
    if [ -e /run/seatd.sock ] || [ -e /var/run/seatd.sock ]; then
        ok "seatd socket present"
    fi
    if [ "$DO_FLATPAK" = "1" ]; then
        if command -v flatpak >/dev/null 2>&1 \
            && flatpak remote-list --system 2>/dev/null | grep -q "^${FLATHUB_NAME}\b"; then
            ok "flatpak + flathub remote configured"
        else
            warn "flatpak or flathub remote missing"
            fail=1
        fi
    fi
    return $fail
}

# ---------- post-install summary ----------
post_summary() {
    cat <<EOF

${C_BOLD}${C_CYN}== setup-cosmic-alpine.sh complete ==${C_RST}

  Seat manager:   ${SEAT_MANAGER:-none}
  User:           ${TARGET_USER}
  Greeter:        $([ "$DO_GREETER" = "1" ] && echo cosmic-greeter on greetd || echo "disabled")
  Browser (apk):  ${BROWSER_PKG:-none}
  Flatpak:        $([ "$DO_FLATPAK" = "1" ] && echo "yes (flathub, system-wide)" || echo "disabled")
  Flatpak apps:   ${FLATPAK_APPS:-none}
  Bluetooth:      $([ "$DO_BLUETOOTH" = "1" ] && echo "bluez (bluetoothd enabled)" || echo "disabled")
  XDG user dirs:  $([ "$DO_XDG_USER_DIRS" = "1" ] && echo "yes (Documents/Downloads/...)" || echo "disabled")
  Bare metal:     $([ "$DO_BARE_METAL" = "1" ] && echo "yes (linux-firmware installed)" || echo "no (VM mode)")

${C_BOLD}Next steps${C_RST}
  1. ${C_BOLD}restart${C_RST} - 'reboot' or 'doas reboot'
  2. After boot, the COSMIC greeter appears on tty1
  3. Log in as ${TARGET_USER}
  4. First login creates ~/.config and ~/.local; subsequent logins are fast
  5. ${C_BOLD}cosmic-store${C_RST} now shows apps from flathub as well as the
     system repos; you can install more flatpaks from there.

${C_BOLD}Flatpak apps installed${C_RST}
$([ -n "$FLATPAK_APPS" ] && echo "  $FLATPAK_APPS" || echo "  (none)")

${C_BOLD}If keyboard/mouse don't work in the greeter${C_RST}
  * This script drops /etc/udev/rules.d/99-cosmic-seat.rules which fixes
    a known Alpine + COSMIC issue (libseat / seatd needs the seat tag
    on /dev/input/event* nodes).
  * If inputs are still dead, from an SSH session as root:
        udevadm control --reload
        udevadm trigger --action=add /sys/class/input/event*
        rc-service cosmic-greeter restart

${C_BOLD}If flatpak apps don't launch${C_RST}
  * The kernel must allow unprivileged user namespaces:
        sysctl kernel.unprivileged_userns_clone
        sysctl user.max_user_namespaces
  * Both should be non-zero.  If not, set them:
        echo 'kernel.unprivileged_userns_clone=1' > /etc/sysctl.d/99-flatpak.conf
        sysctl --system

${C_BOLD}Useful commands${C_RST}
  * rc-status default         - show enabled services
  * rc-service <name> status  - check a service
  * loginctl list-sessions    - see active Wayland sessions
  * cat /var/log/messages     - COSMIC / greetd / seatd logs (logger -t)
  * flatpak list              - see installed flatpak apps
  * flatpak run <app-id>      - launch a flatpak from the shell

  Log of this run: ${LOG}
EOF
}

# ---------- main ----------
main() {
    log "=== ${SCRIPT_NAME} start (user=$TARGET_USER, seat=$SEAT_MANAGER) ==="
    preflight
    ensure_repos
    install_prereqs
    enable_prereq_services
    detect_or_install_seat_manager
    align_polkit_to_seat
    ensure_user
    install_cosmic_packages
    install_optional_apps
    install_flatpak
    cleanup_competing_dms
    udev_seat_tag_fix
    install_and_configure_greeter
    fix_cosmic_greeter_runtime
    align_cosmic_greeter_initd
    install_bluetooth_stack
    setup_xdg_user_dirs
    populate_appstream_cache
    # cosmic-greeter's package creates its service-account user.  If that
    # happened during install_cosmic_packages (which runs before the
    # cosmic-greeter group fix in ensure_user), fix it now.  Idempotent.
    fix_cosmic_greeter_user_groups
    if ! sanity_check; then
        warn "sanity check reported issues - see above"
    fi
    post_summary
    if [ "$DO_REBOOT" = "1" ]; then
        say "restarting in 5 seconds (Ctrl-C to cancel)"
        sleep 5
        log "restarting"
        reboot
    else
        log "done (--no-reboot)"
    fi
}

main "$@"
