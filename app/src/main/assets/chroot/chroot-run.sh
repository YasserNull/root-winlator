#!/system/bin/sh
# root-winlator chroot helper (chroot-distro style with mandatory safe unmount).
#
# Usage:
#   chroot-run.sh mount <rootfs> <busybox> <uid> <gid> <state_dir> [--android-dirs [dirs...]] [--tmpfs-dirs [dirs...]]
#   chroot-run.sh run   <rootfs> <busybox> <app_pid> <env_b64> <cmd_b64> <uid> <gid> <state_dir> [--android-dirs [dirs...]] [--tmpfs-dirs [dirs...]]
#   chroot-run.sh stop  <rootfs> <busybox> <uid> <gid> <state_dir>
#
# Also supports passing <bind_ram> <bind_android> in positional order or replacing
# them directly with --android-dirs and --tmpfs-dirs.

set +e

NL='
'
SYSTEM_POINTS="/dev /sys /proc /dev/pts"
DEFAULT_TMPFS_DIRS="/tmp /run /var/tmp /dev/shm"

ACTION="$1"
ROOTFS="$2"
BB="$3"

[ -n "$ACTION" ] && [ -n "$ROOTFS" ] && [ -n "$BB" ] || exit 64
[ -x "$BB" ] || exit 65
shift 3

bb() { "$BB" "$@"; }
log() { echo "root-winlator: $*"; /system/bin/log -t RootWinlator "$*" 2>/dev/null; }

U=""
G=""
STATE_DIR=""
BIND_RAM=0
BIND_ANDROID=0
CUSTOM_ANDROID_DIRS=""
CUSTOM_TMPFS_DIRS=""
APP_PID=0
ENV_B64=""
CMD_B64=""
CHILD_PID=""

normalize_list() {
    bb printf '%s' "$1" | bb tr ',:\n\t' '    '
}

case "$ACTION" in
    mount)
        # Support both:
        #   mount <rootfs> <bb> <uid> <gid> <state_dir> [--android-dirs ...] [--tmpfs-dirs ...]
        # and legacy:
        #   mount <rootfs> <bb> <bind_ram> <bind_android> <uid> <gid> <state_dir> [--android-dirs ...] [--tmpfs-dirs ...]
        if [ $# -ge 5 ] && [ "${5#--}" = "$5" ] && { [ "$1" = "0" ] || [ "$1" = "1" ]; } && { [ "$2" = "0" ] || [ "$2" = "1" ]; }; then
            BIND_RAM="$1"
            BIND_ANDROID="$2"
            U="$3"
            G="$4"
            STATE_DIR="$5"
            shift 5
        elif [ $# -ge 3 ]; then
            U="$1"
            G="$2"
            STATE_DIR="$3"
            shift 3
        else
            exit 64
        fi
        ;;
    run)
        [ $# -ge 6 ] || exit 64
        APP_PID="$1"
        ENV_B64="$2"
        CMD_B64="$3"
        U="$4"
        G="$5"
        STATE_DIR="$6"
        shift 6
        if [ $# -ge 1 ] && { [ "$1" = "0" ] || [ "$1" = "1" ]; }; then
            BIND_RAM="$1"
            shift
        fi
        if [ $# -ge 1 ] && { [ "$1" = "0" ] || [ "$1" = "1" ]; }; then
            BIND_ANDROID="$1"
            shift
        fi
        ;;
    stop|umount|unmount)
        [ $# -ge 3 ] || exit 64
        U="$1"
        G="$2"
        STATE_DIR="$3"
        shift 3
        ;;
    *)
        exit 64
        ;;
esac

# Only parse --android-dirs and --tmpfs-dirs as requested
while [ $# -gt 0 ]; do
    case "$1" in
        --android-dirs)
            BIND_ANDROID=1
            shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
                case "$1" in
                    0|false|no|none)
                        BIND_ANDROID=0
                        CUSTOM_ANDROID_DIRS=""
                        ;;
                    1|true|yes|auto|default)
                        BIND_ANDROID=1
                        ;;
                    *)
                        CUSTOM_ANDROID_DIRS="$CUSTOM_ANDROID_DIRS $(normalize_list "$1")"
                        ;;
                esac
                shift
            done
            ;;
        --android-dirs=*)
            val="${1#*=}"
            shift
            case "$val" in
                0|false|no|none)
                    BIND_ANDROID=0
                    CUSTOM_ANDROID_DIRS=""
                    ;;
                1|true|yes|auto|default|"")
                    BIND_ANDROID=1
                    ;;
                *)
                    BIND_ANDROID=1
                    CUSTOM_ANDROID_DIRS="$CUSTOM_ANDROID_DIRS $(normalize_list "$val")"
                    ;;
            esac
            ;;
        --tmpfs-dirs)
            BIND_RAM=1
            shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
                case "$1" in
                    0|false|no|none)
                        BIND_RAM=0
                        CUSTOM_TMPFS_DIRS=""
                        ;;
                    1|true|yes|auto|default)
                        BIND_RAM=1
                        ;;
                    *)
                        CUSTOM_TMPFS_DIRS="$CUSTOM_TMPFS_DIRS $(normalize_list "$1")"
                        ;;
                esac
                shift
            done
            ;;
        --tmpfs-dirs=*)
            val="${1#*=}"
            shift
            case "$val" in
                0|false|no|none)
                    BIND_RAM=0
                    CUSTOM_TMPFS_DIRS=""
                    ;;
                1|true|yes|auto|default|"")
                    BIND_RAM=1
                    ;;
                *)
                    BIND_RAM=1
                    CUSTOM_TMPFS_DIRS="$CUSTOM_TMPFS_DIRS $(normalize_list "$val")"
                    ;;
            esac
            ;;
        *)
            log "unknown argument: $1"
            exit 64
            ;;
    esac
done

[ -n "$U" ] && [ -n "$G" ] && [ -n "$STATE_DIR" ] || exit 66
bb mkdir -p "$STATE_DIR" 2>/dev/null

STOP_FILE="$STATE_DIR/chroot.stop"
MOUNT_LIST_FILE="$STATE_DIR/chroot.mounts"
OWNER_MARK="$STATE_DIR/chroot.root-owned"

# Canonicalize ROOTFS and refuse dangerous host root paths
R=$(bb readlink -f "$ROOTFS" 2>/dev/null)
[ -n "$R" ] && ROOTFS="$R"
ROOTFS="${ROOTFS%/}"

case "$ROOTFS" in
    ""|"/"|"/data"|"/system"|"/vendor"|"/sdcard"|"/storage"|"/proc"|"/sys"|"/dev")
        log "CRITICAL: Refusing unsafe rootfs path: '$ROOTFS'"
        exit 66
        ;;
esac

log "action=$ACTION rootfs=$ROOTFS uid=$U gid=$G state=$STATE_DIR ram=$BIND_RAM android=$BIND_ANDROID appPid=$APP_PID"

# Detect lsof support (Busybox vs Toybox) like chroot-distro.sh
BBLSOF=""
LSOF_CMD=""
if bb lsof --help >/dev/null 2>&1; then
    BBLSOF=1
    LSOF_CMD="$BB lsof"
elif [ -x /system/xbin/lsof ]; then
    BBLSOF=1
    LSOF_CMD="/system/xbin/lsof"
elif [ -x /system/bin/lsof ]; then
    LSOF_CMD="/system/bin/lsof"
fi

# ---------------------------------------------------------------------------
# Path Resolution (--android-dirs & --tmpfs-dirs)
# ---------------------------------------------------------------------------

sanitize_rel_path() {
    p="$1"
    [ -n "$p" ] || return 1
    case "$p" in
        /*) ;;
        *) p="/$p" ;;
    esac
    [ "$p" != "/" ] && p="${p%/}"
    case "$p" in
        ""|"/"|*"/.."*|*"../"*|"$ROOTFS"|"$ROOTFS"/*)
            return 1
            ;;
    esac
    bb echo "$p"
}

get_tmpfs_points() {
    [ "$BIND_RAM" = "1" ] || return 0
    if [ -n "$CUSTOM_TMPFS_DIRS" ]; then
        raw_list="$CUSTOM_TMPFS_DIRS"
    else
        raw_list="$DEFAULT_TMPFS_DIRS"
    fi
    for p in $raw_list; do
        sp=$(sanitize_rel_path "$p") || continue
        bb echo "$sp"
    done | bb awk '!seen[$0]++'
}

default_android_bind_points() {
    # Same algorithm as chroot-distro.sh mount_android_dirs, excluding /data and
    # /data_mirror so the host app data and rootfs are never recursively exposed.
    bb echo /sdcard
    for p in /storage/*; do
        [ -e "$p" ] || continue
        bb echo "$p"
    done
    for p in /*; do
        [ -d "$p" ] || continue
        case "$p" in
            /storage|/bin|/boot|/etc|/home|/lib|/lib64|/media|/opt|/root|/run|/sbin|/srv|/usr|/var|/linkerconfig|/data|/data_mirror|/dev|/proc|/sys|/tmp)
                continue
                ;;
        esac
        bb echo "$p"
    done
}

get_android_points() {
    [ "$BIND_ANDROID" = "1" ] || return 0
    if [ -n "$CUSTOM_ANDROID_DIRS" ]; then
        for p in $CUSTOM_ANDROID_DIRS; do
            sp=$(sanitize_rel_path "$p") || continue
            case "$sp" in
                /data|/data_mirror|/proc|/sys|/dev)
                    log "skipping unsafe android bind dir: $sp"
                    continue
                    ;;
            esac
            bb echo "$sp"
        done | bb awk '!seen[$0]++'
    else
        default_android_bind_points | bb awk '!seen[$0]++'
    fi
}

record_mount_point() {
    mp="$1"
    [ -n "$mp" ] || return 0
    if [ -f "$MOUNT_LIST_FILE" ]; then
        bb grep -Fxq "$mp" "$MOUNT_LIST_FILE" 2>/dev/null && return 0
    fi
    bb echo "$mp" >> "$MOUNT_LIST_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Mount Inspection & Symlink Safety
# ---------------------------------------------------------------------------

listed_mounts() {
    {
        bb awk '{gsub(/\\040/, " ", $2); gsub(/\\011/, "\t", $2); print $2}' /proc/mounts 2>/dev/null
        bb awk '{gsub(/\\040/, " ", $5); gsub(/\\011/, "\t", $5); print $5}' /proc/self/mountinfo 2>/dev/null
    } | bb awk -v r="$ROOTFS" '$0 == r || index($0, r "/") == 1' | bb sort -u
}

dev_ino() {
    bb stat -L -c '%d:%i' "$1" 2>/dev/null
}

no_symlink_below_rootfs() {
    case "$1" in
        "$ROOTFS"|"$ROOTFS"/*) ;;
        *) return 1 ;;
    esac
    rest=${1#"$ROOTFS"}
    cur="$ROOTFS"
    while [ -n "$rest" ]; do
        rest=${rest#/}
        comp=${rest%%/*}
        rest=${rest#"$comp"}
        [ -n "$comp" ] || continue
        cur="$cur/$comp"
        [ -L "$cur" ] && return 1
    done
    return 0
}

safe_dir() {
    p="$1"
    rest=${p#"$ROOTFS"}
    cur="$ROOTFS"
    while [ -n "$rest" ]; do
        rest=${rest#/}
        comp=${rest%%/*}
        rest=${rest#"$comp"}
        [ -n "$comp" ] || continue
        cur="$cur/$comp"
        [ -L "$cur" ] && bb rm -f "$cur" 2>/dev/null
        if [ -e "$cur" ] && [ ! -d "$cur" ]; then
            bb rm -rf "$cur" 2>/dev/null
        fi
        if [ ! -d "$cur" ]; then
            bb mkdir -p "$cur" 2>/dev/null || return 1
        fi
    done
    return 0
}

is_mounted() {
    mp="${1%/}"
    [ -e "$mp" ] || return 1
    no_symlink_below_rootfs "$mp" || return 1
    case "$NL$(listed_mounts)$NL" in
        *"$NL$mp$NL"*) return 0 ;;
    esac
    [ -d "$mp" ] && [ ! -L "$mp" ] && bb mountpoint -q "$mp" 2>/dev/null
}

is_bound() {
    src="$1"
    dst="${2%/}"
    no_symlink_below_rootfs "$dst" || return 1
    a=$(dev_ino "$src")
    [ -n "$a" ] && [ "$a" = "$(dev_ino "$dst")" ] && return 0
    is_mounted "$dst"
}

# ---------------------------------------------------------------------------
# Mounting Logic (chroot-distro style + verification)
# ---------------------------------------------------------------------------

mount_system_point() {
    rel="$1"
    dst="$ROOTFS$rel"
    safe_dir "$dst" || return 1
    if is_mounted "$dst"; then
        record_mount_point "$dst"
        return 0
    fi

    err=""
    case "$rel" in
        /proc)
            err=$(bb mount -t proc proc "$dst" 2>&1)
            ;;
        /dev/pts)
            err=$(bb mount -t devpts devpts "$dst" 2>&1)
            ;;
        *)
            err=$(bb mount -o bind "$rel" "$dst" 2>&1)
            ;;
    esac

    if is_mounted "$dst" || is_bound "$rel" "$dst"; then
        record_mount_point "$dst"
        return 0
    fi
    log "mount: $dst failed: ${err:-not visible}"
    return 1
}

mount_tmpfs_point() {
    rel="$1"
    dst="$ROOTFS$rel"

    if [ "$rel" = "/run" ] && [ -L "$ROOTFS/var/run" ]; then
        bb rm -f "$ROOTFS/var/run" 2>/dev/null
        safe_dir "$ROOTFS/var/run"
    fi

    safe_dir "$dst" || return 1
    if is_mounted "$dst"; then
        record_mount_point "$dst"
        return 0
    fi

    err=$(bb mount -t tmpfs -o mode=1777 tmpfs "$dst" 2>&1)
    if ! is_mounted "$dst"; then
        log "mount: tmpfs $dst failed: ${err:-not visible}"
        return 1
    fi
    bb chmod 1777 "$dst" 2>/dev/null
    bb chown "$U:$G" "$dst" 2>/dev/null
    record_mount_point "$dst"
    return 0
}

bind_android_point() {
    src="$1"
    dst="$ROOTFS$src"
    if [ ! -e "$src" ]; then
        log "mount: warning: Android path '$src' missing, skipping"
        return 0
    fi
    safe_dir "$dst" || return 1
    if is_bound "$src" "$dst"; then
        record_mount_point "$dst"
        return 0
    fi

    err=$(bb mount -o rbind "$src" "$dst" 2>&1)
    if [ $? -ne 0 ]; then
        err=$(bb mount -o bind "$src" "$dst" 2>&1)
        if [ $? -ne 0 ]; then
            log "mount: cannot bind $src -> $dst: $err"
            return 1
        fi
    fi

    # Prevent unmount events inside chroot from propagating back to host Android mounts
    bb mount --make-rslave "$dst" 2>/dev/null || bb mount --make-private "$dst" 2>/dev/null

    if ! is_bound "$src" "$dst"; then
        log "mount: bind not visible $dst"
        return 1
    fi
    record_mount_point "$dst"
    return 0
}

do_mount() {
    [ -d "$ROOTFS" ] || { log "missing rootfs: $ROOTFS"; return 1; }
    log "mount: begin"
    log "mount: uid=$(bb id -u 2>/dev/null) ctx=$(bb cat /proc/self/attr/current 2>/dev/null) caps=$(bb awk '/CapEff/{print $2}' /proc/self/status 2>/dev/null) listed=$(listed_mounts | bb wc -l)"
    ok=1

    for sp in $SYSTEM_POINTS; do
        mount_system_point "$sp" || ok=0
    done

    if [ "$BIND_RAM" = "1" ]; then
        for tp in $(get_tmpfs_points); do
            mount_tmpfs_point "$tp" || ok=0
        done
    fi

    if [ "$BIND_ANDROID" = "1" ]; then
        for ap in $(get_android_points); do
            bind_android_point "$ap" || ok=0
        done
    fi

    if [ "$ok" -ne 1 ]; then
        log "mount: incomplete, running mandatory cleanup"
        cleanup
        return 1
    fi
    log "mount: done"
    return 0
}

# ---------------------------------------------------------------------------
# Process Termination & Mandatory Unmount (chroot-distro umount -a -f)
# ---------------------------------------------------------------------------

build_skip_pids() {
    SKIP_PIDS=" $$ "
    p=$$
    while [ "$p" -gt 1 ] 2>/dev/null; do
        p=$(bb awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
        case "$p" in
            ''|*[!0-9]*) break ;;
        esac
        SKIP_PIDS="$SKIP_PIDS$p "
    done
}

kill_pid() {
    sig="${2:--9}"
    case "$SKIP_PIDS" in
        *" $1 "*) return 0 ;;
    esac
    case "$1" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$1" -gt 1 ] 2>/dev/null && bb kill "$sig" "$1" 2>/dev/null
}

find_processes_via_lsof() {
    target_path="$1"
    [ -n "$LSOF_CMD" ] || return 0
    if [ -n "$BBLSOF" ]; then
        $LSOF_CMD 2>/dev/null | bb grep -F "$target_path" | bb grep -Eo '^[0-9]+' | bb sort -n -u
    else
        $LSOF_CMD 2>/dev/null | bb grep -F "$target_path" | bb cut -c10- | bb grep -Eo '^ *[0-9]+' | bb grep -Eo '[0-9]+' | bb sort -n -u
    fi
}

find_processes_via_proc() {
    target_path="$1"
    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid=${proc#/proc/}
        case "$SKIP_PIDS" in
            *" $pid "*) continue ;;
        esac
        hit=0
        for link in root cwd exe; do
            t=$(bb readlink "$proc/$link" 2>/dev/null)
            case "$t" in
                "$target_path"|"$target_path"/*) hit=1; break ;;
            esac
        done
        if [ "$hit" = "0" ]; then
            for fd in "$proc"/fd/*; do
                [ -e "$fd" ] || [ -L "$fd" ] || continue
                t=$(bb readlink "$fd" 2>/dev/null)
                case "$t" in
                    "$target_path"|"$target_path"/*) hit=1; break ;;
                esac
            done
        fi
        [ "$hit" = "1" ] && bb echo "$pid"
    done
}

kill_processes_with_open_files() {
    sig="${1:--9}"
    pids=$(
        {
            find_processes_via_lsof "$ROOTFS"
            find_processes_via_proc "$ROOTFS"
        } | bb sort -n -u
    )
    for pid in $pids; do
        kill_pid "$pid" "$sig"
    done
}

stop_guest_processes() {
    candidates=$(bb ps -o pid,user,args 2>/dev/null | bb awk '
        NR > 1 && ($0 ~ /(^|[\/ ])(box64|wineserver|wine64|wine|wineboot|winhandler|explorer)([ ]|$)/ ||
                    $0 ~ /\.exe([ ]|$)/) { print $1 }')
    for pid in $candidates; do
        proc="/proc/$pid"
        r=$(bb readlink "$proc/root" 2>/dev/null)
        case "$r" in
            "$ROOTFS"|"$ROOTFS"/*) kill_pid "$pid" -9; continue ;;
        esac
        c=$(bb readlink "$proc/cwd" 2>/dev/null)
        case "$c" in
            "$ROOTFS"|"$ROOTFS"/*) kill_pid "$pid" -9 ;;
        esac
    done
}

find_all_loopback_mount_points() {
    bb losetup -a 2>/dev/null | bb grep -F "$ROOTFS" | bb awk -F: '{print $1}' | bb sort -r
}

unmount_loopbacks() {
    for dev in $(find_all_loopback_mount_points); do
        bb umount "$dev" 2>/dev/null || bb umount -f "$dev" 2>/dev/null || bb losetup -d "$dev" 2>/dev/null
    done
}

known_mount_points() {
    if [ -f "$MOUNT_LIST_FILE" ]; then
        bb cat "$MOUNT_LIST_FILE" 2>/dev/null
    fi
    for p in $SYSTEM_POINTS $DEFAULT_TMPFS_DIRS /data_mirror; do
        bb echo "$ROOTFS$p"
    done
    for p in $(get_tmpfs_points); do
        bb echo "$ROOTFS$p"
    done
    for p in $(default_android_bind_points); do
        bb echo "$ROOTFS$p"
    done
    for p in $(get_android_points); do
        bb echo "$ROOTFS$p"
    done
}

mount_active() {
    m="${1%/}"
    case "$m" in
        "$ROOTFS"|"$ROOTFS"/*) ;;
        *) return 1 ;;
    esac
    no_symlink_below_rootfs "$m" || return 1
    [ -d "$m" ] || return 1
    case "$NL$LISTED$NL" in
        *"$NL$m$NL"*) return 0 ;;
    esac
    bb mountpoint -q "$m" 2>/dev/null && return 0
    src=${m#"$ROOTFS"}
    [ -n "$src" ] || return 1
    case " $ANDROID_POINTS " in
        *" $src "*)
            a=$(dev_ino "$src")
            [ -n "$a" ] && [ "$a" = "$(dev_ino "$m")" ] && return 0
            ;;
    esac
    return 1
}

active_mounts() {
    ANDROID_POINTS=$( { default_android_bind_points; get_android_points; } | bb tr '\n' ' ' )
    LISTED=$(listed_mounts)
    {
        bb echo "$LISTED"
        known_mount_points
    } | bb awk -v r="$ROOTFS" 'NF && ($0 == r || index($0, r "/") == 1) { print length($0) "\t" $0 }' \
      | bb sort -k1,1nr -k2,2r \
      | bb awk -F'\t' '!seen[$2]++ { print $2 }' \
      | while IFS= read -r m; do
            mount_active "$m" && bb echo "$m"
        done
}

unmount_point() {
    mp="$1"
    allow_lazy="$2"
    n=0
    while [ "$n" -lt 16 ]; do
        LISTED=$(listed_mounts)
        mount_active "$mp" || return 0
        bb mount --make-rslave "$mp" 2>/dev/null || bb mount --make-private "$mp" 2>/dev/null
        if ! bb umount "$mp" 2>/dev/null && ! bb umount -f "$mp" 2>/dev/null; then
            if [ "$allow_lazy" = "1" ] && bb umount -l "$mp" 2>/dev/null; then
                log "cleanup: lazy umount $mp"
            else
                log "cleanup: umount failed $mp"
                return 1
            fi
        fi
        n=$((n + 1))
    done
    return 1
}

list_unmount_issues() {
    mounts_left="$1"
    loops_left="$2"
    files_left="$3"
    log "WARNING: chroot is potentially still running or mounts could not be unmounted:"
    log "Open files under $ROOTFS: ${files_left:-Not found}"
    log "Mount points under $ROOTFS: ${mounts_left:-Not found}"
    log "Loopback devices under $ROOTFS: ${loops_left:-Not found}"
}

force_unmount_all() {
    log "cleanup: stopping guest processes"
    stop_guest_processes
    log "cleanup: killing processes with open rootfs files"
    kill_processes_with_open_files -15
    bb sleep 1
    kill_processes_with_open_files -9
    log "cleanup: unmounting loop devices"
    unmount_loopbacks

    pass=0
    while [ "$pass" -lt 4 ]; do
        mounts=$(active_mounts)
        [ -z "$mounts" ] && break
        lazy=0
        [ "$pass" -ge 2 ] && lazy=1
        for m in $mounts; do
            unmount_point "$m" "$lazy"
        done
        bb sleep 1
        [ -z "$(active_mounts)" ] && break
        kill_processes_with_open_files -9
        unmount_loopbacks
        pass=$((pass + 1))
    done

    rem_mounts=$(active_mounts)
    rem_loops=$(find_all_loopback_mount_points)
    rem_files=$(find_processes_via_proc "$ROOTFS")

    if [ -n "$rem_mounts" ] || [ -n "$rem_loops" ] || [ -n "$rem_files" ]; then
        list_unmount_issues "$rem_mounts" "$rem_loops" "$rem_files"
        return 1
    fi

    bb rm -f "$MOUNT_LIST_FILE" 2>/dev/null
    return 0
}

take_home_owner() {
    h=$(bb readlink -f "$ROOTFS/home/xuser" 2>/dev/null)
    case "$h" in
        "$ROOTFS"/home/?*) ;;
        *) log "run: invalid home $h"; return 1 ;;
    esac
    : > "$OWNER_MARK" 2>/dev/null
    bb chown 0:0 "$h" 2>/dev/null
    [ -d "$h/.wine" ] && bb chown 0:0 "$h/.wine" 2>/dev/null
    log "run: home owner -> root ($h)"
    return 0
}

restore_home_owner() {
    [ -f "$OWNER_MARK" ] || return 0
    [ -d "$ROOTFS/home" ] && [ ! -L "$ROOTFS/home" ] && \
        bb chown -hR "$U:$G" "$ROOTFS/home" 2>/dev/null
    bb rm -f "$OWNER_MARK" 2>/dev/null
    log "cleanup: home owner -> $U:$G"
}

CLEANUP_DONE=0
cleanup() {
    [ "$CLEANUP_DONE" = "1" ] && return 0
    CLEANUP_DONE=1

    [ -d "$ROOTFS" ] || return 0
    log "cleanup: begin"
    build_skip_pids
    : > "$STOP_FILE" 2>/dev/null

    if [ -n "$CHILD_PID" ]; then
        case "$CHILD_PID" in
            *[!0-9]*) ;;
            *) [ "$CHILD_PID" -gt 1 ] 2>/dev/null && bb kill -9 "$CHILD_PID" 2>/dev/null ;;
        esac
    fi

    if [ -z "$(active_mounts)" ] && [ -z "$(find_all_loopback_mount_points)" ]; then
        log "cleanup: no mounts"
        bb rm -f "$MOUNT_LIST_FILE" 2>/dev/null
        restore_home_owner
        return 0
    fi

    if force_unmount_all; then
        bb sync 2>/dev/null
        [ ! -L "$ROOTFS/tmp" ] && bb rm -rf "$ROOTFS/tmp/.root-winlator" 2>/dev/null
        restore_home_owner
        log "cleanup: done"
        return 0
    fi

    leftover=$(active_mounts | bb tr '\n' ' ')
    log "cleanup: FAILED, still mounted: $leftover"
    restore_home_owner
    return 72
}

watch_app() {
    while bb kill -0 "$APP_PID" 2>/dev/null; do
        [ -f "$STOP_FILE" ] && return 0
        bb sleep 2
    done
    cleanup
    return 0
}

prepare_box64_path() {
    p="$ROOTFS/data/local/tmp"
    safe_dir "$p" || return 1
    bb rm -f "$p/root-winlator" 2>/dev/null
    bb ln -s / "$p/root-winlator" 2>/dev/null || return 1
    log "box64: compatibility path ready"
    return 0
}

do_run() {
    trap 'cleanup; exit 130' INT TERM HUP QUIT

    do_mount || { log "run: mount failed"; cleanup; return 71; }

    bb rm -f "$STOP_FILE" 2>/dev/null

    ENV_SCRIPT=$(bb printf '%s' "$ENV_B64" | bb base64 -d 2>/dev/null)
    CMD=$(bb printf '%s' "$CMD_B64" | bb base64 -d 2>/dev/null)
    unset HISTFILE TMPDIR PREFIX BOOTCLASSPATH SYSTEMSERVERCLASSPATH \
        DEX2OATBOOTCLASSPATH LD_LIBRARY_PATH LD_PRELOAD ANDROID_DATA ANDROID_ROOT \
        ANDROID_ART_ROOT ANDROID_I18N_ROOT ANDROID_TZDATA_ROOT ANDROID_RUNTIME_ROOT \
        ANDROID_STORAGE EXTERNAL_STORAGE ASEC_MOUNTPOINT
    eval "$ENV_SCRIPT"
    log "run: cmd=$CMD"
    log "run: DISPLAY=$DISPLAY HOME=$HOME PATH=$PATH"
    for sock in /tmp/.X11-unix/X0 /tmp/.sysvshm/SM0 /tmp/.sound/AS0 /tmp/.vortek/V0 /tmp/.virgl/V0; do
        [ -e "$ROOTFS$sock" ] && log "socket: $sock present" || log "socket: $sock missing"
    done
    [ -n "$CMD" ] || { log "run: empty command"; cleanup; return 67; }

    eval "set -- $CMD"
    [ $# -gt 0 ] || { log "run: cannot parse command"; cleanup; return 67; }
    take_home_owner || { cleanup; return 68; }

    if ! bb unshare -m -p -f --mount-proc="$ROOTFS/proc" --propagation private "$BB" true 2>/dev/null; then
        log "PID namespace unavailable; refusing insecure plain chroot"
        cleanup
        return 69
    fi
    prepare_box64_path || { log "run: cannot prepare box64 path"; cleanup; return 70; }
    log "run: launching guest as root in PID+mount namespace argc=$#"
    log "run: exec $1"
    bb unshare -m -p -f --mount-proc="$ROOTFS/proc" --propagation private \
        "$BB" chroot "$ROOTFS" "$@" &
    CHILD_PID=$!
    log "run: guest wrapper pid=$CHILD_PID"
    watch_app &
    wait "$CHILD_PID"
    STATUS=$?
    log "run: guest wrapper exited status=$STATUS"
    cleanup
    return "$STATUS"
}

case "$ACTION" in
    mount)
        do_mount
        ;;
    run)
        do_run
        ;;
    stop|umount|unmount)
        cleanup
        ;;
esac

exit $?
