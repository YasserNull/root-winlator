#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
PATCH_TYPE="all"
EXCLUDES=""

if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BLUE=$'\033[1;34m'
    C_CYAN=$'\033[1;36m'
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_MAGENTA=$'\033[1;35m'
    C_RED=$'\033[1;31m'
else
    C_RESET=""
    C_BLUE=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_MAGENTA=""
    C_RED=""
fi

DONE_COLORS=("$C_GREEN" "$C_CYAN" "$C_MAGENTA" "$C_BLUE" "$C_YELLOW")
DONE_INDEX=0

log() { printf '%s[apply_patches]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_step() { printf '%s[apply_patches]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
log_ok() { printf '%s[apply_patches]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[apply_patches]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die() { printf '%s[apply_patches] error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --exclude)
            [ "$#" -ge 2 ] || die "--exclude requires a value"
            EXCLUDES="$EXCLUDES $2"
            shift 2
            ;;
        --exclude=*)
            EXCLUDES="$EXCLUDES ${1#*=}"
            shift
            ;;
        -h|--help)
            printf 'Usage: %s [project-dir] [patch-type] [--exclude "name ..."]\n' "$0"
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"
            elif [ "$PATCH_TYPE" = "all" ]; then
                PATCH_TYPE="$1"
            else
                die "unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

TARGET="${TARGET:-$(pwd)}"
EXCLUDES=$(printf '%s' "$EXCLUDES" | tr ',;-' '   ' | tr 'A-Z' 'a-z')
APP="$TARGET/app"
RES="$APP/src/main/res"

[ -d "$APP" ] || die "not a Winlator project: $TARGET"

MAGICK=""

find_magick() {
    if command -v magick >/dev/null 2>&1; then
        MAGICK="magick"
    elif command -v convert >/dev/null 2>&1; then
        MAGICK="convert"
    else
        die "ImageMagick not found (install magick or convert)"
    fi
}

is_excluded() {
    local name="$1"
    local item canonical

    for item in $EXCLUDES; do
        canonical="$item"
        case "$item" in
            root) canonical="libsu" ;;
            helper) canonical="chroot_helper" ;;
            ui|chroot_ui) canonical="chroot_settings" ;;
            exec) canonical="chroot_exec" ;;
            wallpaper) canonical="wallpapers" ;;
            drawer) canonical="app_name" ;;
        esac
        [ "$canonical" = "$name" ] && return 0
    done

    return 1
}

run_patch() {
    local name="$1"
    local label="$2"
    shift 2

    if is_excluded "$name"; then
        log_warn "excluded: $label"
        return 0
    fi

    log_step "start: $label"
    "$@"

    local color="${DONE_COLORS[$((DONE_INDEX % ${#DONE_COLORS[@]}))]}"
    DONE_INDEX=$((DONE_INDEX + 1))
    printf '%s[apply_patches]%s %s\n' "$color" "$C_RESET" "done: $label"
}

recolor_red() {
    local img="$1"
    local is_blue

    [ -f "$img" ] || return 0

    is_blue=$("$MAGICK" "$img" -format '%[fx:(mean.b>mean.r)?1:0]' info:)
    if [ "$is_blue" = "1" ]; then
        "$MAGICK" "$img" -modulate 100,100,186 "$img"
        log "recolored red: ${img#"$TARGET"/}"
    else
        log "skipped (already red or not blue): ${img#"$TARGET"/}"
    fi
}

patch_icon() {
    log "patch: red app icon"
    find_magick

    local f
    for f in "$RES"/mipmap-*/ic_launcher.png \
             "$RES"/mipmap-*/ic_launcher_round.png \
             "$RES"/mipmap-*/ic_launcher_foreground.png \
             "$RES"/drawable-*/logo.png; do
        recolor_red "$f"
    done
}

patch_wallpapers() {
    log "patch: red wallpapers"
    find_magick

    local n img config

    for n in 1 2; do
        img="$APP/src/main/assets/wallpapers/wallpaper-$n/image.png"
        recolor_red "$img"
    done

    config="$APP/src/main/assets/wallpapers/wallpaper-1/config.json"
    if [ -f "$config" ]; then
        sed -i 's/#90a4ae/#ae9093/gi; s/#01579b/#9b0401/gi' "$config"
        log "patched: ${config#"$TARGET"/}"
    fi

    config="$APP/src/main/assets/wallpapers/wallpaper-2/config.json"
    if [ -f "$config" ]; then
        sed -i 's/#01579b/#9b0401/gi; s/#0277bd/#bd020b/gi' "$config"
        log "patched: ${config#"$TARGET"/}"
    fi
}

patch_package() {
    log "patch: package com.rootwinlator"

    local gradle="$APP/build.gradle"
    local manifest="$APP/src/main/AndroidManifest.xml"
    local fileutils="$APP/src/main/java/com/winlator/core/FileUtils.java"
    local apputils="$APP/src/main/java/com/winlator/core/AppUtils.java"
    local winlator_h="$APP/src/main/cpp/winlator/include/winlator.h"

    [ -f "$gradle" ] || die "missing $gradle"

    sed -i "s/applicationId 'com\.winlator'/applicationId 'com.rootwinlator'/" "$gradle"
    sed -i "s/applicationId 'com\.yassernull\.rootwinlator'/applicationId 'com.rootwinlator'/" "$gradle"

    if [ -f "$manifest" ]; then
        sed -i 's/com\.winlator\.FileProvider/com.rootwinlator.FileProvider/g' "$manifest"
    fi

    if [ -f "$fileutils" ]; then
        sed -i 's|FileProvider.getUriForFile(activity, "com\.winlator\.FileProvider", file)|FileProvider.getUriForFile(activity, activity.getPackageName()+".FileProvider", file)|' "$fileutils"
    fi

    if [ -f "$apputils" ]; then
        sed -i 's|/data/data/com\.winlator/storage|/data/data/com.rootwinlator/storage|' "$apputils"
    fi

    if [ -f "$winlator_h" ]; then
        sed -i 's|/data/data/com\.winlator/cache|/data/data/com.rootwinlator/cache|g' "$winlator_h"
    fi

    log "patched: ${gradle#"$TARGET"/}"
}

patch_rootfs() {
    log "patch: rootfs and library paths (/data/local/tmp/root-winlator)"

    # 1. Native header paths
    local gladio_h="$APP/src/main/cpp/gladiorenderer/include/gladio.h"
    if [ -f "$gladio_h" ]; then
        sed -i 's|/data/data/com\.winlator/files/rootfs/tmp/\.X11-unix/X0|/data/local/tmp/root-winlator/tmp/.X11-unix/X0|g' "$gladio_h"
        sed -i 's|/data/data/com\.rootwinlator/files/rootfs/tmp/\.X11-unix/X0|/data/local/tmp/root-winlator/tmp/.X11-unix/X0|g' "$gladio_h"
        log "patched: ${gladio_h#"$TARGET"/}"
    fi

    local vortek_h="$APP/src/main/cpp/vortekrenderer/include/vortek.h"
    if [ -f "$vortek_h" ]; then
        sed -i 's|/data/data/com\.winlator/files/rootfs/tmp/\.vortek/V0|/data/local/tmp/root-winlator/tmp/.vortek/V0|g' "$vortek_h"
        sed -i 's|/data/data/com\.rootwinlator/files/rootfs/tmp/\.vortek/V0|/data/local/tmp/root-winlator/tmp/.vortek/V0|g' "$vortek_h"
        log "patched: ${vortek_h#"$TARGET"/}"
    fi

    # 2. Java rootfs directory and environment
    local rootfs_java="$APP/src/main/java/com/winlator/xenvironment/RootFS.java"
    if [ -f "$rootfs_java" ]; then
        sed -i 's|File rootDir = new File(context.getFilesDir(), "rootfs");|File rootDir = new File("/data/local/tmp/root-winlator");|' "$rootfs_java"
        log "patched: ${rootfs_java#"$TARGET"/}"
    fi

    local installer_java="$APP/src/main/java/com/winlator/xenvironment/RootFSInstaller.java"
    if [ -f "$installer_java" ]; then
        sed -i 's/public static final byte LATEST_VERSION = 23;/public static final byte LATEST_VERSION = 24;/' "$installer_java"
        log "patched: ${installer_java#"$TARGET"/}"
    fi

    local container_java="$APP/src/main/java/com/winlator/container/Container.java"
    if [ -f "$container_java" ]; then
        sed -i 's/WINEESYNC=1/WINEESYNC=0/g' "$container_java"
        log "patched: ${container_java#"$TARGET"/}"
    fi

    local xserver_activity="$APP/src/main/java/com/winlator/XServerDisplayActivity.java"
    if [ -f "$xserver_activity" ]; then
        sed -i 's/if (!envVars.has("WINEESYNC")) envVars.put("WINEESYNC", "1");/envVars.put("WINEESYNC", "0");/g' "$xserver_activity"
        log "patched: ${xserver_activity#"$TARGET"/}"
    fi

    # 3. Bundled assets (box64, graphics drivers, rootfs, etc.)
    local copied_assets=0
    if [ -d "$SCRIPT_DIR/app/src/main/assets" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        local asset_rel
        for asset_rel in \
            "box64/box64-0.4.4.tzst" \
            "container_pattern.tzst" \
            "graphics_driver/gladio-1.1.tzst" \
            "graphics_driver/turnip-26.2.0.tzst" \
            "graphics_driver/virgl-23.1.9.tzst" \
            "graphics_driver/vortek-2.1.tzst" \
            "rootfs.tzst" \
            "rootfs_patches.tzst"; do
            if [ -f "$SCRIPT_DIR/app/src/main/assets/$asset_rel" ]; then
                mkdir -p "$(dirname "$APP/src/main/assets/$asset_rel")"
                cp -f "$SCRIPT_DIR/app/src/main/assets/$asset_rel" "$APP/src/main/assets/$asset_rel"
                log "updated asset from source: app/src/main/assets/$asset_rel"
                copied_assets=1
            fi
        done

        if [ -d "$SCRIPT_DIR/app/src/main/assets/chroot" ]; then
            mkdir -p "$APP/src/main/assets/chroot"
            cp -rf "$SCRIPT_DIR/app/src/main/assets/chroot/"* "$APP/src/main/assets/chroot/"
            log "updated asset from source: app/src/main/assets/chroot"
        fi
    fi

    # Fallback / in-place binary string patcher if assets were not copied
    if [ "$copied_assets" -eq 0 ] && command -v python3 >/dev/null 2>&1; then
        log "patching asset archives in-place with python..."
        python3 - <<'PYTHON_SCRIPT' "$APP/src/main/assets"
import os, sys, tarfile, io, subprocess

assets_dir = sys.argv[1]
old_prefix = b"/data/data/com.winlator/files/rootfs"
old_prefix2 = b"/data/data/com.rootwinlator/files/rootfs"
new_prefix = b"/data/local/tmp/root-winlator"

def patch_content(name, content):
    for op in [old_prefix, old_prefix2]:
        if op not in content:
            continue
        if name.endswith((".json", ".conf", ".txt", ".sh", ".desktop")):
            content = content.replace(op, new_prefix)
            continue
        res = bytearray()
        idx = 0
        while True:
            pos = content.find(op, idx)
            if pos == -1:
                res.extend(content[idx:])
                break
            res.extend(content[idx:pos])
            null_pos = content.find(b"\x00", pos)
            if null_pos != -1:
                orig = content[pos:null_pos]
                rep = orig.replace(op, new_prefix)
                pad = b"\x00" * (len(orig) - len(rep))
                res.extend(rep + b"\x00" + pad)
                idx = null_pos + 1
            else:
                pad = b"\x00" * (len(op) - len(new_prefix))
                res.extend(new_prefix + pad)
                idx = pos + len(op)
        content = bytes(res)
    return content

def patch_archive(tzst_path):
    try:
        with open(tzst_path, "rb") as f:
            decomp = subprocess.check_output(["zstd", "-d"], input=f.read())
    except Exception as e:
        print(f"Skipping {tzst_path}: {e}")
        return

    in_tar = tarfile.open(fileobj=io.BytesIO(decomp))
    out_buf = io.BytesIO()
    out_tar = tarfile.open(fileobj=out_buf, mode="w")
    modified = False

    for m in in_tar.getmembers():
        if m.isfile():
            f_in = in_tar.extractfile(m)
            content = f_in.read() if f_in else b""
            new_content = patch_content(m.name, content)
            if new_content != content:
                modified = True
                m.size = len(new_content)
                out_tar.addfile(m, io.BytesIO(new_content))
            else:
                out_tar.addfile(m, io.BytesIO(content))
        else:
            out_tar.addfile(m)

    in_tar.close()
    out_tar.close()

    if modified:
        comp = subprocess.check_output(["zstd", "-3", "-f"], input=out_buf.getvalue())
        with open(tzst_path, "wb") as f:
            f.write(comp)
        print(f"Patched in-place: {os.path.basename(tzst_path)}")

for root, _, files in os.walk(assets_dir):
    for file in files:
        if file.endswith(".tzst") and file != "rootfs.tzst":
            patch_archive(os.path.join(root, file))
PYTHON_SCRIPT
    fi
}

patch_libsu() {
    log "patch: Libsu dependency and root backend classes"

    # 1. Top-level build.gradle: add JitPack repository
    local root_gradle="$TARGET/build.gradle"
    if [ -f "$root_gradle" ] && ! grep -q "jitpack.io" "$root_gradle"; then
        sed -i "/repositories {/a \        maven { url 'https://jitpack.io' }" "$root_gradle"
        log "added JitPack repository to build.gradle"
    fi

    # 2. app/build.gradle: add Libsu dependency
    local app_gradle="$APP/build.gradle"
    if [ -f "$app_gradle" ] && ! grep -q "libsu:core" "$app_gradle"; then
        sed -i "/dependencies {/a \    implementation 'com.github.topjohnwu.libsu:core:6.0.0'" "$app_gradle"
        log "added Libsu dependency to app/build.gradle"
    fi

    # 3. Copy root backend Java classes (modular additions to avoid changing existing files)
    local root_java_dir="$APP/src/main/java/com/winlator/root"
    mkdir -p "$root_java_dir"
    if [ -d "$SCRIPT_DIR/app/src/main/java/com/winlator/root" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        cp -f "$SCRIPT_DIR/app/src/main/java/com/winlator/root/"*.java "$root_java_dir/"
        log "installed com.winlator.root Java classes"
    fi

    # 4. Copy root resources (strings)
    if [ -d "$SCRIPT_DIR/app/src/main/res" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        [ -f "$SCRIPT_DIR/app/src/main/res/values/strings_root.xml" ] && \
            cp -f "$SCRIPT_DIR/app/src/main/res/values/strings_root.xml" "$RES/values/"
        [ -f "$SCRIPT_DIR/app/src/main/res/values-pt/strings_root.xml" ] && [ -d "$RES/values-pt" ] && \
            cp -f "$SCRIPT_DIR/app/src/main/res/values-pt/strings_root.xml" "$RES/values-pt/"
        [ -f "$SCRIPT_DIR/app/src/main/res/values-ru/strings_root.xml" ] && [ -d "$RES/values-ru" ] && \
            cp -f "$SCRIPT_DIR/app/src/main/res/values-ru/strings_root.xml" "$RES/values-ru/"
        log "installed strings_root.xml"
    fi

}

patch_chroot_helper() {
    log "patch: runtime chroot helper download"

    local src_busybox="$SCRIPT_DIR/app/src/main/java/com/winlator/root/BusyboxInstaller.java"
    local dst_busybox="$APP/src/main/java/com/winlator/root/BusyboxInstaller.java"

    if [ -f "$src_busybox" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        mkdir -p "$(dirname "$dst_busybox")"
        cp -f "$src_busybox" "$dst_busybox"
        log "installed/updated BusyboxInstaller.java"
    fi

    [ -f "$dst_busybox" ] || die "missing $dst_busybox"
    grep -q "HELPER_SHA256" "$dst_busybox" || die "BusyboxInstaller.java has no runtime helper verification"
    grep -q "root_winlator_chroot.sh" "$dst_busybox" || die "BusyboxInstaller.java has wrong helper name"

    local main_activity="$APP/src/main/java/com/winlator/MainActivity.java"
    if [ -f "$main_activity" ] && ! grep -q "BusyboxInstaller.ensureHelper" "$main_activity"; then
        python3 - <<'PYTHON_SCRIPT' "$main_activity"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

target = "        super.onCreate(savedInstanceState);\n        setContentView(R.layout.main_activity);"
hook = target + """

        new Thread(() -> {
            try {
                com.winlator.root.BusyboxInstaller.ensureHelper(getApplicationContext());
            }
            catch (Throwable ignored) {}
        }, "chroot-helper-download").start();"""

if target in code:
    code = code.replace(target, hook, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(code)
    print("hooked MainActivity.java")
PYTHON_SCRIPT
        log "downloads chroot helper on app start"
    fi
}

patch_chroot_settings() {
    log "patch: added chroot settings"

    # 1. Add Chroot FrameLayout to container_detail_fragment.xml
    local layout_file="$RES/layout/container_detail_fragment.xml"
    if [ -f "$layout_file" ] && ! grep -q "CBCBindRam" "$layout_file"; then
        python3 - <<'PYTHON_SCRIPT' "$layout_file"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

target = """                    <TextView
                        style="@style/FieldSetLabel"
                        android:text="@string/system" />
                </FrameLayout>"""

chroot_xml = """                    <TextView
                        style="@style/FieldSetLabel"
                        android:text="@string/system" />
                </FrameLayout>

                <FrameLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="8dp">

                    <LinearLayout style="@style/FieldSet">
                        <CheckBox
                            android:id="@+id/CBCBindRam"
                            android:layout_width="match_parent"
                            android:layout_height="wrap_content"
                            android:text="@string/root_chroot_bind_ram" />

                        <CheckBox
                            android:id="@+id/CBCBindAndroid"
                            android:layout_width="match_parent"
                            android:layout_height="wrap_content"
                            android:text="@string/root_chroot_bind_android" />
                    </LinearLayout>

                    <TextView
                        style="@style/FieldSetLabel"
                        android:text="@string/root_chroot" />
                </FrameLayout>"""

if target in content:
    content = content.replace(target, chroot_xml, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print("inserted chroot options into container_detail_fragment.xml")
PYTHON_SCRIPT
    fi

    # 2. Hook ContainerDetailFragment.java using ChrootUIHelper (minimal, non-intrusive hook)
    local frag_file="$APP/src/main/java/com/winlator/ContainerDetailFragment.java"
    if [ -f "$frag_file" ] && ! grep -q "ChrootUIHelper" "$frag_file"; then
        python3 - <<'PYTHON_SCRIPT' "$frag_file"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

# View init hook
t1 = 'Box64PresetManager.loadSpinner(sBox64Preset, isEditMode() ? container.getBox64Preset() : preferences.getString("box64_preset", Box64Preset.DEFAULT));'
r1 = t1 + '\n\n        com.winlator.root.ChrootUIHelper.initViews(view, container, isEditMode());'
if t1 in code:
    code = code.replace(t1, r1, 1)

# Confirm check hook
t2 = 'view.findViewById(R.id.BTConfirm).setOnClickListener((v) -> {'
r2 = t2 + '\n            if (!com.winlator.root.ChrootUIHelper.checkRootFSReady(context, isEditMode())) return;'
if t2 in code:
    code = code.replace(t2, r2, 1)

# Edit mode save hook
t3 = 'container.setDesktopTheme(desktopTheme);'
r3 = t3 + '\n                    com.winlator.root.ChrootUIHelper.saveContainerData(view, container);'
if t3 in code:
    code = code.replace(t3, r3, 1)

# Create mode save hook
t4 = 'data.put("desktopTheme", desktopTheme);'
r4 = t4 + '\n                    com.winlator.root.ChrootUIHelper.saveCreationData(view, data);'
if t4 in code:
    code = code.replace(t4, r4, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(code)
print("hooked ContainerDetailFragment.java with ChrootUIHelper")
PYTHON_SCRIPT
    fi

    # 3. Relax blocking in ContainersFragment so user can open detail while rootfs installs
    local containers_frag="$APP/src/main/java/com/winlator/ContainersFragment.java"
    if [ -f "$containers_frag" ]; then
        sed -i 's|if (!RootFS.find(getContext()).isValid()) return false;|// if (!RootFS.find(getContext()).isValid()) return false;|' "$containers_frag"
    fi

}

patch_about() {
    log "patch: changes at about"

    local about_dialog="$APP/src/main/java/com/winlator/contentdialog/AboutDialog.java"
    [ -f "$about_dialog" ] || return 0

    if grep -q "root_winlator_chroot.sh" "$about_dialog"; then
        return 0
    fi

    python3 - <<'PYTHON_SCRIPT' "$about_dialog"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

target = r'''                "CNC DDraw (<a href=\"https://github.com/FunkyFr3sh/cnc-ddraw\">github.com/FunkyFr3sh/cnc-ddraw</a>)"'''
target_comma = target + ","
libsu = r'''                "Libsu (<a href=\"https://github.com/topjohnwu/libsu\">github.com/topjohnwu/libsu</a>) by topjohnwu",'''
busybox = r'''                "BusyBox binaries (<a href=\"https://github.com/YasserNull/ndk-box-kitchen\">github.com/YasserNull/ndk-box-kitchen</a>) by YasserNull",'''
old_credit = r'''                "Distro chroot launching algorithms from (<a href=\"https://github.com/Magisk-Modules-Alt-Repo/chroot-distro\">github.com/Magisk-Modules-Alt-Repo/chroot-distro</a>) by YasserNull"'''
new_credit = r'''                "root_winlator_chroot.sh (<a href=\"https://gist.github.com/YasserNull/19a375d3689084d4fa506a5ec6fbc4f5\">gist.github.com/YasserNull/19a375d3689084d4fa506a5ec6fbc4f5</a>) Distro chroot launching script, algorithms from chroot-distro (<a href=\"https://github.com/Magisk-Modules-Alt-Repo/chroot-distro\">github.com/Magisk-Modules-Alt-Repo/chroot-distro</a>) by YasserNull"'''

if new_credit not in code:
    if old_credit in code:
        code = code.replace(old_credit, new_credit, 1)
    elif target_comma in code:
        replacement = target_comma + "\n" + libsu + "\n" + busybox + "\n" + new_credit
        code = code.replace(target_comma, replacement, 1)
    elif target in code:
        replacement = target_comma + "\n" + libsu + "\n" + busybox + "\n" + new_credit
        code = code.replace(target, replacement, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(code)
    print("added root credits to AboutDialog.java")
PYTHON_SCRIPT
}

patch_chroot_exec() {
    log "patch: chroot lifecycle and execution hooks"

    # 1. GuestProgramLauncherComponent: launch guest in chroot if available
    local launcher_comp="$APP/src/main/java/com/winlator/xenvironment/components/GuestProgramLauncherComponent.java"
    if [ -f "$launcher_comp" ] && ! grep -q "ChrootManager" "$launcher_comp"; then
        python3 - <<'PYTHON_SCRIPT' "$launcher_comp"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

# Hook launchGuestProgram
t1 = 'return ProcessHelper.exec(command, envVars, rootDir, (status) -> {'
hook1 = """        int chrootPid = com.winlator.root.ChrootManager.launchIfChroot(environment, rootDir, guestExecutable, envVars, terminationCallback);
        if (chrootPid >= 0) return chrootPid;

        return ProcessHelper.exec(command, envVars, rootDir, (status) -> {"""

if t1 in code:
    code = code.replace(t1, hook1, 1)

# Hook stop
t2 = 'Process.killProcess(pid);'
hook2 = """com.winlator.root.ChrootManager.stopIfChroot(environment.getContext());
                Process.killProcess(pid);"""

if t2 in code:
    code = code.replace(t2, hook2, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(code)
print("hooked GuestProgramLauncherComponent.java")
PYTHON_SCRIPT
    fi

    # 2. XServerDisplayActivity: early mount, bootstrap check, and termination toast
    local activity_file="$APP/src/main/java/com/winlator/XServerDisplayActivity.java"
    if [ -f "$activity_file" ] && ! grep -q "RootBootstrap" "$activity_file"; then
        python3 - <<'PYTHON_SCRIPT' "$activity_file"
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    code = f.read()

# Startup wait in background thread
t1 = 'if (!isGenerateWineprefix()) {'
h1 = """            if (!com.winlator.root.RootBootstrap.isAttempted()) com.winlator.root.RootBootstrap.prepare(this, null);
            if (!com.winlator.root.RootBootstrap.awaitReady(120000)) {
                runOnUiThread(() -> {
                    com.winlator.core.AppUtils.showToast(this, R.string.root_required);
                    exit();
                });
                return;
            }
            if (!com.winlator.root.ChrootManager.awaitRootFSReady(this, 120000)) {
                runOnUiThread(() -> {
                    com.winlator.core.AppUtils.showToast(this, R.string.unable_to_install_system_files);
                    exit();
                });
                return;
            }
            if (!isGenerateWineprefix()) {"""
if t1 in code:
    code = code.replace(t1, h1, 1)

# Early mount in setupXEnvironment
t2 = 'GuestProgramLauncherComponent guestProgramLauncherComponent = new GuestProgramLauncherComponent();'
h2 = """        final boolean chrootBindRam = container == null || !container.getExtra("chrootBindRam", "1").equals("0");
        final boolean chrootBindAndroid = container == null || !container.getExtra("chrootBindAndroid", "1").equals("0");
        final String chrootTmpfsDirs = container != null ? container.getExtra("chrootTmpfsDirs", "") : "";
        final String chrootAndroidDirs = container != null ? container.getExtra("chrootAndroidDirs", "") : "";
        if (com.winlator.root.RootBootstrap.isReady() && com.winlator.root.RootBootstrap.isChrootSupported()) {
            com.winlator.root.ChrootManager.mount(this, chrootBindRam, chrootBindAndroid, chrootTmpfsDirs, chrootAndroidDirs);
        }

        GuestProgramLauncherComponent guestProgramLauncherComponent = new GuestProgramLauncherComponent();"""
if t2 in code:
    code = code.replace(t2, h2, 1)

# Add ChrootComponent to environment
t3 = 'environment = new XEnvironment(this, rootFS);'
h3 = """environment = new XEnvironment(this, rootFS);
        environment.addComponent(new com.winlator.root.ChrootComponent(chrootBindRam, chrootBindAndroid, chrootTmpfsDirs, chrootAndroidDirs));"""
if t3 in code:
    code = code.replace(t3, h3, 1)

# Guest termination toast on error
t4 = 'guestProgramLauncherComponent.setTerminationCallback((status) -> exit());'
h4 = """guestProgramLauncherComponent.setTerminationCallback((status) -> {
            if (status != 0) runOnUiThread(() -> com.winlator.core.AppUtils.showToast(this, getString(R.string.root_chroot_failed, status)));
            exit();
        });"""
if t4 in code:
    code = code.replace(t4, h4, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(code)
print("hooked XServerDisplayActivity.java")
PYTHON_SCRIPT
    fi

    # 3. ProcessHelper: send signals via RootShell if root is active
    local proc_helper="$APP/src/main/java/com/winlator/core/ProcessHelper.java"
    if [ -f "$proc_helper" ] && ! grep -q "RootShell" "$proc_helper"; then
        sed -i 's|Process.sendSignal(pid, OsConstants.SIGSTOP);|if (com.winlator.root.RootBootstrap.isReady()) com.winlator.root.RootShell.execAsync("kill -STOP "+pid); else Process.sendSignal(pid, OsConstants.SIGSTOP);|' "$proc_helper"
        sed -i 's|Process.sendSignal(pid, OsConstants.SIGCONT);|if (com.winlator.root.RootBootstrap.isReady()) com.winlator.root.RootShell.execAsync("kill -CONT "+pid); else Process.sendSignal(pid, OsConstants.SIGCONT);|' "$proc_helper"
        sed -i 's|Process.sendSignal(pid, OsConstants.SIGKILL);|if (com.winlator.root.RootBootstrap.isReady()) com.winlator.root.RootShell.execAsync("kill -KILL "+pid); else Process.sendSignal(pid, OsConstants.SIGKILL);|' "$proc_helper"
        log "hooked ProcessHelper.java with root signal handling"
    fi

    # 4. XEnvironment: reverse stop order
    local xenv_file="$APP/src/main/java/com/winlator/xenvironment/XEnvironment.java"
    if [ -f "$xenv_file" ]; then
        sed -i 's|for (EnvironmentComponent environmentComponent : this) environmentComponent.stop();|for (int i = components.size()-1; i >= 0; i--) components.get(i).stop();|' "$xenv_file"
    fi

    # 5. WineInstaller: relative symlink for container pattern
    local wine_inst="$APP/src/main/java/com/winlator/core/WineInstaller.java"
    if [ -f "$wine_inst" ]; then
        sed -i 's|FileUtils.symlink(containerPatternDir.getPath(), linkFile.getPath());|FileUtils.symlink("../opt/installed-wine/preinstall/container-pattern", linkFile.getPath());|' "$wine_inst"
    fi
}

patch_ndk_build() {
    log "patch: NDK ndkBuild configuration and adrenotools fixes"

    local app_gradle="$APP/build.gradle"
    if [ -f "$app_gradle" ] && ! grep -q "ndkBuild" "$app_gradle"; then
        python3 - <<'PYTHON_SCRIPT' "$app_gradle"
import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# Add abiFilters arm64-v8a in defaultConfig
if "abiFilters" not in text:
    text = re.sub(r'(defaultConfig\s*\{)', r"\1\n        ndk {\n            abiFilters 'arm64-v8a'\n        }", text)

# Set ndkVersion
if "ndkVersion" in text:
    text = re.sub(r"ndkVersion\s*['\"].*?['\"]", "ndkVersion '29.0.14206865'", text)
else:
    text = re.sub(r'(android\s*\{)', r"\1\n    ndkVersion '29.0.14206865'", text)

# Replace cmake with ndkBuild
cmake_pattern = r'externalNativeBuild\s*\{\s*cmake\s*\{[^}]*\}\s*\}'
ndk_build_block = """externalNativeBuild {
        ndkBuild {
            path 'src/main/cpp/Android.mk'
        }
    }"""
text = re.sub(cmake_pattern, ndk_build_block, text)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print("switched externalNativeBuild to ndkBuild in app/build.gradle")
PYTHON_SCRIPT
    fi

    # Ensure defaultConfig limits ABIs even when ndkBuild was already configured
    python3 - <<'PYTHON_SCRIPT' "$app_gradle"
import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

match = re.search(r'defaultConfig\s*\{', text)
if match:
    start = match.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1

    block = text[start:i]
    if "abiFilters" not in block:
        insert = "\n        ndk {\n            abiFilters 'arm64-v8a'\n        }"
        text = text[:start] + insert + text[start:]
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("added abiFilters arm64-v8a to defaultConfig")
PYTHON_SCRIPT

    # Copy Android.mk and Application.mk if available from source
    if [ -f "$SCRIPT_DIR/app/src/main/cpp/Android.mk" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        cp -f "$SCRIPT_DIR/app/src/main/cpp/Android.mk" "$APP/src/main/cpp/"
        cp -f "$SCRIPT_DIR/app/src/main/cpp/Application.mk" "$APP/src/main/cpp/"
        log "installed Android.mk and Application.mk"
    fi

    # Patch adrenotools memfd_create define
    local linker_ns="$APP/src/main/cpp/libadrenotools/lib/linkernsbypass/android_linker_ns.cpp"
    if [ -f "$linker_ns" ] && ! grep -q "__NR_memfd_create 385" "$linker_ns"; then
        sed -i 's|#define __NR_memfd_create 279|#define __NR_memfd_create 279\n    #elif defined(__arm__)\n        #define __NR_memfd_create 385\n    #elif defined(__x86_64__)\n        #define __NR_memfd_create 319\n    #elif defined(__i386__)\n        #define __NR_memfd_create 356|' "$linker_ns"
        log "patched android_linker_ns.cpp architecture syscalls"
    fi

    # Patch adrenotools hook_impl static_cast
    local hook_impl="$APP/src/main/cpp/libadrenotools/src/hook/hook_impl.cpp"
    if [ -f "$hook_impl" ]; then
        sed -i 's|\.gpuaddr = gslMemDesc->gpuaddr|\.gpuaddr = static_cast<unsigned long>(gslMemDesc->gpuaddr)|' "$hook_impl"
        log "patched hook_impl.cpp cast"
    fi

    # Clean up obsolete CMakeLists.txt when using ndkBuild
    local cmake_file
    for cmake_file in \
        "$APP/src/main/cpp/CMakeLists.txt" \
        "$APP/src/main/cpp/gladiorenderer/CMakeLists.txt" \
        "$APP/src/main/cpp/libadrenotools/CMakeLists.txt" \
        "$APP/src/main/cpp/libadrenotools/lib/linkernsbypass/CMakeLists.txt" \
        "$APP/src/main/cpp/libadrenotools/src/hook/CMakeLists.txt" \
        "$APP/src/main/cpp/midihandler/CMakeLists.txt" \
        "$APP/src/main/cpp/virglrenderer/CMakeLists.txt" \
        "$APP/src/main/cpp/vortekrenderer/CMakeLists.txt" \
        "$APP/src/main/cpp/winlator/CMakeLists.txt"; do
        if [ -f "$cmake_file" ]; then
            rm -f "$cmake_file"
        fi
    done
}

patch_app_name() {
    log "patch: change app name at drawer"

    local strings_file="$RES/values/strings.xml"
    if [ -f "$strings_file" ]; then
        sed -i 's|<string name="app_name">Winlator</string>|<string name="app_name">Root Winlator</string>|' "$strings_file"
    fi

    if [ -f "$SCRIPT_DIR/app/src/main/res/drawable-hdpi/logo_icon.png" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        mkdir -p "$RES/drawable-hdpi"
        cp -f "$SCRIPT_DIR/app/src/main/res/drawable-hdpi/logo_icon.png" "$RES/drawable-hdpi/logo_icon.png"
        log "installed logo_icon.png"
    fi

    local header_file="$RES/layout/main_menu_header.xml"
    if [ -f "$header_file" ] && ! grep -q "logo_icon" "$header_file"; then
        python3 - <<'PYTHON_SCRIPT' "$header_file"
import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

target = r'<ImageView\s+android:layout_width="153dp"\s+android:layout_height="52dp"\s+android:layout_gravity="left\|bottom"\s+android:src="@drawable/logo"\s*/>'
replacement = """<LinearLayout
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_gravity="left|bottom"
        android:gravity="center_vertical"
        android:orientation="horizontal">

        <ImageView
            android:layout_width="56dp"
            android:layout_height="56dp"
            android:src="@drawable/logo_icon" />

        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginStart="8dp"
            android:text="@string/app_name"
            android:textColor="#ffffff"
            android:textSize="24sp"
            android:textStyle="bold" />
    </LinearLayout>"""

xml = re.sub(target, replacement, xml)
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
print("updated main_menu_header.xml")
PYTHON_SCRIPT
    fi

    if [ -f "$header_file" ]; then
        sed -i '/android:translationY="8dp"/d' "$header_file"
    fi
}

patch_theme() {
    log "patch: red UI theme"

    # 1. Update theme colors in styles.xml
    local styles_file="$RES/values/styles.xml"
    if [ -f "$styles_file" ]; then
        sed -i 's|<item name="colorAccent">#0288d1</item>|<item name="colorAccent">#e53935</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimary">#607d8b</item>|<item name="colorPrimary">#c62828</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimaryDark">#455a64</item>|<item name="colorPrimaryDark">#8e0000</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimary">#505963</item>|<item name="colorPrimary">#7f1d1d</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimaryDark">#3f474f</item>|<item name="colorPrimaryDark">#4a1010</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimaryVariant">#607d8b</item>|<item name="colorPrimaryVariant">#b71c1c</item>|g' "$styles_file"
        sed -i 's|<item name="colorSecondaryVariant">#d3dce0</item>|<item name="colorSecondaryVariant">#efc7c7</item>|g' "$styles_file"
        sed -i 's|<item name="colorPrimaryVariant">#56677a</item>|<item name="colorPrimaryVariant">#991b1b</item>|g' "$styles_file"
        sed -i 's|<item name="colorSecondaryVariant">#37424f</item>|<item name="colorSecondaryVariant">#4a2a2a</item>|g' "$styles_file"
        sed -i 's|<item name="android:background">#0278b8</item>|<item name="android:background">#8e0000</item>|g' "$styles_file"
    fi

    # 2. Copy themed drawables from source repository
    if [ -d "$SCRIPT_DIR/app/src/main/res" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
        local img
        for img in \
            "drawable-hdpi/logo_icon.png" \
            "drawable-hdpi/button_positive_normal.9.png" \
            "drawable-hdpi/button_positive_pressed.9.png" \
            "drawable-hdpi/edit_text_focused.9.png" \
            "drawable-hdpi/icon_image_picker.png" \
            "drawable-hdpi/preloader_spinner_dark.png" \
            "drawable-hdpi/preloader_spinner_light.png" \
            "drawable-hdpi/taskmgr_process.png" \
            "drawable-hdpi/toggle_button_on.png" \
            "drawable/icon_notification.png" \
            "drawable-hdpi/container_file_link.png" \
            "drawable-hdpi/container_file_window.png"; do
            if [ -f "$SCRIPT_DIR/app/src/main/res/$img" ]; then
                mkdir -p "$(dirname "$RES/$img")"
                cp -f "$SCRIPT_DIR/app/src/main/res/$img" "$RES/$img"
            fi
        done
        log "installed theme drawables"
    fi
}

case "$PATCH_TYPE" in
    all)
        run_patch icon "red app icon" patch_icon
        run_patch wallpapers "red wallpapers" patch_wallpapers
        run_patch theme "red UI theme" patch_theme
        run_patch app_name "change app name at drawer" patch_app_name
        run_patch package "app package com.rootwinlator" patch_package
        run_patch rootfs "rootfs paths and native assets" patch_rootfs
        run_patch libsu "root backend (libsu)" patch_libsu
        run_patch chroot_helper "runtime chroot helper" patch_chroot_helper
        run_patch chroot_settings "added chroot settings" patch_chroot_settings
        run_patch chroot_exec "chroot execution hooks" patch_chroot_exec
        run_patch about "changes at about" patch_about
        ;;
    icon)
        run_patch icon "red app icon" patch_icon
        ;;
    wallpapers|wallpaper)
        run_patch wallpapers "red wallpapers" patch_wallpapers
        ;;
    theme)
        run_patch theme "red UI theme" patch_theme
        ;;
    app_name|drawer)
        run_patch app_name "change app name at drawer" patch_app_name
        ;;
    package)
        run_patch package "app package com.rootwinlator" patch_package
        ;;
    rootfs)
        run_patch rootfs "rootfs paths and native assets" patch_rootfs
        ;;
    libsu|root)
        run_patch libsu "root backend (libsu)" patch_libsu
        ;;
    chroot_helper|helper)
        run_patch chroot_helper "runtime chroot helper" patch_chroot_helper
        ;;
    chroot_settings|chroot_ui|ui)
        run_patch chroot_settings "added chroot settings" patch_chroot_settings
        ;;
    chroot_exec|exec)
        run_patch chroot_exec "chroot execution hooks" patch_chroot_exec
        ;;
    about)
        run_patch about "changes at about" patch_about
        ;;
    ndk)
        run_patch ndk "ndk build" patch_ndk_build
        ;;
    *)
        die "unknown patch type: $PATCH_TYPE (expected: all, icon, wallpapers, theme, app_name, package, rootfs, libsu, chroot_helper, chroot_settings, chroot_exec, about, ndk)"
        ;;
esac

log_ok "done"
