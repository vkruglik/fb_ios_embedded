#!/usr/bin/env bash
# build_firebird_ios.sh  —  firebird-ios-build v3
#
# Cross-builds the Firebird 5 embedded engine for iOS and packages it as a set
# of .xcframeworks (one framework per library, as iOS and App Store Connect
# require).
#
# The scheme follows the official Android job of Firebird's CI
# (.github/workflows/main.yml, build-android-initial):
#     ./autogen.sh ... --with-cross-build=<platform> ...
#     make
# where a single make run does both the native phase (host tools such as gpre)
# and the cross phase (Makefile.in:364-366). No separate native build is needed.
#
# Run from the root of a clean FirebirdSQL/firebird checkout of the wanted tag:
#     cd ~/fb/firebird-ios
#     FB_MSG_FILE=~/fb/firebird.msg /path/to/firebird-ios-build/build_firebird_ios.sh 2>&1 | tee ../build.log
#
# Environment variables:
#     FB_MSG_FILE=<file>  firebird.msg (fetch_firebird_msg.sh downloads it)
#     FB_IOS_SIM=1        also build the iOS simulator slice (off by default)
#     FB_IOS_MIN=15.0     minimum iOS (must match the plugin's podspec; 15.0 is the Flutter 3.47 minimum)
#     FB_IOS_OUT=<dir>    output directory (default <repo>/ios-out)
#     FB_SKIP_VCPKG=1     do not reinstall ICU through vcpkg (repeated runs)
#     FB_SKIP_BUILD=1     skip configure and make, only collect, check and package
#
set -euo pipefail

if [ ! -f configure.ac ] || [ ! -d builds/posix ]; then
  echo "Run from the root of a FirebirdSQL/firebird checkout" >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode is not selected: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB_ROOT="$(pwd)"
OUT="${FB_IOS_OUT:-$FB_ROOT/ios-out}"
IOS_MIN="${FB_IOS_MIN:-15.0}"
export IOS_MIN_VERSION="$IOS_MIN"      # read by make.ios.arm64*
export LIBTOOLIZE=glibtoolize LIBTOOL=glibtool   # as in the macOS CI job
# SDKROOT as in the macOS CI job. Without it CMake 4.x leaves
# CMAKE_OSX_SYSROOT empty, while vcpkg 2023-08 still writes
# "-isysroot ${CMAKE_OSX_SYSROOT}": the empty -isysroot swallows the next flag
# and configure of the host ICU fails with "C compiler cannot create
# executables". The cross phase (make.ios.arm64) overrides SDKROOT with the
# iOS SDK.
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
JOBS="$(sysctl -n hw.ncpu)"

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "0. Kit files -> source tree"
git submodule update --init --recursive
cp "$SCRIPT_DIR/builds/posix/make.ios.arm64"     builds/posix/make.ios.arm64
cp "$SCRIPT_DIR/builds/posix/make.ios.arm64.sim" builds/posix/make.ios.arm64.sim
# compiler wrappers for cross2 (see make.ios.arm64)
mkdir -p builds/posix/ios-tools
cp "$SCRIPT_DIR"/ios-tools/ios-clang "$SCRIPT_DIR"/ios-tools/ios-clang++ builds/posix/ios-tools/
chmod +x builds/posix/ios-tools/ios-clang builds/posix/ios-tools/ios-clang++
mkdir -p vcpkg-custom/triplets
cp "$SCRIPT_DIR"/vcpkg-custom-triplets/fb-arm64-ios*.cmake vcpkg-custom/triplets/

log "0a. Source patches for iOS"
for p in "$SCRIPT_DIR"/patches/*.patch; do
  if git apply --check --reverse "$p" >/dev/null 2>&1; then
    echo "  already applied: $(basename "$p")"
  elif git apply --check "$p" >/dev/null 2>&1; then
    git apply "$p" && echo "  applied: $(basename "$p")"
  else
    die "patch $(basename "$p") does not apply to these sources (a tag other than v5.0.4?). Review the patch and apply it by hand."
  fi
done

# ---------------------------------------------------------------------------
log "1. vcpkg: ICU for iOS (icu only, classic mode; the manifest's libcxx is not needed for iOS)"
[ -x ./vcpkg/vcpkg ] || ./vcpkg/bootstrap-vcpkg.sh -disableMetrics
# vcpkg 2023-08-09 (pinned by Firebird v5.0.4):
#  - VCPKG_FEATURE_FLAGS=-manifests no longer turns manifest mode off: seeing
#    vcpkg.json at the Firebird root, vcpkg refuses "individual package
#    arguments" in manifest mode. Classic mode is reached by running vcpkg from
#    a directory OUTSIDE the tree (vcpkg looks for a manifest upwards from cwd).
#  - In classic mode the icu port comes from the vcpkg tree (73.1), while
#    Firebird pins 71.1 in its manifest, and so does the macOS build. Different
#    ICU on iOS and macOS would give incompatible collation versions
#    (COLL-VERSION) in databases. The 71.1 port ships with this kit:
#    vcpkg-overlay-ports/icu (git tree 13fe0c90).
#  - A separate install root, vcpkg_installed_ios: the manifest mode that
#    configure runs for the host build (fb-arm64-osx) may remove from the shared
#    vcpkg_installed everything that is not in the manifest.
ICU_ROOT="$FB_ROOT/vcpkg_installed_ios"
vcpkg_icu () {   # $1 = triplet
  if [ "${FB_SKIP_VCPKG:-0}" = "1" ] && [ -d "$ICU_ROOT/$1/lib" ]; then
    echo "  skipped ($1 already installed)"; return
  fi
  (cd "$FB_ROOT/.." && "$FB_ROOT/vcpkg/vcpkg" install "icu:$1" \
      --vcpkg-root="$FB_ROOT/vcpkg" \
      --overlay-ports="$SCRIPT_DIR/vcpkg-overlay-ports" \
      --overlay-triplets="$FB_ROOT/vcpkg-custom/triplets" \
      --x-install-root="$ICU_ROOT")
}
vcpkg_icu fb-arm64-ios
[ "${FB_IOS_SIM:-0}" = "1" ] && vcpkg_icu fb-arm64-ios-simulator

# ---------------------------------------------------------------------------
# One cross build: $1 = platform file name (ios.arm64 | ios.arm64.sim),
# $2 = label (device | simulator), $3 = vcpkg triplet
build_slice () {
  local CROSS="$1" LABEL="$2" TRIPLET="$3"
  local ICU_LIB="$ICU_ROOT/$TRIPLET/lib"
  local SLICE="$OUT/$LABEL"

  # FB_SKIP_BUILD=1: do not rebuild (steps 2-3), package the tree already
  # built; for changes to steps 4-7.
  if [ "${FB_SKIP_BUILD:-0}" != "1" ]; then

  log "2. [$LABEL] configure (--with-cross-build=$CROSS): like the Android CI job, plus builtin tommath/tomcrypt like the macOS job"
  make distclean >/dev/null 2>&1 || true
  rm -rf gen temp src/include/gen/autoconfig.h
  # distclean leaves the objects of the builtin tommath/tomcrypt in extern/
  # (libtool builds them inside the tree), so foreign .o/.lo/.la from a
  # previous run would remain.
  find extern/libtommath extern/libtomcrypt \( -name "*.o" -o -name "*.lo" -o -name "*.la" \) -delete
  rm -rf extern/libtommath/.libs extern/libtomcrypt/.libs
  ./autogen.sh --prefix=/opt/firebird --enable-binreloc \
      --with-builtin-tommath --with-builtin-tomcrypt \
      --without-editline \
      --with-cross-build="$CROSS"

  log "2a. [$LABEL] config header for cross2: src/include/cross/$CROSS from autoconfig.auto"
  # Makefile.in:392: cross2 makes autoconfig.h a symlink to src/include/cross/$(CROSS_CONFIG).
  # For iOS we take the result of the native configure for Darwin (the APIs are
  # the same) and adjust what is known to differ on iOS. If compilation fails on
  # a missing function, fix it here (#undef HAVE_...), not in the sources.
  [ -f src/include/gen/autoconfig.auto ] || die "configure did not create src/include/gen/autoconfig.auto"
  # Add iOS adjustments here as -e 's|^#define HAVE_XXX .*|/* #undef HAVE_XXX */|'
  # (none are required so far: Firebird does not check for system()/posix_spawn,
  # and fork() exists in the iOS SDK and is used only by the server).
  sed -e 's|^#define FB_PREFIX .*|#define FB_PREFIX "/opt/firebird"|' \
      src/include/gen/autoconfig.auto > "src/include/cross/$CROSS"
  grep -q '#define DARWIN' "src/include/cross/$CROSS" || die "no DARWIN in autoconfig.auto: did configure run for Darwin?"

  log "3. [$LABEL] make (native phase for host tools + cross2 for iOS)"
  make -j"$JOBS"
  else
    log "2-3. [$LABEL] build skipped (FB_SKIP_BUILD=1)"
  fi

  log "4. [$LABEL] collecting libraries"
  rm -rf "$SLICE"; mkdir -p "$SLICE/lib" "$SLICE/plugins" "$SLICE/intl"
  local FBOUT="gen/Release/firebird"
  # cross2 puts the libraries FLAT into gen/Release/firebird/, without
  # lib/ plugins/ intl/, so look in both places.
  fbpick () {   # $1 = subdirectory in the install layout, $2 = file name
    if [ -f "$FBOUT/$1/$2" ]; then echo "$FBOUT/$1/$2"; else echo "$FBOUT/$2"; fi
  }
  cp "$(fbpick lib libfbclient.dylib)"         "$SLICE/lib/"      || die "no libfbclient.dylib"
  cp "$(fbpick plugins libEngine13.dylib)"     "$SLICE/plugins/"  || die "no libEngine13.dylib"
  cp "$(fbpick intl libfbintl.dylib)"          "$SLICE/intl/"     || die "no libfbintl.dylib"
  # optional plugins: packaged if they were built (Srp is needed if the engine
  # requires AuthServer; udr_engine for UDR). Their absence is not an error.
  for opt in libSrp.dylib libLegacy_Auth.dylib libLegacy_UserManager.dylib libudr_engine.dylib libChaCha.dylib; do
    local optf; optf="$(fbpick plugins "$opt")"
    [ -f "$optf" ] && cp "$optf" "$SLICE/plugins/" || true
  done
  # ICU strictly from this slice's triplet (no fb-arm64-ios* globs, which
  # would mix in the simulator)
  cp "$ICU_LIB"/libicudata.*.dylib "$ICU_LIB"/libicuuc.*.dylib "$ICU_LIB"/libicui18n.*.dylib "$SLICE/lib/" \
      || die "no ICU .dylib in $ICU_LIB"
  # ib_util: the engine loads it on EVERY start (EngineStartup::init ->
  # IbUtil::initialize, unconditionally) and logs "ib_util init failed" in
  # firebird.log without it. Packaged as the FirebirdIbUtil framework; the
  # fb_ios_embedded plugin creates the lib/libib_util.dylib symlink.
  cp "$(fbpick lib libib_util.dylib)" "$SLICE/lib/" || die "no libib_util.dylib"
  # drop duplicate symlinks: keep only the files with the full version (libicuuc.71.1.dylib)
  find "$SLICE/lib" -type l -delete

  if [ "$LABEL" = "device" ]; then
    log "4a. assets (shared by the slices)"
    mkdir -p "$OUT/assets"
    cp "$FBOUT/firebird.conf"      "$OUT/assets/" 2>/dev/null || cp builds/install/misc/firebird.conf "$OUT/assets/"
    # firebird.msg is made by build_file, which cross2 builds for iOS, so it
    # cannot run on the Mac and gen/Release has no such file. The message file
    # does not depend on the platform (the official macOS package and a native
    # macOS 5.0.4 build are byte-identical). Order: FB_MSG_FILE; an official
    # package of the same tag unpacked under ~/dev/firebird-official; a native
    # macOS build next to this checkout.
    local MSG="$FBOUT/firebird.msg"
    if [ ! -f "$MSG" ]; then
      local TAGVER; TAGVER="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
      for MSG in "${FB_MSG_FILE:-}" \
                 "$HOME/dev/firebird-official/${TAGVER:-?}-macos-arm64/firebird/firebird.msg" \
                 "$FB_ROOT/../firebird-macos/gen/Release/firebird/firebird.msg"; do
        [ -n "$MSG" ] && [ -f "$MSG" ] && break
      done
    fi
    [ -f "$MSG" ] || die "no firebird.msg: set FB_MSG_FILE (fetch_firebird_msg.sh ${TAGVER:-<version>} <file>)"
    cp "$MSG" "$OUT/assets/firebird.msg"
    echo "  firebird.msg: $MSG"
    cp "$FBOUT/intl/fbintl.conf"   "$OUT/assets/" 2>/dev/null || cp builds/install/misc/fbintl.conf "$OUT/assets/"
    cp "$FBOUT/plugins.conf"       "$OUT/assets/" 2>/dev/null || cp builds/install/misc/plugins.conf "$OUT/assets/"
    cp "$FBOUT/databases.conf"     "$OUT/assets/" 2>/dev/null || cp builds/install/misc/databases.conf "$OUT/assets/"
    [ -f "$FBOUT/security5.fdb" ] && cp "$FBOUT/security5.fdb" "$OUT/assets/" || true
    # ICU data: from vcpkg (share/icu/... or next to lib), named icudt<major>l.dat
    local DAT
    DAT="$(find "$ICU_ROOT/$TRIPLET" -iname 'icudt*l.dat' | head -n1 || true)"
    if [ -n "$DAT" ]; then cp "$DAT" "$OUT/assets/"; else
      echo "  NOTE: no icudt*l.dat in vcpkg; ICU was probably built with the data inside libicudata (fine, no .dat is needed)"
    fi
    # ICU major.minor version: the plugin needs it for the lib/libicuuc.<ver>.dylib symlink names
    local UC; UC="$(ls "$SLICE"/lib/libicuuc.*.dylib | head -n1)"
    basename "$UC" | sed -E 's/^libicuuc\.([0-9]+\.[0-9]+)\.dylib$/\1/' > "$OUT/assets/icu_version.txt"
    echo "  ICU: $(cat "$OUT/assets/icu_version.txt")"
  fi

  log "5. [$LABEL] checking the slice: lipo / vtool / otool"
  local want="IOS"; [ "$LABEL" = "simulator" ] && want="IOSSIMULATOR"
  for f in "$SLICE"/lib/*.dylib "$SLICE"/plugins/*.dylib "$SLICE"/intl/*.dylib; do
    lipo -info "$f" | grep -q arm64 || die "$f: not arm64"
    vtool -show-build "$f" | grep -q "platform $want" || die "$f: platform is not $want (built for the Mac, or a wrong slice)"
    # the first line of otool -L is the file itself; skip it
    if otool -L "$f" | tail -n +2 | grep -qE '/opt/homebrew|/usr/local/|/opt/firebird|/Users/'; then
      otool -L "$f"; die "$f refers to paths of the build machine"
    fi
  done
  echo "  all libraries of the $LABEL slice: arm64, platform $want, clean dependencies"
}

build_slice ios.arm64 device fb-arm64-ios
[ "${FB_IOS_SIM:-0}" = "1" ] && build_slice ios.arm64.sim simulator fb-arm64-ios-simulator

# ---------------------------------------------------------------------------
# Packaging: one library = one .framework = one .xcframework.
# Framework names (and the executables inside) have no dots and no versions.
log "6. Packaging as .xcframework"

# library -> framework name; ICU names are matched regardless of version
fw_name () {   # $1 = basename of the .dylib
  case "$1" in
    libfbclient.dylib)            echo Firebird ;;
    libEngine13.dylib)            echo FirebirdEngine ;;
    libfbintl.dylib)              echo FirebirdIntl ;;
    libSrp.dylib)                 echo FirebirdSrp ;;
    libLegacy_Auth.dylib)         echo FirebirdLegacyAuth ;;
    libLegacy_UserManager.dylib)  echo FirebirdLegacyUserManager ;;
    libudr_engine.dylib)          echo FirebirdUdrEngine ;;
    libChaCha.dylib)              echo FirebirdChaCha ;;
    libicudata.*.dylib)           echo ICUdata ;;
    libicuuc.*.dylib)             echo ICUuc ;;
    libicui18n.*.dylib)           echo ICUi18n ;;
    libib_util.dylib)             echo FirebirdIbUtil ;;
    *) echo "" ;;
  esac
}

make_framework () {   # $1 = path to the .dylib, $2 = slice frameworks directory, $3 = platform tag (iPhoneOS|iPhoneSimulator)
  local SRC="$1" DST="$2" PLAT="$3"
  local NAME; NAME="$(fw_name "$(basename "$SRC")")"
  [ -n "$NAME" ] || { echo "  skipping $(basename "$SRC") (no framework name)"; return; }
  local FW="$DST/$NAME.framework"
  mkdir -p "$FW"
  cp "$SRC" "$FW/$NAME"
  install_name_tool -id "@rpath/$NAME.framework/$NAME" "$FW/$NAME"
  cat > "$FW/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>org.firebirdsql.ios.$NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>5.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$PLAT</string></array>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict></plist>
PLIST
}

# relink inter-library references: everything that pointed to a lib*.dylib of
# our set must now point to @rpath/<FW>.framework/<FW>
relink_frameworks () {   # $1 = directory with *.framework
  local DIR="$1"
  for FW in "$DIR"/*.framework; do
    local NAME; NAME="$(basename "$FW" .framework)"
    local BIN="$FW/$NAME"
    otool -L "$BIN" | awk 'NR>1 {print $1}' | while read -r dep; do
      local leaf; leaf="$(basename "$dep")"
      local tgt; tgt="$(fw_name "$leaf")"
      # libicuuc.71.dylib (a reference without the minor version) -> the same framework
      [ -z "$tgt" ] && case "$leaf" in libicudata.*) tgt=ICUdata;; libicuuc.*) tgt=ICUuc;; libicui18n.*) tgt=ICUi18n;; esac
      if [ -n "$tgt" ] && [ "$dep" != "@rpath/$tgt.framework/$tgt" ]; then
        install_name_tool -change "$dep" "@rpath/$tgt.framework/$tgt" "$BIN"
      fi
    done
    # rpath for finding sibling frameworks from the framework itself
    install_name_tool -add_rpath "@loader_path/.." "$BIN" 2>/dev/null || true
  done
}

package_slice () {   # $1 = device|simulator
  local LABEL="$1" PLAT="iPhoneOS"; [ "$LABEL" = "simulator" ] && PLAT="iPhoneSimulator"
  local FWDIR="$OUT/frameworks-$LABEL"; rm -rf "$FWDIR"; mkdir -p "$FWDIR"
  for f in "$OUT/$LABEL"/lib/*.dylib "$OUT/$LABEL"/plugins/*.dylib "$OUT/$LABEL"/intl/*.dylib; do
    make_framework "$f" "$FWDIR" "$PLAT"
  done
  relink_frameworks "$FWDIR"
}

package_slice device
[ "${FB_IOS_SIM:-0}" = "1" ] && package_slice simulator

rm -rf "$OUT/xcframeworks"; mkdir -p "$OUT/xcframeworks"
for FW in "$OUT"/frameworks-device/*.framework; do
  NAME="$(basename "$FW" .framework)"
  args=(-framework "$FW")
  [ "${FB_IOS_SIM:-0}" = "1" ] && [ -d "$OUT/frameworks-simulator/$NAME.framework" ] && args+=(-framework "$OUT/frameworks-simulator/$NAME.framework")
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT/xcframeworks/$NAME.xcframework" >/dev/null
  echo "  $NAME.xcframework"
done

# list of Firebird plugin frameworks, read by the Dart side to generate plugins.conf
# FirebirdIbUtil is not a plugin: the engine finds it by name in $FIREBIRD/lib (the plugin creates the symlink)
ls "$OUT"/frameworks-device | sed 's/\.framework$//' | grep -v '^ICU' | grep -v '^Firebird$' | grep -v '^FirebirdIntl$' | grep -v '^FirebirdIbUtil$' > "$OUT/assets/plugin_frameworks.txt"

# ---------------------------------------------------------------------------
log "7. Final check of the frameworks"
for FW in "$OUT"/frameworks-device/*.framework; do
  NAME="$(basename "$FW" .framework)"
  vtool -show-build "$FW/$NAME" | grep -q "platform IOS" || die "$NAME: platform is not IOS"
  if otool -L "$FW/$NAME" | awk 'NR>1{print $1}' | grep -vE '^(@rpath/|/usr/lib/|/System/)' ; then
    die "$NAME: references outside @rpath, /usr/lib, /System remain (see above)"
  fi
done
echo "  all frameworks: platform IOS, dependencies only @rpath / /usr/lib / /System"

cat << EOF

===================================================================
Done.
  xcframeworks:  $OUT/xcframeworks/          -> fb_ios_embedded/ios/Frameworks/
  assets:        $OUT/assets/                -> fb_ios_embedded/assets/fb/
  ICU:           version $(cat "$OUT/assets/icu_version.txt" 2>/dev/null || echo '?')
  (install_into_plugin.sh copies both)

To free disk space (gigabytes of intermediate ICU build):
  rm -rf vcpkg/buildtrees vcpkg/packages
===================================================================
EOF
