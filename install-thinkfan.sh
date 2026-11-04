#!/usr/bin/env bash
# ============================================================================
#  install-thinkfan.sh 1.0.0: install thinkfan (one time, with sudo)
# ============================================================================
#  Sets up:
#    1. /usr/local/bin/thinkfan          user script (+ symlink /usr/local/bin/fan)
#    2. /usr/local/sbin/thinkfan-root    root helper for privileged access
#    3. /etc/sudoers.d/thinkfan          NOPASSWD for this helper only
#    4. /etc/thinkfan/thinkfan.conf        thresholds/actions (only if missing)
#    5. /etc/modprobe.d/thinkpad_acpi.conf   fan_control=1 (persistent, on ThinkPads)
#    6. /etc/systemd/system/thinkfan-guard.service   guard as a system service
#
#  Usage:   sudo ./install-thinkfan.sh [--user NAME] [--no-service] [--no-module-reload]
#                                    [--dry-run] [--uninstall]
#
#  Without arguments the calling user (SUDO_USER) is registered as the
#  authorized user. Exactly that user may run thinkfan commands without a
#  password afterwards, and nobody else.
# ============================================================================
set -uo pipefail

VERSION="1.0.0"
SRC_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BIN=${BIN:-/usr/local/bin/thinkfan}
BIN_LINK=${BIN_LINK:-/usr/local/bin/fan}
HELPER=${HELPER:-/usr/local/sbin/thinkfan-root}
SUDOERS=${SUDOERS:-/etc/sudoers.d/thinkfan}
CONF_DIR=${CONF_DIR:-/etc/thinkfan}
CONF=$CONF_DIR/thinkfan.conf
MODPROBE=${MODPROBE:-/etc/modprobe.d/thinkpad_acpi.conf}
UNIT=${UNIT:-/etc/systemd/system/thinkfan-guard.service}
STATE_DIR=${STATE_DIR:-/var/lib/thinkfan}

TARGET_USER=""
WITH_SERVICE=1
MODULE_RELOAD=1
DRY_RUN=0
UNINSTALL=0
SANDBOX=0

info() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# visudo often lives in /usr/sbin and is not in a normal user's PATH
VISUDO=$(command -v visudo 2>/dev/null || true)
[ -n "$VISUDO" ] || VISUDO=/usr/sbin/visudo
[ -x "$VISUDO" ] || VISUDO=""

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# install with an owner change only when we really are root
inst() { # $1 = mode, $2 = source, $3 = target
    local own=()
    if [ "$(id -u)" -eq 0 ]; then own=(-o root -g root); fi
    mkdir -p -- "$(dirname -- "$3")" || die "cannot create $(dirname -- "$3")"
    install "${own[@]}" -m "$1" "$2" "$3"
}

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
    --user)
        TARGET_USER=${2:-}
        [ -n "$TARGET_USER" ] || die "--user needs a name"
        shift
        ;;
    --no-service) WITH_SERVICE=0 ;;
    --no-module-reload) MODULE_RELOAD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --sandbox)
        # Testing only: puts every target below one directory, without systemd
        # or modprobe and without requiring root. Does not touch the real system.
        SANDBOX_DIR=${2:-}
        [ -n "$SANDBOX_DIR" ] || die "--sandbox needs a directory"
        SANDBOX=1
        BIN="$SANDBOX_DIR/usr/local/bin/thinkfan"
        BIN_LINK="$SANDBOX_DIR/usr/local/bin/fan"
        HELPER="$SANDBOX_DIR/usr/local/sbin/thinkfan-root"
        SUDOERS="$SANDBOX_DIR/etc/sudoers.d/thinkfan"
        CONF_DIR="$SANDBOX_DIR/etc/thinkfan"
        CONF=$CONF_DIR/thinkfan.conf
        MODPROBE="$SANDBOX_DIR/etc/modprobe.d/thinkpad_acpi.conf"
        UNIT="$SANDBOX_DIR/etc/systemd/system/thinkfan-guard.service"
        STATE_DIR="$SANDBOX_DIR/var/lib/thinkfan"
        shift
        ;;
    -h | --help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

# --- Who may go without a password later? -----------------------------------
detect_user() {
    [ -n "$TARGET_USER" ] && return 0
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        TARGET_USER=$SUDO_USER
        return 0
    fi
    # Fallback: the only user with UID >= 1000 and a home directory
    local cand
    for cand in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
        [ -d "/home/$cand" ] || continue
        if [ -n "$TARGET_USER" ]; then
            TARGET_USER=""
            warn "several users found, please pass --user NAME"
            return 1
        fi
        TARGET_USER=$cand
    done
    [ -n "$TARGET_USER" ] || { warn "no user detected, please pass --user NAME"; return 1; }
}

if [ "$UNINSTALL" = 1 ]; then
    [ "$(id -u)" -eq 0 ] || [ "$SANDBOX" = 1 ] || exec sudo -- "$0" "$@"
    info "Removing thinkfan"
    if [ "$SANDBOX" != 1 ]; then
        run systemctl disable --now thinkfan-guard 2>/dev/null
    fi
    run rm -f "$UNIT" "$BIN" "$BIN_LINK" "$HELPER" "$SUDOERS" "$MODPROBE"
    [ "$SANDBOX" = 1 ] || run systemctl daemon-reload
    printf '    Kept: %s and %s (log/state in %s)\n' "$CONF" "$STATE_DIR" "$STATE_DIR"
    printf '    To remove everything:  sudo rm -rf %s %s\n' "$CONF" "$STATE_DIR"
    exit 0
fi

if [ "$DRY_RUN" != 1 ] && [ "$SANDBOX" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    info "Restarting with sudo (one password prompt)..."
    exec sudo -- "$0" "$@"
fi

detect_user || exit 1
id "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' does not exist"

info "Source: $SRC_DIR"
info "Target user (may go without a password later): $TARGET_USER"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN: nothing will be written"

for f in thinkfan thinkfan-root thinkfan.conf; do
    [ -f "$SRC_DIR/$f" ] || die "$SRC_DIR/$f is missing, please unpack the complete package"
done

# --- 1./2. scripts ----------------------------------------------------------
info "Installing $BIN and $BIN_LINK"
if [ "$DRY_RUN" = 1 ]; then
    printf '    [dry-run] install -m 0755 %s %s\n' "$SRC_DIR/thinkfan" "$BIN"
    printf '    [dry-run] ln -sfn %s %s\n' "$BIN" "$BIN_LINK"
else
    inst 0755 "$SRC_DIR/thinkfan" "$BIN"
    ln -sfn "$BIN" "$BIN_LINK"
fi
info "Installing $HELPER (only this helper gets NOPASSWD)"
if [ "$DRY_RUN" = 1 ]; then
    printf '    [dry-run] install -m 0755 %s %s\n' "$SRC_DIR/thinkfan-root" "$HELPER"
else
    inst 0755 "$SRC_DIR/thinkfan-root" "$HELPER"
fi

# --- 3. sudoers -------------------------------------------------------------
# Deliberately ONLY the helper, without wildcards. NEVER add something like
#   "NOPASSWD: /usr/bin/tee"  or  "NOPASSWD: /usr/bin/*", that would be a
#   root hole. The helper validates its own arguments.
info "Writing $SUDOERS"
if [ "$DRY_RUN" = 1 ]; then
    printf '    [dry-run] Cmnd_Alias THINKFAN_ROOT = %s\n' "$HELPER"
    printf '    [dry-run] %s ALL=(root) NOPASSWD: THINKFAN_ROOT\n' "$TARGET_USER"
else
    tmp=$(mktemp) || die "mktemp failed"
    {
        printf '# thinkfan: passwordless fan/thermal control for %s\n' "$TARGET_USER"
        printf '# Only the root helper with its fixed command set is allowed.\n'
        printf 'Cmnd_Alias THINKFAN_ROOT = %s\n' "$HELPER"
        printf '%s ALL=(root) NOPASSWD: THINKFAN_ROOT\n' "$TARGET_USER"
    } >"$tmp"
    if [ -n "$VISUDO" ]; then
        "$VISUDO" -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers file is syntactically wrong, nothing installed"; }
    else
        warn "visudo not found, syntax check of the sudoers file skipped"
    fi
    mkdir -p -- "$(dirname -- "$SUDOERS")"
    install -m 0440 "$tmp" "$SUDOERS"
    rm -f "$tmp"
    if [ -n "$VISUDO" ] && [ "$SANDBOX" != 1 ]; then
        "$VISUDO" -c >/dev/null || die "sudoers configuration is broken now! Please check: $VISUDO"
    fi
fi

# --- 4. configuration -------------------------------------------------------
run mkdir -p "$CONF_DIR"
if [ -f "$CONF" ]; then
    info "$CONF already exists, not overwriting it"
else
    info "Installing $CONF"
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] install -m 0644 %s %s\n' "$SRC_DIR/thinkfan.conf" "$CONF"
    else
        inst 0644 "$SRC_DIR/thinkfan.conf" "$CONF"
    fi
fi
run mkdir -p "$STATE_DIR"
run chmod 0750 "$STATE_DIR"

# --- 5. thinkpad_acpi -------------------------------------------------------
if [ -d /sys/module/thinkpad_acpi ]; then
    fanctl_active=0
    grep -q '^commands:' /proc/acpi/ibm/fan 2>/dev/null && fanctl_active=1
    if [ "$fanctl_active" = 1 ]; then
        info "thinkpad_acpi already runs with fan_control=1, all good"
    else
        info "Enabling fan_control=1 in $MODPROBE"
        if [ "$DRY_RUN" = 1 ]; then
            printf '    [dry-run] printf "options thinkpad_acpi fan_control=1\\n" > %s\n' "$MODPROBE"
        else
            mkdir -p -- "$(dirname -- "$MODPROBE")"
            printf 'options thinkpad_acpi fan_control=1\n' >"$MODPROBE"
        fi
        if [ "$MODULE_RELOAD" = 1 ] && [ "$DRY_RUN" != 1 ] && [ "$SANDBOX" != 1 ]; then
            info "Reloading thinkpad_acpi (briefly without the hotkey handler, among others)"
            modprobe -r thinkpad_acpi 2>/dev/null
            modprobe thinkpad_acpi || warn "modprobe thinkpad_acpi failed"
            sleep 1
            if grep -q '^commands:' /proc/acpi/ibm/fan 2>/dev/null; then
                info "Fan control is active now"
            else
                warn "fan_control not active yet, it will apply after the next reboot at the latest"
            fi
        else
            warn "A reboot is required for fan_control=1 to take effect"
        fi
    fi
else
    warn "thinkpad_acpi is not loaded, this machine has no ThinkPad fan control"
    warn "(temperature monitoring and the guard still work)"
fi

# --- 6. systemd service -----------------------------------------------------
if [ "$WITH_SERVICE" = 1 ]; then
    info "Setting up the guard service: thinkfan-guard (runs as root, needs no sudo)"
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] write %s and enable/start\n' "$UNIT"
    else
        mkdir -p -- "$(dirname -- "$UNIT")"
        cat >"$UNIT" <<EOF
[Unit]
Description=thinkfan guard (fan and thermal monitoring with countermeasures)
After=multi-user.target

[Service]
Type=simple
ExecStart=$BIN --guard
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
Nice=-5
# The guard may only write through the helper; /proc and /sys must be writable
ProtectSystem=full
ReadWritePaths=/proc/acpi /sys/devices/system/cpu /var/lib/thinkfan
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$UNIT"
        if [ "$SANDBOX" = 1 ]; then
            info "(sandbox: systemd is not touched)"
        else
            systemctl daemon-reload
            systemctl enable --now thinkfan-guard || warn "thinkfan-guard could not be started"
            sleep 2
            systemctl is-active --quiet thinkfan-guard && info "Guard is running" ||
                warn "Guard is not running, details: journalctl -u thinkfan-guard -n 30"
        fi
    fi
fi

# --- Verify -----------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
    if [ "$SANDBOX" != 1 ]; then
        info "Checking passwordless access for $TARGET_USER"
        if runuser -u "$TARGET_USER" -- sudo -n "$HELPER" selftest 2>/dev/null; then
            info "OK: $TARGET_USER may run thinkfan commands without a password"
        else
            warn "NOPASSWD test failed, please check: sudo -l -U $TARGET_USER"
        fi
    fi
    info "Fan and sensor report:"
    "$BIN" --probe | sed 's/^/    /'
fi

cat <<EOF

Done. Quick use:
    fan --status              overview: fan and temperatures
    fan --watch               live view
    fan --auto | --full | -l 5      fan mode without a password
    fan --check ; echo \$?     exit 0/1/2 (ok/warm/critical)
    fan --guard --dry-run     test the guard without changing anything
    systemctl status thinkfan-guard ; journalctl -u thinkfan-guard -f
    fan --log 50              guard log
Adjust thresholds:   sudo nano $CONF
Uninstall:           sudo $0 --uninstall
EOF
