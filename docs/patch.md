# Patch Guide

`apply_patches.sh` applies the Root Winlator changes to a clean winlator-app source
tree. It is idempotent: patches skip work that is already applied.

## Requirements

- Bash
- `sed`
- `python3`
- ImageMagick (`magick` or `convert`)
- `zstd` when the rootfs asset fallback patcher is used
- Network access on the device at runtime, for the chroot helper download

## First Step: Clone Winlator

```bash
git clone https://github.com/brunodev85/winlator-app
```

## Usage

```bash
./apply_patches.sh [project-dir] [patch-type] [--exclude "name ..."]
```

- `project-dir`: Winlator source directory containing `app/`. Defaults to the
  current directory.
- `patch-type`: a single patch name, or `all`. Defaults to `all`.
- `--exclude`: skips one or more patches. Values can be separated by spaces,
  commas, semicolons, or hyphens, for example `"theme ndk"` or `"theme,about"`.

Help:

```bash
./apply_patches.sh --help
```

Examples:

```bash
# Apply every default patch to winlator-app
./apply_patches.sh winlator-app

# Apply only the icon patch
./apply_patches.sh winlator-app icon

# Apply everything except the theme and about patches
./apply_patches.sh winlator-app --exclude "theme about"

# Apply only the NDK patch (it is not part of all)
./apply_patches.sh winlator-app ndk

# Run from a different directory
./apply_patches.sh /path/to/winlator-app all
```

## Default Patch Order

`all` applies these patches in order:

| # | Patch | Display name |
|---|-------|--------------|
| 1 | `icon` | red app icon |
| 2 | `wallpapers` | red wallpapers |
| 3 | `theme` | red UI theme |
| 4 | `app_name` | change app name at drawer |
| 5 | `package` | app package com.rootwinlator |
| 6 | `build` | Java 17 and Gradle memory |
| 7 | `rootfs` | rootfs paths and native assets |
| 8 | `libsu` | root backend (libsu) |
| 9 | `chroot_helper` | runtime chroot helper |
| 10 | `chroot_settings` | added chroot settings |
| 11 | `chroot_exec` | chroot execution hooks |
| 12 | `about` | changes at about |

`ndk` is intentionally not included in `all`. It only runs when requested
explicitly:

```bash
./apply_patches.sh winlator-app ndk
```

## Patches

### `icon`

Recolors the launcher icons and the header logo from blue to red with
ImageMagick, using the same hue rotation as the Root Winlator branding.

Targets:

- `app/src/main/res/mipmap-*/ic_launcher.png`
- `app/src/main/res/mipmap-*/ic_launcher_round.png`
- `app/src/main/res/mipmap-*/ic_launcher_foreground.png`
- `app/src/main/res/drawable-*/logo.png`

An image is recolored only when its mean blue channel is greater than its mean
red channel. Otherwise it is skipped.

### `wallpapers`

Recolors `wallpaper-1` and `wallpaper-2` from blue to red and updates their
`config.json` color values so the background fills match the images.

Targets:

- `app/src/main/assets/wallpapers/wallpaper-1/image.png`
- `app/src/main/assets/wallpapers/wallpaper-1/config.json`
- `app/src/main/assets/wallpapers/wallpaper-2/image.png`
- `app/src/main/assets/wallpapers/wallpaper-2/config.json`

### `theme`

Applies the red UI theme.

- Replaces the known blue theme colors in
  `app/src/main/res/values/styles.xml` with red equivalents.
- Copies themed drawables from the reference repository, including buttons,
  spinners, notification icon, file-link icons, and `logo_icon.png`.

### `app_name`

Changes the app name shown in the drawer.

- Sets `app_name` to `Root Winlator` in `values/strings.xml`.
- Copies `drawable-hdpi/logo_icon.png`.
- Replaces the header logo `ImageView` in `main_menu_header.xml` with a `56dp`
  red logo icon plus the app name text.

### `package`

Changes the application package to `com.rootwinlator`.

- `applicationId` in `app/build.gradle`
- FileProvider authority in `AndroidManifest.xml`
- `FileUtils` now builds the FileProvider authority from
  `activity.getPackageName()`
- `AppUtils.INTERNAL_STORAGE`
- Cache path in `app/src/main/cpp/winlator/include/winlator.h`

### `build`

- Sets `sourceCompatibility` and `targetCompatibility` to Java 17 in
  `app/build.gradle`. This removes the JDK 21 deprecation warning for Java 8
  source and target values.
- Sets `org.gradle.jvmargs` to a 2 GB heap with a 1 GB metaspace limit in
  `gradle.properties`. This prevents `Java heap space` failures in tasks such
  as `compressReleaseAssets`.

### `rootfs`

Changes the rootfs location to the root-friendly path
`/data/local/tmp/root-winlator` and applies the required runtime changes.

- X11 and Vortek socket paths in native headers.
- `RootFS` root directory.
- `RootFSInstaller` version bump to `24`.
- Disables `WINEESYNC` in `Container` and `XServerDisplayActivity`.
- Installs the Root Winlator asset set from the reference repository: Box64,
  graphics drivers, container pattern, rootfs, and rootfs patches.
- When source assets are not available, patches the other `.tzst` archives in
  place with Python and `zstd`. `rootfs.tzst` is not rewritten by this fallback.

### `libsu`

Installs the root backend.

- Adds the JitPack repository to the top-level `build.gradle`.
- Adds the Libsu dependency to `app/build.gradle`.
- Copies the `com.winlator.root` Java classes.
- Copies `strings_root.xml` translations.

### `chroot_helper`

Installs the runtime chroot helper downloader.

- Installs `BusyboxInstaller` with the helper download URL and SHA-256
  verification.
- Adds the helper download step to `MainActivity.onCreate`, so the app fetches
  the helper in the background at startup.
- Saves the helper as `root_winlator_chroot.sh` in the app's private `bin/`
  directory.
- If the helper file exists with the expected SHA-256, it is reused; otherwise
  it is downloaded again.

### `chroot_settings`

Adds the chroot settings UI.

- Adds the RAM bind and Android bind checkboxes to
  `container_detail_fragment.xml`.
- Hooks `ContainerDetailFragment` with `ChrootUIHelper` for loading, saving,
  and validating chroot options.
- Relaxes the rootfs validity gate in `ContainersFragment`.

### `chroot_exec`

Adds chroot execution hooks to the runtime.

- `GuestProgramLauncherComponent`: launch and stop guests through the chroot
  manager when available.
- `XServerDisplayActivity`: bootstrap root, wait for the rootfs, mount the
  chroot early, add `ChrootComponent`, and show a termination toast on failure.
- `ProcessHelper`: send stop/continue/kill signals through the root shell when
  root is active.
- `XEnvironment`: stop components in reverse order.
- `WineInstaller`: use a relative symlink for the container pattern.

### `about`

Adds third-party credits to the About dialog for Libsu, BusyBox binaries, the
`root_winlator_chroot.sh` helper, and the chroot-distro launching algorithms.

### `ndk` (explicit only)

Switches the native build to `ndkBuild` and fixes the build configuration.

- Uses NDK `29.0.14206865`.
- Replaces the CMake `externalNativeBuild` block with `Android.mk`.
- Adds `abiFilters 'arm64-v8a'` to `defaultConfig`.
- Copies `Android.mk` and `Application.mk`.
- Patches adrenotools architecture syscalls and the `hook_impl.cpp` cast.
- Removes the `CMakeLists.txt` files replaced by the ndkBuild setup.

This patch is not part of `all`. Run it explicitly:

```bash
./apply_patches.sh winlator-app ndk
```

## Excluding Patches

`--exclude` accepts patch names.

Examples:

```bash
./apply_patches.sh winlator-app --exclude "theme about"
./apply_patches.sh winlator-app all --exclude "wallpapers,ndk"
./apply_patches.sh winlator-app --exclude "chroot_settings app_name"
```