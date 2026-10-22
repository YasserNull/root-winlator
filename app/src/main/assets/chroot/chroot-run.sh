#!/system/bin/sh
# root-winlator chroot helper.
#
# Usage:
#   chroot-run.sh mount <rootfs> <busybox> <bind_ram> <bind_android> <uid> <gid> <state_dir>
#   chroot-run.sh run   <rootfs> <busybox> <app_pid> <env_b64> <cmd_b64> <uid> <gid> <state_dir> <bind_ram> <bind_android>
#   chroot-run.sh stop  <rootfs> <busybox> <uid> <gid> <state_dir>
#
# All files except the rootfs itself live in the app-private state dir, which
# is not bind-mounted into the chroot. This file only runs as root.

set +e

ACTION="$1"
ROOTFS="$2"
BB="$3"

[ -n "$ACTION" ] && [ -n "$ROOTFS" ] && [ -n "$BB" ] || exit 64
[ -x "$BB" ] || exit 65

bb() { "$BB" "$@"; }
log() { echo "root-winlator: $*"; /system/bin/log -t RootWinlator "$*" 2>/dev/null; }

U=""
G=""
STATE_DIR=""
BIND_RAM=1
BIND_ANDROID=1
APP_PID=0
ENV_B64=""
CMD_B64=""
CHILD_PID=""

case "$ACTION" in
    mount)
        BIND_RAM="$4"; BIND_ANDROID="$5"
        U="$6"; G="$7"; STATE_DIR="$8"
        ;;
    run)
        APP_PID="$4"; ENV_B64="$5"; CMD_B64="$6"
        U="$7"; G="$8"; STATE_DIR="$9"
        BIND_RAM="${10:-1}"; BIND_ANDROID="${11:-1}"
        ;;
    stop)
        U="$4"; G="$5"; STATE_DIR="$6"
        ;;
    *)
        exit 64
        ;;
esac

[ -n "$U" ] && [ -n "$G" ] && [ -n "$STATE_DIR" ] || exit 66
bb mkdir -p "$STATE_DIR"
log "action=$ACTION rootfs=$ROOTFS uid=$U gid=$G state=$STATE_DIR ram=$BIND_RAM android=$BIND_ANDROID appPid=$APP_PID"
STOP_FILE="$STATE_DIR/chroot.stop"

NL='
'

# The rootfs path must be canonical: the kernel reports and resolves mount
# points by their real path, so a symlinked component would never match.
R=$(bb readlink -f "$ROOTFS" 2>/dev/null)
[ -n "$R" ] && ROOTFS="$R"

# /proc/mounts cannot be trusted on every device: root-hiding kernels
# (KernelSU + SUSFS sus_mount, Shamiko, ...) filter mount entries even for
# root, so a successful mount(2) may never be listed there. Every check below
# also falls back to stat(2), which cannot be hidden. Without this, mounts
# looked "missing", were stacked again on every start (the second tmpfs on
# /tmp hid the X11 sockets created in between) and were never unmounted.
listed_mounts() {
    {
        bb awk '{print $2}' /proc/mounts 2>/dev/null
        bb awk '{print $5}' /proc/self/mountinfo 2>/dev/null
    } | bb awk -v r="$ROOTFS" '$0==r || index($0, r "/")==1' | bb sort -u
}

dev_ino() { bb stat -L -c '%d:%i' "$1" 2>/dev/null; }

# A directory on another device than its parent is a mount point
# (busybox mountpoint compares st_dev, it does not read /proc/mounts).
is_mounted() {
    case "$NL$(listed_mounts)$NL" in
        *"$NL$1$NL"*) return 0 ;;
    esac
    [ -d "$1" ] && [ ! -L "$1" ] && bb mountpoint -q "$1" 2>/dev/null
}

# Bind mounts from the same filesystem do not change st_dev, so compare the
# device and inode of the source and the target instead.
is_bound() {
    a=$(dev_ino "$1")
    [ -n "$a" ] && [ "$a" = "$(dev_ino "$2")" ] && return 0
    is_mounted "$2"
}

# True if no component of $1 below the rootfs is a symlink. Shell builtins
# only: called for every candidate mount point during cleanup.
no_symlink_below_rootfs() {
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

# Mount targets must be real directories. A guest-created symlink here would
# make mount(2) act on the symlink target in the host filesystem.
safe_dir() {
    p="$1"
    [ -L "$p" ] && bb rm -f "$p" 2>/dev/null
    if [ ! -d "$p" ]; then
        bb rm -rf "$p" 2>/dev/null
        bb mkdir -p "$p" 2>/dev/null
    fi
}

# mount_fs <rel_path> <mount args...>: idempotent, verified mount.
mount_fs() {
    dst="$ROOTFS$1"
    shift
    safe_dir "$dst"
    is_mounted "$dst" && return 0
    err=$(bb mount "$@" "$dst" 2>&1)
    is_mounted "$dst" && return 0
    log "mount: $dst failed: ${err:-not visible}"
    return 1
}

mount_tmpfs() {
    dst="$ROOTFS$1"
    mount_fs "$1" -t tmpfs -o mode=1777 tmpfs || return 1
    bb chmod 1777 "$dst" 2>/dev/null
    bb chown "$U:$G" "$dst" 2>/dev/null
    return 0
}

bind_path() {
    src="$1"
    dst="$ROOTFS$1"
    [ -e "$src" ] || return 0
    safe_dir "$dst"
    is_bound "$src" "$dst" && return 0
    # rbind keeps Android submounts (/apex/*, /mnt/*, /storage/*) visible.
    err=$(bb mount -o rbind "$src" "$dst" 2>&1)
    if [ $? -ne 0 ]; then
        err=$(bb mount -o bind "$src" "$dst" 2>&1)
        if [ $? -ne 0 ]; then
            log "mount: cannot bind $src -> $dst: $err"
            return 1
        fi
    fi
    if ! is_bound "$src" "$dst"; then
        log "mount: bind not visible $dst"
        return 1
    fi
    return 0
}

android_bind_points() {
    # Same list generation as chroot-distro: /sdcard, each /storage entry,
    # then every top-level Android directory except the Linux rootfs/host-only
    # ones. /data is excluded on purpose: the rootfs lives inside it, so
    # exposing /data would both recurse and hand app-private files to the guest.
    # /data_mirror is excluded for the same reason (it re-exposes /data), and
    # /dev, /proc and /sys are mounted separately by do_mount.
    bb echo /sdcard
    for p in /storage/*; do
        [ -e "$p" ] || continue
        bb echo "$p"
    done
    for p in /*; do
        [ -d "$p" ] || continue
        case "$p" in
            /storage|/bin|/boot|/etc|/home|/lib|/media|/opt|/root|/run|/sbin|/srv|/usr|/var|/linkerconfig|/data|/data_mirror|/dev|/proc|/sys)
                continue
                ;;
        esac
        bb echo "$p"
    done
}

do_mount() {
    [ -d "$ROOTFS" ] || { log "missing rootfs: $ROOTFS"; return 1; }
    log "mount: begin"
    log "mount: uid=$(bb id -u 2>/dev/null) ctx=$(bb cat /proc/self/attr/current 2>/dev/null) caps=$(bb awk '/CapEff/{print $2}' /proc/self/status 2>/dev/null) listed=$(listed_mounts | bb wc -l)"
    ok=1

    mount_fs /dev -o bind /dev || ok=0
    mount_fs /proc -t proc proc || ok=0
    mount_fs /sys -o bind /sys || ok=0
    mount_fs /dev/pts -t devpts devpts || ok=0

    if [ "$BIND_RAM" = "1" ]; then
        for p in /tmp /run /var/tmp /dev/shm; do
            mount_tmpfs "$p" || ok=0
        done
    fi

    if [ "$BIND_ANDROID" = "1" ]; then
        points=$(android_bind_points | bb sort -u)
        for p in $points; do
            bind_path "$p" || ok=0
        done
    fi

    if [ "$ok" -ne 1 ]; then
        log "mount: incomplete"
        return 1
    fi
    log "mount: done"
    return 0
}

# Wine refuses a WINEPREFIX that is not owned by the current uid. The guest
# runs as root, so hand the prefix to root for the run and give the whole
# /home back to the app uid afterwards (the app edits container files).
OWNER_MARK="$STATE_DIR/chroot.root-owned"

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
    # -h: never follow guest-created symlinks to host files.
    [ -d "$ROOTFS/home" ] && [ ! -L "$ROOTFS/home" ] && \
        bb chown -hR "$U:$G" "$ROOTFS/home" 2>/dev/null
    bb rm -f "$OWNER_MARK" 2>/dev/null
    log "cleanup: home owner -> $U:$G"
}

build_skip_pids() {
    # Never kill the su/helper ancestor chain.
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
    case "$SKIP_PIDS" in
        *" $1 "*) return 0 ;;
    esac
    case "$1" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$1" -gt 1 ] 2>/dev/null && bb kill -9 "$1" 2>/dev/null
}

stop_guest_processes() {
    # Narrow candidates with one ps call, then verify root/cwd.
    candidates=$(bb ps -o pid,user,args 2>/dev/null | bb awk '
        NR > 1 && ($0 ~ /(^|[\/ ])(box64|wineserver|wine64|wine|wineboot|winhandler|explorer)([ ]|$)/ ||
                    $0 ~ /\.exe([ ]|$)/) { print $1 }')
    for pid in $candidates; do
        proc="/proc/$pid"
        r=$(bb readlink "$proc/root" 2>/dev/null)
        case "$r" in
            "$ROOTFS"|"$ROOTFS"/*) kill_pid "$pid"; continue ;;
        esac
        c=$(bb readlink "$proc/cwd" 2>/dev/null)
        case "$c" in
            "$ROOTFS"|"$ROOTFS"/*) kill_pid "$pid" ;;
        esac
    done
}

kill_processes_with_open_files() {
    # chroot-distro force mode: close every process that still references the
    # rootfs, not only wine/box64. This is what lets the following umount(2)
    # succeed without lazy unmounts.
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
                "$ROOTFS"|"$ROOTFS"/*) hit=1; break ;;
            esac
        done
        if [ "$hit" = "0" ]; then
            for fd in "$proc"/fd/*; do
                [ -e "$fd" ] || [ -L "$fd" ] || continue
                t=$(bb readlink "$fd" 2>/dev/null)
                case "$t" in
                    "$ROOTFS"|"$ROOTFS"/*) hit=1; break ;;
                esac
            done
        fi
        [ "$hit" = "1" ] && kill_pid "$pid"
    done
}

unmount_loopbacks() {
    loops=$(bb losetup -a 2>/dev/null | bb grep -F "$ROOTFS" | bb awk -F: '{print $1}')
    for dev in $loops; do
        bb umount "$dev" 2>/dev/null || bb umount -f "$dev" 2>/dev/null
    done
}

known_mount_points() {
    # Every path this helper ever mounts. They are probed with stat(2) because
    # /proc/mounts may hide them. /data_mirror: mounted by older builds.
    for p in /dev /dev/pts /dev/shm /proc /sys /tmp /run /var/tmp /data_mirror; do
        bb echo "$ROOTFS$p"
    done
    for p in $ANDROID_POINTS; do
        bb echo "$ROOTFS$p"
    done
}

# Uses $LISTED (listed_mounts snapshot) and $ANDROID_POINTS.
mount_active() {
    m="$1"
    case "$m" in
        "$ROOTFS"|"$ROOTFS"/*) ;;
        *) return 1 ;;
    esac
    # Never let a guest-created symlink redirect umount(2) to a host mount.
    no_symlink_below_rootfs "$m" || return 1
    [ -d "$m" ] || return 1
    case "$NL$LISTED$NL" in
        *"$NL$m$NL"*) return 0 ;;
    esac
    bb mountpoint -q "$m" 2>/dev/null && return 0
    src=${m#"$ROOTFS"}
    case " $ANDROID_POINTS " in
        *" $src "*) ;;
        *) return 1 ;;
    esac
    a=$(dev_ino "$src")
    [ -n "$a" ] && [ "$a" = "$(dev_ino "$m")" ]
}

# Prints the active mount points below the rootfs, deepest first.
active_mounts() {
    [ -n "$ANDROID_POINTS" ] || ANDROID_POINTS=$(android_bind_points | bb tr '\n' ' ')
    LISTED=$(listed_mounts)
    for m in $({ bb echo "$LISTED"; known_mount_points; } | bb sort -u -r); do
        mount_active "$m" && bb echo "$m"
    done
}

# unmount_point <path> <allow_lazy>: pops every mount stacked on <path>
# (broken builds mounted the same path again on each start).
unmount_point() {
    n=0
    while [ "$n" -lt 16 ]; do
        LISTED=$(listed_mounts)
        mount_active "$1" || return 0
        if ! bb umount "$1" 2>/dev/null && ! bb umount -f "$1" 2>/dev/null; then
            # Kernels that hide mounts also hide rbind submounts, so they
            # cannot be unmounted one by one; detach the whole tree instead.
            if [ "$2" = "1" ] && bb umount -l "$1" 2>/dev/null; then
                log "cleanup: lazy umount $1"
            else
                log "cleanup: umount failed $1"
                return 1
            fi
        fi
        n=$((n + 1))
    done
    return 1
}

force_unmount_all() {
    # chroot-distro algorithm: kill open files, loop devices, then every mount
    # point under the rootfs deepest-first, and verify. Lazy umount is only a
    # last resort, after every process using the rootfs has been killed.
    log "cleanup: stopping guest processes"
    stop_guest_processes
    log "cleanup: killing processes with open rootfs files"
    kill_processes_with_open_files
    log "cleanup: unmounting loop devices"
    bb sleep 1
    unmount_loopbacks

    pass=0
    while [ "$pass" -lt 3 ]; do
        mounts=$(active_mounts)
        [ -z "$mounts" ] && return 0
        lazy=0
        [ "$pass" -ge 1 ] && lazy=1
        for m in $mounts; do
            unmount_point "$m" "$lazy"
        done
        bb sleep 1
        [ -z "$(active_mounts)" ] && return 0
        if [ "$pass" -eq 0 ]; then
            kill_processes_with_open_files
            bb sleep 1
        fi
        pass=$((pass + 1))
    done

    [ -z "$(active_mounts)" ]
}

cleanup() {
    [ -d "$ROOTFS" ] || return 0
    log "cleanup: begin"
    build_skip_pids
    ANDROID_POINTS=$(android_bind_points | bb tr '\n' ' ')
    : > "$STOP_FILE" 2>/dev/null

    # The launcher wrapper is root-owned and not guest-writable. Never read a
    # pid from an app-writable file: that would allow arbitrary root kills.
    if [ -n "$CHILD_PID" ]; then
        case "$CHILD_PID" in
            *[!0-9]*) ;;
            *) [ "$CHILD_PID" -gt 1 ] 2>/dev/null && bb kill -9 "$CHILD_PID" 2>/dev/null ;;
        esac
    fi

    # Nothing mounted means there is nothing to unmount. Avoid scanning every
    # process on the device (slow on some ROMs) during normal app startup.
    if [ -z "$(active_mounts)" ]; then
        log "cleanup: no mounts"
        restore_home_owner
        return 0
    fi

    if force_unmount_all; then
        bb sync 2>/dev/null
        # Leftover from the old privilege dropper.
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
    # The Android process was killed (LMK, force-stop). The su shell can
    # outlive it, so clean up here instead of leaving mounts behind.
    cleanup
    return 0
}

prepare_box64_path() {
    # The packaged box64 ELF has a fixed interpreter/RUNPATH pointing at
    # /data/data/com.winlator/files/rootfs. Inside the chroot that path does
    # not exist, so make it resolve to the chroot root.
    p="$ROOTFS/data/data/com.winlator/files"
    safe_dir "$p"
    bb rm -f "$p/rootfs" 2>/dev/null
    bb ln -s / "$p/rootfs" 2>/dev/null || return 1
    log "box64: compatibility path ready"
    return 0
}

do_run() {
    do_mount || { log "run: mount failed"; cleanup; return 71; }

    bb rm -f "$STOP_FILE" 2>/dev/null

    # Decode both before eval: the guest PATH does not contain the shell
    # utilities, and /system/bin/sh has no portable printf builtin here.
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

    # Same as chroot-distro without su: plain chroot as root, no user switch.
    # The rootfs has no shell, so box64 is exec'd directly. CMD is a list of
    # single-quoted words built by ChrootManager (keeps C:\ backslashes).
    eval "set -- $CMD"
    [ $# -gt 0 ] || { log "run: cannot parse command"; cleanup; return 67; }
    take_home_owner || { cleanup; return 68; }

    # A plain chroot would let the guest reach /proc/<app>/root/... and modify
    # app-private files, so it is never used as a fallback.
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
    stop)
        cleanup
        ;;
esac

exit $?
