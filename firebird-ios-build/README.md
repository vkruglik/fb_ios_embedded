# firebird-ios-build — cross-building embedded Firebird 5 for iOS

One script that builds the Firebird 5 embedded engine and ICU for iOS
devices (`arm64`, iOS 15.0 or later) from a clean `FirebirdSQL/firebird`
checkout and packages each library as its own `.xcframework`. The output
goes into the [`fb_ios_embedded`](../README.md) Flutter plugin, or into any
iOS app that loads `libfbclient` itself.

**Verified build:** Firebird `v5.0.4`, ICU 71.1, Mac mini M4,
macOS 26.7.3, Xcode 27.2 (iOS SDK 27.2). The engine passed a full device
test on an iPhone 17 Pro Max (iOS 27.2.1), including `UNICODE_CI` on Cyrillic
text. A clean build takes about 5 minutes on an M4, plus the first clone of
the vcpkg submodule.

The approach follows Firebird's own CI: the Android job's
`--with-cross-build=<platform>` (one `make` runs the native phase for host
tools and the cross phase for the target) combined with the macOS job's
`--with-builtin-tommath --with-builtin-tomcrypt`.

## Contents

```
firebird-ios-build/
├── build_firebird_ios.sh        the build: patches → vcpkg ICU → configure → make → checks → xcframeworks
├── fetch_firebird_msg.sh        firebird.msg from the official macOS package of the same tag
├── install_into_plugin.sh       copies the output into fb_ios_embedded (ios/Frameworks, assets/fb)
├── builds/posix/
│   ├── make.ios.arm64           platform file for the device (CROSS_CONFIG=ios.arm64)
│   └── make.ios.arm64.sim       Apple Silicon simulator (only with FB_IOS_SIM=1)
├── ios-tools/ios-clang(++)      compiler wrappers for the cross phase
├── vcpkg-custom-triplets/       fb-arm64-ios, fb-arm64-ios-simulator
├── vcpkg-overlay-ports/icu/     the vcpkg port of ICU 71.1, adjusted for iOS
└── patches/                     three patches to the Firebird sources
```

## Requirements

- An Apple Silicon Mac with Xcode; `xcode-select -p` must point inside
  `Xcode.app`.
- Homebrew tools, as in Firebird's macOS CI job:
  `brew install automake autoconf-archive libtool ninja pkg-config cmake`.

## Running

```bash
mkdir -p ~/fb && cd ~/fb
git clone https://github.com/FirebirdSQL/firebird.git firebird-ios
cd firebird-ios && git checkout v5.0.4

/path/to/firebird-ios-build/fetch_firebird_msg.sh 5.0.4 ~/fb/firebird.msg
FB_MSG_FILE=~/fb/firebird.msg /path/to/firebird-ios-build/build_firebird_ios.sh 2>&1 | tee ~/fb/build.log

/path/to/firebird-ios-build/install_into_plugin.sh ~/fb/firebird-ios/ios-out /path/to/fb_ios_embedded
```

Environment variables:

| Variable | Meaning |
|---|---|
| `FB_MSG_FILE` | path to `firebird.msg` (see below) |
| `FB_IOS_MIN` | minimum iOS version, `15.0` by default; must match the plugin's podspec |
| `FB_IOS_SIM=1` | also build the simulator slice |
| `FB_IOS_OUT` | output directory, `<checkout>/ios-out` by default |
| `FB_SKIP_VCPKG=1` | do not rebuild ICU on repeated runs |
| `FB_SKIP_BUILD=1` | skip configure and make; only collect, check and package an already built tree |

A repeated run is the same command: the script runs `distclean` itself and
recognises patches that are already applied.

**`firebird.msg`.** The cross phase builds `build_file` for iOS, so the
message file cannot be produced on the Mac. The file does not depend on the
platform: the one from the official macOS package of the same tag is
byte-identical to a native build. `fetch_firebird_msg.sh` downloads that
package from the Firebird release on GitHub, checks its SHA-256 digest and
extracts the file without installing anything.

## Output

`ios-out/xcframeworks/` — 12 frameworks: `Firebird` (libfbclient),
`FirebirdEngine`, `FirebirdIntl`, `FirebirdIbUtil`, `FirebirdSrp`,
`FirebirdChaCha`, `FirebirdLegacyAuth`, `FirebirdLegacyUserManager`,
`FirebirdUdrEngine`, `ICUdata`, `ICUuc`, `ICUi18n`.

`ios-out/assets/` — `firebird.msg`, `firebird.conf`, `plugins.conf`,
`fbintl.conf`, `databases.conf` (templates), `icu_version.txt` and
`plugin_frameworks.txt` (read by the plugin).

The script checks every library before packaging: `arm64` (`lipo`),
`platform IOS` (`vtool`), and no dependencies outside `@rpath/`, `/usr/lib`
and `/System` (`otool -L`). libc++ is the iOS system one; tommath and
tomcrypt are linked statically. The device slice is about 50 MB.

## Problems solved, and where

Each row is a real stop of the build or of the device test, with the fix.

| Stop | Fix |
|---|---|
| `mac_utils.m` uses `SecTaskCreateFromSelf` / `SecTaskCopyValueForEntitlement`, absent from the iOS SDK | `patches/0001`: on iOS `isSandboxed()` returns `true` |
| `system()` is unavailable on iOS (`utl.cpp` EDIT in isql, replication archive commands, isql SHELL) | `patches/0002`: under `#ifdef IOS` the call fails instead (`IOS` is already known to Firebird) |
| the libc++ of Xcode 27 reads `propagate_on_container_*` from `std::allocator_traits`, which Firebird's `PoolAllocator` specialisation did not declare | `patches/0003`: the members with standard defaults |
| on Darwin, `configure.ac` adds the libc++ of the *macOS* vcpkg triplet to all phases | `make.ios.arm64` filters these flags out of `AC_CFLAGS/AC_CXXFLAGS/AC_LDFLAGS`; the iOS SDK libc++ is used |
| the cross phase takes its config header from `src/include/cross/<CROSS_CONFIG>`, which exists for Android only | the script generates `src/include/cross/ios.arm64` from the native `autoconfig.auto` |
| vcpkg 2023-08 refuses package arguments in manifest mode, and `VCPKG_FEATURE_FLAGS=-manifests` no longer helps | vcpkg runs from outside the Firebird tree (classic mode) |
| classic mode would take ICU 73.1 from the vcpkg tree, while Firebird pins 71.1; different ICU versions give different `COLL-VERSION` in databases | the ICU 71.1 port ships here as an overlay (`vcpkg-overlay-ports/icu`, vcpkg git tree `13fe0c90`) |
| the manifest-mode install that `configure` runs for the host may remove other packages from `vcpkg_installed` | iOS ICU goes into its own `vcpkg_installed_ios/` |
| ICU's `pkgdata` calls `system()` | the overlay port builds ICU for iOS with `--disable-tools --disable-extras`; host tools build the data via `--with-cross-build` |
| `extern/decNumber` compiles with bare `$(CC)`: `string.h` not found | `make.ios.arm64` exports `CROSS_FLAGS`, as the Android file does |
| libcds (CMake) wants a single file in `CMAKE_CXX_COMPILER`; the host `MACOSX_DEPLOYMENT_TARGET` added `-mmacosx-version-min` next to the iOS flag | `CC`/`CXX` are the `ios-tools` wrappers that append `-arch arm64 -isysroot <iOS SDK> <min iOS>` at the end; `MACOSX_DEPLOYMENT_TARGET` is unexported, `SDKROOT` is the iOS SDK |
| with builtin tommath/tomcrypt the native phase builds them inside `extern/`, and the cross phase then links those macOS objects | `make.ios.arm64` and the script delete `*.o/*.lo/*.la` and `.libs` in `extern/libtommath` and `extern/libtomcrypt` |
| CMake 4 leaves `CMAKE_OSX_SYSROOT` empty and vcpkg 2023-08 writes an empty `-isysroot`, which swallows the next flag: "C compiler cannot create executables" for host ICU | the script exports `SDKROOT` (the macOS SDK), as Firebird's macOS CI job does; the cross phase overrides it |
| the cross phase puts libraries flat into `gen/Release/firebird/` | the collection step looks in both layouts |
| App Store Connect rejects loose `.dylib` files and nested frameworks | one library = one framework = one `.xcframework`; `install_name_tool` rewrites ids and references to `@rpath/<FW>.framework/<FW>` |
| the engine loads `ib_util` on every start (`EngineStartup::init`) and logs "ib_util init failed" without it | `libib_util.dylib` becomes `FirebirdIbUtil.framework`; the plugin adds the `lib/libib_util.dylib` symlink |

## Another 5.0.x tag

The platform files and triplets do not depend on the tag. If a patch does
not apply (`git apply --check` fails), the script stops and names it; apply
the same few lines by hand and save the result as the new patch. The
`cross1/cross2` scheme and `src/include/cross/` are the same across 5.x.

Typical stops on a new tag or Xcode:

1. `autogen.sh` cannot find `glibtoolize`: `brew install libtool`.
2. vcpkg ICU fails for the triplet: see `vcpkg/buildtrees/icu/*.log`.
3. "no such function / header" in the cross phase: fix
   `src/include/cross/ios.arm64` through the `sed` at step 2a of the script,
   not the sources. A `duplicate symbol` from an anonymous namespace: a patch
   in `patches/`.
4. `building for iOS, but linking … built for macOS` with
   `vcpkg_installed/fb-arm64-osx` in the path: the `filter-out` in
   `make.ios.arm64` no longer matches; see the real `AC_CXXFLAGS` /
   `AC_LDFLAGS` in `gen/make.defaults`.
5. `platform MACOS` at step 5: the host compiler got into the cross phase;
   check `CC`/`CXX` in `gen/make.crossPlatform`.

## ICU fallback

Firebird on Darwin opens ICU with `dlopen("lib/libicuuc.<ver>.dylib")`
relative to the working directory (`src/common/unicode_util.cpp`). The
plugin makes that work with symlinks and `chdir`, and it did on iOS 27. If
some iOS version refuses it (the engine works, `UNICODE_CI` does not, and
the device console shows `failed to load UC icu module`), patch
`unicode_util.cpp`: for `TARGET_OS_IPHONE`, build absolute paths with
`fb_utils::getPrefix(IConfigManager::DIR_LIB, …)`, as the `ANDROID` branch of
the same file does.

## License

The scripts, platform files, wrappers and triplets are MIT-licensed. The
patches modify Firebird source files and are under the license of the file
they modify (IPL 1.0 or IDPL 1.0). The ICU overlay port is derived from
vcpkg (MIT, `vcpkg-overlay-ports/LICENSE.vcpkg.txt`).
