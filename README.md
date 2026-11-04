# thinkfan

Fan control, thermal monitoring and an automatic guard for **ThinkPads** on Linux.

`thinkfan` changes the fan level without asking for a password every time, shows
every temperature the machine offers, and runs a guard that reacts to heat on
its own: it raises the fan, caps the CPU clock, disables turbo and slows down
CPU hogs, then rolls all of that back once the system cools down.

> **Device support**
> Fan control works only on ThinkPads whose `thinkpad_acpi` driver allows manual
> fan levels. That is the case when `/proc/acpi/ibm/fan` exists and contains a
> `commands:` line after the module was loaded with `fan_control=1`. Many
> ThinkPads support this, some models block manual fan control in the embedded
> controller. Everything else in this project is not tied to a specific model.
> Temperature monitoring and the CPU part of the guard also work on other Linux
> laptops, the fan commands are simply skipped there. Windows, macOS and BSD are
> not supported.

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)

## Features

- Fan modes: `auto`, fixed levels `1` to `7`, and `disengaged` (full speed)
- Temperatures from CPU, GPU, NVMe, battery, ACPI thermal zones and the ThinkPad EC
- `--status` snapshot and `--watch` live view
- `--check` for cron or chat notifications, with exit codes `0` (ok), `1` (warm), `2` (critical)
- JSON output for scripts and integrations
- Guard with escalation, hysteresis and automatic rollback
- Optional desktop notifications and a custom notification command
- No password prompts after a one time install
- Works on non-ThinkPads for monitoring and CPU measures, fan commands are simply skipped

## How it works

```text
thinkfan              user command, runs as your user
  |
  +-- thinkfan-root   small root helper, the only sudo NOPASSWD entry
  |
  +-- thinkfan-guard  optional systemd service, runs as root
```

`/proc/acpi/ibm/fan` belongs to root and cannot be opened up through a group or
udev rule. `thinkfan` therefore ships a small helper, `thinkfan-root`, which accepts
a fixed set of commands with strictly validated arguments. That helper is the
only binary allowed in `/etc/sudoers.d/thinkfan`. Details are in
[Security model](#security-model).

## Requirements

- Linux with `bash`, `systemd` and `sudo`
- A ThinkPad with `thinkpad_acpi` for fan control
- Root access once, for the installer

Tested on Debian 13 for monitoring and guard logic. The fan write path needs a
ThinkPad and should be verified on the target machine with `thinkfan --probe`.

## Device compatibility

| Device | Fan control | Monitoring and guard |
|---|---|---|
| ThinkPad with `thinkpad_acpi`, `fan_control=1` and a `commands:` line in `/proc/acpi/ibm/fan` | yes | yes |
| ThinkPad that blocks manual fan levels in the EC | no | yes |
| Other Linux laptop | no | yes |
| Desktop or virtual machine | no | yes, with fewer sensors |

Check the machine after the install:

```bash
thinkfan --probe
grep '^commands:' /proc/acpi/ibm/fan
```

If the second command prints nothing, the embedded controller does not allow
manual fan levels on this model. The guard still works through the CPU, but it
cannot spin the fan up.

## Installation

```bash
git clone https://github.com/YOUR-NAME/thinkfan.git
cd thinkfan
sudo ./install-thinkfan.sh
```

The installer performs these steps:

1. Copies `thinkfan` to `/usr/local/bin/thinkfan` and creates the `fan` symlink.
2. Copies `thinkfan-root` to `/usr/local/sbin/thinkfan-root`.
3. Writes `/etc/sudoers.d/thinkfan` with `NOPASSWD` for the helper only. The file
   is checked with `visudo -cf` and installed with mode `0440`.
4. Installs `/etc/thinkfan/thinkfan.conf` if no configuration exists yet.
5. Writes `/etc/modprobe.d/thinkpad_acpi.conf` with
   `options thinkpad_acpi fan_control=1`, so fan control survives reboots.
6. Installs and starts `thinkfan-guard.service`.
7. Verifies that passwordless access works for your user.

Options:

```text
--user NAME           user who may run thinkfan without a password
--no-service          do not install the systemd service
--no-module-reload    do not reload thinkpad_acpi during install
--dry-run             show what would happen, change nothing
--uninstall           remove files, service and sudoers entry
--sandbox DIR         test install into DIR without root or systemd
```

## Usage

```bash
fan --status              # snapshot: fan and all temperatures
fan --watch 3             # live view, refresh every 3 seconds
fan --probe               # what was found on this machine
fan --auto                # back to automatic fan control
fan --full                # full speed (disengaged)
fan -l 5                  # fixed fan level 1 to 7
fan --check               # one measurement, exit 0/1/2
fan --check --json        # machine readable output
fan --guard --once        # one guard evaluation, then exit
fan --guard --dry-run     # show what the guard would do
fan --log 50              # last 50 log lines
fan --show-config         # effective settings
```

`fan` is a symlink to `thinkfan`, both names work.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | normal |
| 1 | warm |
| 2 | critical |
| 3 | error, for example no fan interface |
| 64 | bad arguments |

## The guard

Every `POLL` seconds (default 5) the guard compares all sensors against their
thresholds. If a role crosses its warn threshold it escalates to level 1, if it
crosses its critical threshold it escalates to level 2.

| Level | Fan | CPU | Processes | Notification |
|---|---|---|---|---|
| 1 (warm) | `FAN_LEVEL_WARN` (5) | clock capped at 90% | none | log and `NOTIFY_CMD` |
| 2 (critical) | `FAN_LEVEL_CRIT` (7) | clock capped at 65%, turbo off, optional `powersave` governor | CPU hogs above `RENICE_MIN_CPU`% get nice 19, optional SIGTERM | log and `NOTIFY_CMD` |
| back to normal | `auto` | cap removed, turbo restored | nice restored | log |

A rollback happens only when **every** role is at least `HYSTERESIS` °C below
its threshold (default 4 °C), for `RECOVER_SAMPLES` measurements in a row
(default 6). That prevents flapping around a threshold. Two escalations are at
least `MIN_ESCALATE_INTERVAL` seconds apart.

Default thresholds in °C:

| Role | Warn | Critical | Source |
|---|---|---|---|
| cpu | 80 | 92 | k10temp, coretemp, x86_pkg_temp |
| gpu | 80 | 92 | amdgpu, radeon, nouveau, nvidia-smi |
| nvme | 70 | 82 | NVMe composite |
| bat | 45 | 55 | `/sys/class/power_supply/BAT*/temp` |
| acpi | 70 | 85 | ACPI thermal zones |
| ec | 80 | 92 | `/proc/acpi/ibm/thermal` (display only by default) |

On a ThinkPad the 65% clock cap can feel choppy. If that is too aggressive,
adjust `CPU_CAP_PCT_CRIT` and `FAN_LEVEL_*` in `/etc/thinkfan/thinkfan.conf` and
restart the service:

```bash
sudo systemctl restart thinkfan-guard
```

## Configuration

The system file is `/etc/thinkfan/thinkfan.conf`. A user file at
`~/.config/thinkfan/thinkfan.conf` overrides it.

The file is sourced as Bash. Keep it free of group and world write permissions,
otherwise `thinkfan` ignores it for security reasons.

Most useful settings:

```bash
POLL=5                       # seconds between measurements
WARN_CPU=80; CRIT_CPU=92     # thresholds per role
FAN_LEVEL_WARN=5             # fan level on warn
FAN_LEVEL_CRIT=7             # fan level on critical
CPU_CAP_PCT_CRIT=65          # CPU clock cap on critical
RENICE_ENABLED=1             # slow down CPU hogs
KILL_ENABLED=0               # send SIGTERM to hogs (off by default)
NOTIFY_CMD=""                # notification command
```

Every option is documented inline in `thinkfan.conf`.

## Telegram notifications

`NOTIFY_CMD` receives two arguments: the level (`0`, `1` or `2`) and a message.
A small script is enough:

```bash
mkdir -p ~/bin
cat >~/bin/telegram-notify.sh <<'EOF'
#!/bin/bash
TOKEN="<bot-token>"
CHAT="<chat-id>"
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
     -d chat_id="$CHAT" -d text="thinkfan level $1: $2" >/dev/null
EOF
chmod +x ~/bin/telegram-notify.sh
```

Then point the configuration at it:

```bash
sudo sed -i 's|^NOTIFY_CMD=.*|NOTIFY_CMD="/home/YOUR-NAME/bin/telegram-notify.sh"|' /etc/thinkfan/thinkfan.conf
sudo systemctl restart thinkfan-guard
```

The same pattern works for cron: `fan --check --json` prints the current values.

## Security model

`/proc/acpi/ibm/fan` is owned by root and its permissions cannot be changed
persistently. The common options are:

1. **Recommended:** a single `NOPASSWD` entry in `/etc/sudoers.d/thinkfan`, limited
   to one helper that knows only the allowed commands and validates every
   argument (`auto|full|disengaged|1..7`, kHz values, PIDs). No `tee`, no
   wildcards.
2. The guard as a systemd system service: it runs as root and does not need the
   sudo rule at all.

Do **not** use `NOPASSWD: /usr/bin/tee`, `NOPASSWD: ALL` or a wildcard such as
`/usr/local/sbin/thinkfan-root *`. Any of those would let a normal user become
root.

## Pausing the guard during a game or render

```bash
sudo systemctl stop thinkfan-guard      # clean exit, fan back to auto, caps removed
fan --full                            # maximum cooling manually
sudo systemctl start thinkfan-guard     # back to normal afterwards
```

## Testing without a ThinkPad

The scripts support simulated sensors, which is useful on a VM or a desktop:

```bash
THINKFAN_FAKE="cpu=95,gpu=97" fan --status
THINKFAN_FAKE="cpu=95,gpu=97" fan --guard --once
```

`THINKFAN_FAKE_FILE=/tmp/fake` reads the values from a file, so you can change them
while the guard is running. Set `POLL` and `RECOVER_SAMPLES` low in a test
configuration to see escalation and rollback within seconds.

The installer also has a sandbox mode that needs neither root nor systemd:

```bash
./install-thinkfan.sh --sandbox /tmp/thinkfan-test
```

`./selftest.sh` checks the syntax of all scripts, builds a release tarball,
unpacks it in `/tmp` and runs the basic commands.

## Troubleshooting

**Fan commands do nothing**

Check whether `thinkpad_acpi` was loaded with fan control enabled:

```bash
grep '^commands:' /proc/acpi/ibm/fan
```

If there is no output, make sure `/etc/modprobe.d/thinkpad_acpi.conf` contains
`options thinkpad_acpi fan_control=1` and reboot.

**No passwordless access**

```bash
sudo -l -U YOUR-NAME
sudo -n /usr/local/sbin/thinkfan-root selftest
```

The first command should list the helper as `NOPASSWD`, the second should print
`ok, running as uid 0`.

**The guard does not react**

```bash
systemctl status thinkfan-guard
journalctl -u thinkfan-guard -n 50
fan --probe
```

`fan --probe` shows which sensors and thresholds are active on this machine.

**No CPU cap on a VM or container**

There are no `cpufreq` policies inside most VMs. The guard logs this and
continues with fan and process measures.

## Uninstall

```bash
sudo ./install-thinkfan.sh --uninstall
```

This removes the scripts, the service, the sudoers entry and the modprobe file.
The configuration and the state directory are kept. Remove them manually if you
want a clean machine:

```bash
sudo rm -rf /etc/thinkfan /var/lib/thinkfan
```

## Project layout

```text
thinkfan                 main script: status, watch, check, guard
thinkfan-root            root helper with a fixed command set
thinkfan.conf            default configuration
install-thinkfan.sh      installer and uninstaller
selftest.sh            syntax check and package self test
```

## License

MIT, see [LICENSE](LICENSE).
