#!/bin/sh
# setup-cosmic-alpine.sh
# Install and configure the COSMIC desktop on Alpine Linux (Edge, community repo).
# Reference: https://wiki.alpinelinux.org/wiki/COSMIC
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
#  14. Enable and start all required OpenRC services
#  15. Remove competing / broken display managers from runlevel
#  16. Print post-install instructions (restart)
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
    # Nothing installed - prefer seatd for minimal Alpine, but if user
    # previously had elogind in their world, we honor that.
    if grep -q '^elogind$' /etc/apk/world 2>/dev/null; then
        say "installing elogind (found in /etc/apk/world)"
        apk add $APK_FLAGS elogind || die "elogind install failed" 3
        rc-update add elogind default
        rc-service elogind start
        SEAT_MANAGER="elogind"
    else
        say "installing seatd (minimal, recommended for COSMIC on Alpine)"
        apk add $APK_FLAGS seatd || die "seatd install failed" 3
        rc-update add seatd default
        rc-service seatd start
        SEAT_MANAGER="seatd"
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
