# vcpkg-custom/triplets/fb-arm64-ios-simulator.cmake
#
# Adapted from vcpkg-custom/triplets/fb-arm64-osx.cmake of FirebirdSQL/firebird:
# the same structure, with the system changed to the iOS simulator (Apple Silicon).
#
# Only icu is installed through this triplet (vcpkg classic mode, see
# build_firebird_ios.sh). The libcxx port from vcpkg.json is neither needed
# nor installed for iOS: the iOS SDK libc++ is used (see make.ios.arm64).

set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET "15.0")
set(VCPKG_OSX_SYSROOT iphonesimulator)

if(PORT STREQUAL "icu")
    # Firebird loads ICU with dlopen() at run time, so .dylib files are needed.
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
