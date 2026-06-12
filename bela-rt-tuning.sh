#!/bin/bash
#
# bela-rt-tuning.sh — "RT appliance mode" toggle for an embedded board
# (Bela / BeagleBone class, Debian Bookworm) running a real-time audio
# engine such as Sushi.
#
#   bela-rt-tuning.sh on      # apply all tunings (persistent + live)
#   bela-rt-tuning.sh off     # revert everything to distro defaults
#   bela-rt-tuning.sh status  # one line per knob with [on]/[off] + why
#
# Rationale: at tight buffer budgets (<= 0.7 ms) audio underruns correlate
# with SD/MMC traffic — journald fsync, ext4 journal commits, atime updates.
# These knobs remove or batch that background I/O so the card stays quiet
# while the RT graph runs.
#
# What it manages (each clearly labeled below, idempotent both ways):
#   1. journald volatile storage — system logs live in RAM and are LOST AT
#      REBOOT (accepted appliance tradeoff); removes journald's periodic
#      fsync/rotate traffic to the SD card.
#   2. rootfs mount options — noatime (no inode write on every file read)
#      + commit=60 (ext4 flushes its journal every 60 s instead of 5 s;
#      up to 60 s of writes can be lost on power cut).
#   3. sysctls — slower vmstat sampling, longer dirty-page writeback
#      interval, timer migration off (timers stay on their own core).
#   4. Wi-Fi power save off — PS-poll wakeup cycles cause periodic wlan
#      latency spikes; persisted via a tiny systemd oneshot unit.
#   5. iwd quiet scans — iwd background and roaming scan loops cause USB/bus
#      traffic bursts (rtw88 firmware activity) that stall RT audio at
#      sub-ms budgets; DisablePeriodicScan + DisableRoamingScan silence them.
#      WARNING: restarting iwd briefly drops connectivity — acceptable at
#      provision time.
#
# Recommended but NOT enforced here: point the audio engine's own logs at
# a tmpfs (/dev/shm or /tmp) — that concern belongs to the host start
# scripts, not to this system-level toggle.
#
set -u

JOURNALD_DROPIN=/etc/systemd/journald.conf.d/10-rt-volatile.conf
SYSCTL_FILE=/etc/sysctl.d/90-rt-audio.conf
FSTAB=/etc/fstab
FSTAB_BACKUP=/etc/fstab.pre-rt-tuning
WIFI_UNIT=/etc/systemd/system/wifi-powersave-off.service
WLAN_IF=wlan0
IWD_CONF=/etc/iwd/main.conf

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. journald volatile storage
#    on : logs in RAM only (lost at reboot) -> no journal fsync SD traffic
#    off: back to persistent /var/log/journal
# ---------------------------------------------------------------------------
journald_on() {
    if [ -f "$JOURNALD_DROPIN" ] && grep -q '^Storage=volatile$' "$JOURNALD_DROPIN"; then
        echo "journald: already volatile"
        return
    fi
    mkdir -p "$(dirname "$JOURNALD_DROPIN")"
    printf '[Journal]\nStorage=volatile\n' > "$JOURNALD_DROPIN"
    systemctl restart systemd-journald
    echo "journald: volatile (logs in RAM, lost at reboot)"
}

journald_off() {
    if [ ! -f "$JOURNALD_DROPIN" ]; then
        echo "journald: already persistent"
        return
    fi
    rm -f "$JOURNALD_DROPIN"
    systemctl restart systemd-journald
    echo "journald: persistent (distro default)"
}

# ---------------------------------------------------------------------------
# 2. rootfs mount options (noatime + commit=60)
#    on : back up /etc/fstab once, add the options to the root line only,
#         remount live
#    off: restore the pre-tuning fstab, remount with the original options
# ---------------------------------------------------------------------------
root_opts() {  # current root-line mount options from a given fstab
    awk '$1 !~ /^#/ && $2 == "/" { print $4; exit }' "$1"
}

fstab_on() {
    local cur new
    cur="$(root_opts "$FSTAB")"
    [ -n "$cur" ] || { echo "fstab: no '/' line found — skipping" >&2; return 1; }
    new="$cur"
    case ",$new," in *,noatime,*) ;; *) new="$new,noatime" ;; esac
    case ",$new," in *,commit=*) ;; *) new="$new,commit=60" ;; esac
    if [ "$new" != "$cur" ]; then
        [ -f "$FSTAB_BACKUP" ] || cp "$FSTAB" "$FSTAB_BACKUP"
        # conservative: rewrite only the options field of the root line
        sed -i -E "s@^([^#[:space:]]+[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)${cur}@\1${new}@" "$FSTAB"
        echo "fstab: / options -> ${new} (backup: ${FSTAB_BACKUP})"
    else
        echo "fstab: / already has noatime + commit="
    fi
    mount -o remount,noatime,commit=60 /
    echo "rootfs: remounted noatime,commit=60 (up to 60 s of writes lost on power cut)"
}

fstab_off() {
    local orig
    if [ -f "$FSTAB_BACKUP" ]; then
        orig="$(root_opts "$FSTAB_BACKUP")"
        cp "$FSTAB_BACKUP" "$FSTAB"
        rm -f "$FSTAB_BACKUP"
        echo "fstab: restored from ${FSTAB_BACKUP}"
    else
        orig="$(root_opts "$FSTAB")"
        echo "fstab: no backup found — leaving file as-is"
    fi
    # re-apply the original options live; force commit back to the ext4
    # default (5 s) if the original line did not pin one
    case ",$orig," in *,commit=*) ;; *) orig="$orig,commit=5" ;; esac
    mount -o "remount,$orig" /
    echo "rootfs: remounted ($orig)"
}

# ---------------------------------------------------------------------------
# 3. sysctls
#    vm.stat_interval=120            (vmstat sampling 1 s -> 120 s)
#    vm.dirty_writeback_centisecs=6000  (dirty flusher 5 s -> 60 s)
#    kernel.timer_migration=0        (timers stay on their own core)
# ---------------------------------------------------------------------------
sysctl_on() {
    cat > "$SYSCTL_FILE" <<'EOF'
# RT audio appliance tuning: batch kernel housekeeping, keep timers local
vm.stat_interval = 120
vm.dirty_writeback_centisecs = 6000
kernel.timer_migration = 0
EOF
    sysctl --system >/dev/null
    echo "sysctls: stat_interval=120 dirty_writeback=6000 timer_migration=0"
}

sysctl_off() {
    rm -f "$SYSCTL_FILE"
    sysctl -w vm.stat_interval=1 \
              vm.dirty_writeback_centisecs=500 \
              kernel.timer_migration=1 >/dev/null
    echo "sysctls: restored defaults (1 / 500 / 1)"
}

# ---------------------------------------------------------------------------
# 4. Wi-Fi power save off (reduces wlan latency spikes), persisted via a
#    systemd oneshot so it survives reboots
# ---------------------------------------------------------------------------
wifi_on() {
    if ! command -v iw >/dev/null || ! iw dev "$WLAN_IF" info >/dev/null 2>&1; then
        echo "wifi: no ${WLAN_IF} / iw — skipping"
        return
    fi
    iw dev "$WLAN_IF" set power_save off
    cat > "$WIFI_UNIT" <<EOF
[Unit]
Description=Disable Wi-Fi power save on ${WLAN_IF} (RT audio latency)
After=network.target

[Service]
Type=oneshot
ExecStart=$(command -v iw) dev ${WLAN_IF} set power_save off

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wifi-powersave-off.service >/dev/null 2>&1
    echo "wifi: power_save off (persisted via wifi-powersave-off.service)"
}

wifi_off() {
    if [ -f "$WIFI_UNIT" ]; then
        systemctl disable wifi-powersave-off.service >/dev/null 2>&1
        rm -f "$WIFI_UNIT"
        systemctl daemon-reload
    fi
    if command -v iw >/dev/null && iw dev "$WLAN_IF" info >/dev/null 2>&1; then
        iw dev "$WLAN_IF" set power_save on
        echo "wifi: power_save on (distro default)"
    else
        echo "wifi: no ${WLAN_IF} / iw — nothing to revert"
    fi
}

# ---------------------------------------------------------------------------
# 5. iwd quiet scans — disable periodic + roaming background scan loops in
#    iwd; these cause USB/bus traffic bursts (rtw88 firmware activity) that
#    stall RT audio at sub-ms budgets.
#    on : set DisablePeriodicScan=true + DisableRoamingScan=true in
#         /etc/iwd/main.conf [Scan] section; restart iwd.
#         WARNING: restarting iwd briefly drops connectivity — fine at
#         provision time.
#    off: set both keys to false; restart iwd.
# Uses python3 configparser so the ini file is edited safely and any other
# sections/keys already in the file are preserved.
# ---------------------------------------------------------------------------
_iwd_set_keys() {     # args: val_periodic val_roaming   (true|false)
    local vp="$1" vr="$2"
    mkdir -p "$(dirname "$IWD_CONF")"
    python3 - "$IWD_CONF" "$vp" "$vr" <<'PYEOF'
import sys, configparser, os

path, vp, vr = sys.argv[1], sys.argv[2], sys.argv[3]

cfg = configparser.RawConfigParser()
cfg.optionxform = str          # preserve key case
if os.path.exists(path):
    cfg.read(path)

if not cfg.has_section('Scan'):
    cfg.add_section('Scan')

cfg.set('Scan', 'DisablePeriodicScan', vp)
cfg.set('Scan', 'DisableRoamingScan',  vr)

with open(path, 'w') as fh:
    cfg.write(fh)
PYEOF
}

iwd_on() {
    _iwd_set_keys true true
    if systemctl is-active --quiet iwd 2>/dev/null; then
        systemctl restart iwd
        echo "iwd-quiet-scans: DisablePeriodicScan=true DisableRoamingScan=true (iwd restarted)"
    else
        echo "iwd-quiet-scans: DisablePeriodicScan=true DisableRoamingScan=true (iwd not running — config written)"
    fi
}

iwd_off() {
    _iwd_set_keys false false
    if systemctl is-active --quiet iwd 2>/dev/null; then
        systemctl restart iwd
        echo "iwd-quiet-scans: DisablePeriodicScan=false DisableRoamingScan=false (iwd restarted)"
    else
        echo "iwd-quiet-scans: DisablePeriodicScan=false DisableRoamingScan=false (iwd not running — config written)"
    fi
}

# ---------------------------------------------------------------------------
# status — live state of every knob, one line each, [on]/[off] + why
# ---------------------------------------------------------------------------
status() {
    local storage opts s1 s2 s3 ps iwd_per iwd_roam mark

    # journald: effective Storage= (cat-config if available, else drop-in)
    storage="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
               | grep -E '^Storage=' | tail -1 | cut -d= -f2)"
    if [ -z "$storage" ]; then
        [ -f "$JOURNALD_DROPIN" ] && storage=volatile || storage=auto
    fi
    [ "$storage" = volatile ] && mark='[on] ' || mark='[off]'
    printf 'journald-volatile  %s Storage=%s, %s — volatile = logs in RAM, lost at reboot; kills journal fsync SD traffic\n' \
        "$mark" "$storage" "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT](iB|B)?' | head -1)"

    # rootfs mount options
    opts="$(findmnt -no OPTIONS / 2>/dev/null)"
    case ",$opts," in
        *,noatime,*) case ",$opts," in *,commit=60,*) mark='[on] ' ;; *) mark='[off]' ;; esac ;;
        *) mark='[off]' ;;
    esac
    printf 'rootfs-mount-opts  %s live: %s — noatime+commit=60 batch ext4 journal/metadata writes (60 s loss window on power cut)\n' \
        "$mark" "$opts"

    # sysctls
    s1="$(sysctl -n vm.stat_interval)"
    s2="$(sysctl -n vm.dirty_writeback_centisecs)"
    s3="$(sysctl -n kernel.timer_migration)"
    if [ "$s1" = 120 ] && [ "$s2" = 6000 ] && [ "$s3" = 0 ]; then mark='[on] '; else mark='[off]'; fi
    printf 'sysctls            %s stat_interval=%s dirty_writeback_cs=%s timer_migration=%s — less periodic kernel housekeeping on RT cores\n' \
        "$mark" "$s1" "$s2" "$s3"

    # wifi power save
    if command -v iw >/dev/null && iw dev "$WLAN_IF" info >/dev/null 2>&1; then
        ps="$(iw dev "$WLAN_IF" get power_save 2>/dev/null)"   # "Power save: off"
        case "$ps" in *off) mark='[on] ' ;; *) mark='[off]' ;; esac
        printf 'wifi-powersave-off %s %s (unit: %s) — PS-poll wakeups cause periodic wlan latency spikes\n' \
            "$mark" "$ps" "$(systemctl is-enabled wifi-powersave-off.service 2>/dev/null || echo absent)"
    else
        printf 'wifi-powersave-off [off] no %s interface — nothing to manage\n' "$WLAN_IF"
    fi

    # iwd quiet scans
    if [ -f "$IWD_CONF" ]; then
        iwd_per="$(python3 -c "
import configparser
c = configparser.RawConfigParser(); c.optionxform = str; c.read('$IWD_CONF')
print(c.get('Scan','DisablePeriodicScan',fallback='absent').lower())
" 2>/dev/null)"
        iwd_roam="$(python3 -c "
import configparser
c = configparser.RawConfigParser(); c.optionxform = str; c.read('$IWD_CONF')
print(c.get('Scan','DisableRoamingScan',fallback='absent').lower())
" 2>/dev/null)"
    else
        iwd_per=absent; iwd_roam=absent
    fi
    if [ "$iwd_per" = true ] && [ "$iwd_roam" = true ]; then mark='[on] '; else mark='[off]'; fi
    printf 'iwd-quiet-scans    %s DisablePeriodicScan=%s DisableRoamingScan=%s — iwd background/roaming scans cause USB/bus traffic bursts (rtw88 firmware activity) that stall RT audio at sub-ms budgets\n' \
        "$mark" "$iwd_per" "$iwd_roam"
}

case "${1:-}" in
    on)     journald_on; fstab_on; sysctl_on; wifi_on; iwd_on ;;
    off)    journald_off; fstab_off; sysctl_off; wifi_off; iwd_off ;;
    status) status ;;
    *)      echo "Usage: $0 on|off|status" >&2; exit 2 ;;
esac
