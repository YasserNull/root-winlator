#!/system/bin/sh
# root-winlator chroot helper.
#
# Usage:
#   chroot-run.sh mount <rootfs> <busybox> <fix_suid> <bind_ram> <bind_android> <uid> <gid> <state_dir>
#   chroot-run.sh run   <rootfs> <busybox> <app_pid> <env_b64> <cmd_b64> <uid> <gid> <state_dir> <fix_suid> <bind_ram> <bind_android>
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
FIX_SUID=1
BIND_RAM=1
BIND_ANDROID=1
APP_PID=0
ENV_B64=""
CMD_B64=""
CHILD_PID=""

case "$ACTION" in
    mount)
        FIX_SUID="$4"; BIND_RAM="$5"; BIND_ANDROID="$6"
        U="$7"; G="$8"; STATE_DIR="$9"
        ;;
    run)
        APP_PID="$4"; ENV_B64="$5"; CMD_B64="$6"
        U="$7"; G="$8"; STATE_DIR="$9"
        FIX_SUID="${10:-1}"; BIND_RAM="${11:-1}"; BIND_ANDROID="${12:-1}"
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
log "action=$ACTION rootfs=$ROOTFS uid=$U gid=$G state=$STATE_DIR fix=$FIX_SUID ram=$BIND_RAM android=$BIND_ANDROID appPid=$APP_PID"
STOP_FILE="$STATE_DIR/chroot.stop"

is_mounted() { bb mountpoint -q "$1" 2>/dev/null; }

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

mount_tmpfs() {
    dst="$ROOTFS$1"
    safe_dir "$dst"
    if ! is_mounted "$dst"; then
        bb mount -t tmpfs -o mode=1777 tmpfs "$dst" 2>/dev/null || return 1
    fi
    bb chmod 1777 "$dst" 2>/dev/null
    bb chown "$U:$G" "$dst" 2>/dev/null
    return 0
}

bind_path() {
    src="$1"
    dst="$ROOTFS$1"
    [ -e "$src" ] || return 0
    safe_dir "$dst"
    is_mounted "$dst" && return 0
    # Android mounts /apex/* and several /system and /dev subtrees separately.
    # A plain bind hides those submounts, so the guest linker
    # (/system/bin/linker64 -> /apex/...) would disappear.
    bb mount -o rbind "$src" "$dst" 2>/dev/null || \
        bb mount -o bind "$src" "$dst" 2>/dev/null || log "cannot bind $src"
}

fix_suid_options() {
    opts=$(bb awk '$2=="/data"{print $4; exit}' /proc/mounts 2>/dev/null)
    [ -n "$opts" ] || return 0
    if [ "$FIX_SUID" = "1" ]; then
        case ",$opts," in
            *",nosuid,"*)
                bb mount -o remount,dev,suid /data 2>/dev/null || log "cannot enable suid on /data"
                ;;
        esac
    else
        case ",$opts," in
            *",nosuid,"*) ;;
            *)
                bb mount -o remount,nosuid,nodev /data 2>/dev/null || log "cannot disable suid on /data"
                ;;
        esac
    fi
}

do_mount() {
    [ -d "$ROOTFS" ] || { log "missing rootfs: $ROOTFS"; return 1; }
    log "mount: begin"

    safe_dir "$ROOTFS/dev"
    is_mounted "$ROOTFS/dev" || bb mount -o bind /dev "$ROOTFS/dev" 2>/dev/null

    safe_dir "$ROOTFS/proc"
    is_mounted "$ROOTFS/proc" || bb mount -t proc proc "$ROOTFS/proc" 2>/dev/null

    safe_dir "$ROOTFS/sys"
    is_mounted "$ROOTFS/sys" || bb mount -o bind /sys "$ROOTFS/sys" 2>/dev/null

    safe_dir "$ROOTFS/dev/pts"
    is_mounted "$ROOTFS/dev/pts" || bb mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null

    if [ "$BIND_RAM" = "1" ]; then
        for p in /tmp /run /var/tmp /dev/shm; do
            mount_tmpfs "$p" || log "cannot mount tmpfs on $p"
        done
    fi

    if [ "$BIND_ANDROID" = "1" ]; then
        # /data is intentionally not bind-mounted: the rootfs lives in
        # /data/local/tmp, so binding /data would create a recursive mount.
        for p in /sdcard /storage /mnt /system /vendor /product /odm /apex /linkerconfig; do
            bind_path "$p"
        done
    fi

    fix_suid_options
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

cleanup() {
    [ -d "$ROOTFS" ] || return 0
    log "cleanup: begin"

    # Never kill the su/helper ancestor chain: ProcessHelper may start su with
    # the rootfs as cwd, which would otherwise match the cwd scan below.
    SKIP_PIDS=" $$ "
    p=$$
    while [ "$p" -gt 1 ] 2>/dev/null; do
        p=$(bb awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
        case "$p" in
            ''|*[!0-9]*) break ;;
        esac
        SKIP_PIDS="$SKIP_PIDS$p "
    done

    : > "$STOP_FILE" 2>/dev/null

    # The launcher wrapper is root-owned and not guest-writable. Never read a
    # pid from an app-writable file: that would allow arbitrary root kills.
    if [ -n "$CHILD_PID" ]; then
        case "$CHILD_PID" in
            *[!0-9]*) ;;
            *) [ "$CHILD_PID" -gt 1 ] 2>/dev/null && bb kill -9 "$CHILD_PID" 2>/dev/null ;;
        esac
    fi

    # Narrow candidates with one ps call: scanning every root process (there
    # are hundreds) made stop/prepare take ~20s on some devices. The readlink
    # check below still verifies that the process really lives in the rootfs.
    candidates=$(bb ps -o pid,user,args 2>/dev/null | bb awk '
        NR > 1 && ($0 ~ /(^|[\/ ])(box64|wineserver|wine64|wine|wineboot|winhandler|explorer)([ ]|$)/ ||
                    $0 ~ /\.exe([ ]|$)/) { print $1 }')
    for pid in $candidates; do
        case "$SKIP_PIDS" in
            *" $pid "*) continue ;;
        esac
        proc="/proc/$pid"
        r=$(bb readlink "$proc/root" 2>/dev/null)
        case "$r" in
            "$ROOTFS"|"$ROOTFS"/*)
                bb kill -9 "$pid" 2>/dev/null
                continue
                ;;
        esac
        c=$(bb readlink "$proc/cwd" 2>/dev/null)
        case "$c" in
            "$ROOTFS"|"$ROOTFS"/*) bb kill -9 "$pid" 2>/dev/null ;;
        esac
    done

    log "cleanup: processes stopped"
    bb sleep 1

    # Repeat: each pass unmounts deeper targets first. A lazy unmount is the
    # final fallback if a file descriptor is still held by a dying process.
    i=0
    while [ "$i" -lt 3 ]; do
        mounts=$(bb awk -v r="$ROOTFS" '$2==r || index($2, r "/")==1 {print $2}' /proc/mounts 2>/dev/null | bb sort -r)
        [ -z "$mounts" ] && break
        for m in $mounts; do
            bb umount "$m" 2>/dev/null || bb umount -l "$m" 2>/dev/null
        done
        bb sleep 1
        i=$((i + 1))
    done

    # Leftover from the old privilege dropper.
    bb rm -rf "$ROOTFS/tmp/.root-winlator" 2>/dev/null
    restore_home_owner
    log "cleanup: done"
    return 0
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
    do_mount

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
