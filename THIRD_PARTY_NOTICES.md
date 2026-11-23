# Third-party notices

The MIT license in [`LICENSE`](LICENSE) covers only the original code of this
project: the Dart library, the podspec, the build scripts and the example
app. The native binaries in `ios/Frameworks/` and the data files in
`assets/fb/` are built from third-party sources and stay under their own
licenses. The full texts are in [`licenses/`](licenses/).

## Firebird

Firebird® 5.0.4 — the client library (`Firebird.framework`), the engine
(`FirebirdEngine`), the international character sets (`FirebirdIntl`),
`FirebirdIbUtil` and the plugins (`FirebirdSrp`, `FirebirdChaCha`,
`FirebirdLegacyAuth`, `FirebirdLegacyUserManager`, `FirebirdUdrEngine`),
plus `firebird.msg` and the configuration templates.

- InterBase Public License 1.0 — [`licenses/Firebird-IPL-1.0.txt`](licenses/Firebird-IPL-1.0.txt)
- Initial Developer's Public License 1.0 — [`licenses/Firebird-IDPL-1.0.txt`](licenses/Firebird-IDPL-1.0.txt)

Each Firebird source file states which of the two applies. Source code:
<https://github.com/FirebirdSQL/firebird>, tag `v5.0.4`.

**Modifications.** The binaries are built from the unmodified `v5.0.4`
sources plus the patches in `firebird-ios-build/patches/` of this project's
repository. The patches change these Firebird files and are distributed
under the license of the file they change:

| Patch | Files | Purpose |
|---|---|---|
| `0001-mac_utils-ios.patch` | `src/common/os/darwin/mac_utils.m` | macOS-only `SecTask` API is absent on iOS; an iOS process is always sandboxed |
| `0002-ios-no-system.patch` | `src/yvalve/utl.cpp`, `src/jrd/replication/Utils.cpp`, `src/isql/isql.epp` | `system()` is unavailable on iOS; the affected commands fail instead |
| `0003-alloc-traits-libcxx.patch` | `src/common/classes/alloc.h` | `std::allocator_traits` members required by the libc++ of Xcode 27 |

## Libraries built into the Firebird binaries

| Component | Where it ends up | License | Text |
|---|---|---|---|
| ICU 71.1 | `ICUdata`, `ICUuc`, `ICUi18n` | Unicode License (ICU) | [`licenses/ICU-71.1.txt`](licenses/ICU-71.1.txt) |
| RE2 | engine | BSD 3-Clause | [`licenses/re2-BSD-3-Clause.txt`](licenses/re2-BSD-3-Clause.txt) |
| libcds | engine | Boost Software License 1.0 | [`licenses/libcds-and-Boost-BSL-1.0.txt`](licenses/libcds-and-Boost-BSL-1.0.txt) |
| Boost.Preprocessor (headers) | client and engine | Boost Software License 1.0 | [`licenses/libcds-and-Boost-BSL-1.0.txt`](licenses/libcds-and-Boost-BSL-1.0.txt) |
| decNumber | client and engine | ICU License | [`licenses/decNumber-ICU-License.txt`](licenses/decNumber-ICU-License.txt) |
| Abseil `int128` | client and engine | Apache License 2.0 | [`licenses/abseil-int128-Apache-2.0.txt`](licenses/abseil-int128-Apache-2.0.txt) |
| TTMath (headers) | client and engine | BSD 3-Clause | [`licenses/ttmath-BSD-3-Clause.txt`](licenses/ttmath-BSD-3-Clause.txt) |
| LibTomMath | client, engine, plugins | public domain | [`licenses/libtommath-public-domain.txt`](licenses/libtommath-public-domain.txt) |
| LibTomCrypt | client, engine, plugins | public domain or WTFPL | [`licenses/libtomcrypt-public-domain-or-WTFPL.txt`](licenses/libtomcrypt-public-domain-or-WTFPL.txt) |

The C++ standard library is the system libc++ of iOS; nothing from it is
bundled.

## Build tooling

`firebird-ios-build/vcpkg-overlay-ports/icu` is the vcpkg port of ICU 71.1
(vcpkg git tree `13fe0c90`) with changes for iOS. vcpkg is MIT-licensed:
`firebird-ios-build/vcpkg-overlay-ports/LICENSE.vcpkg.txt`. The build tooling
is not part of the published package.

Firebird is a registered trademark of the Firebird Foundation. This project
is not affiliated with or endorsed by the Firebird Project.
