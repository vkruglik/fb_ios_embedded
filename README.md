# fb_ios_embedded

The embedded Firebird 5 database engine for Flutter apps on iOS. The engine
runs inside your app process, with no server and no network: a database is
a file in the app container.

The package is the iOS counterpart of
[`fb_5_embedded`](https://github.com/hipercompl/fb_5_embedded) for Android
and is meant to be used with the [`fbdb`](https://pub.dev/packages/fbdb)
driver.

- Firebird **5.0.4** and ICU **71.1**, as signed `.xcframework`s for
  `arm64` devices, with a minimum of iOS 15.0.
- The `UNICODE` / `UNICODE_CI` collations work (ICU is included).
- No native code of its own: a Dart library (`dart:ffi`) plus a podspec that
  embeds the frameworks.

**Verified on** iPhone 17 Pro Max, iOS 27.2.1, Xcode 27.2, Flutter 3.47.8,
fbdb 1.8.1. The checks were: fresh install, database creation, reads and
writes, `UNICODE_CI` on Cyrillic text, restarting the app, reinstalling
over the old version (new bundle and container paths), deleting and
reinstalling, airplane mode, 2.5 minutes in the background with an open
connection, and a release build launched without the cable.

The iOS simulator is not supported by the prebuilt binaries: they contain
the device slice only. See [Building the binaries](#building-the-binaries)
for a simulator slice.

## Installation

```yaml
dependencies:
  fb_ios_embedded: ^0.3.0
  fbdb: ^1.8.1
```

Your app's `ios/Podfile` must state the platform explicitly, and the Xcode
project must use a numeric deployment target:

```ruby
platform :ios, '15.0'
```

CocoaPods 1.17 cannot parse `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)`,
which recent Xcode templates put into `IPHONEOS_DEPLOYMENT_TARGET`. Set it
to `15.0` (or higher) in the Runner target.

## Usage

Call `setUpEmbedded()` once, before the first database call, and pass the
client library path to `fbdb`:

```dart
import 'dart:io';

import 'package:fb_ios_embedded/fb_ios_embedded.dart' as fb_embedded;
import 'package:fbdb/fbdb.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<FbDb> openDatabase() async {
  await fb_embedded.setUpEmbedded();

  final docs = await getApplicationDocumentsDirectory();
  final options = FbOptions(libFbClient: fb_embedded.getFbClientPath());
  final path = p.join(docs.path, 'app.fdb');

  return File(path).existsSync()
      ? FbDb.attach(database: path, user: 'SYSDBA', options: options)
      : FbDb.createDatabase(database: path, user: 'SYSDBA', options: options);
}
```

Do not pass a host, port or password: embedded connections do not use them.

`describeSetup()` returns a diagnostic snapshot: the bundle path, the
embedded frameworks, the contents of the Firebird root directory and the
client library path. The [example](example/) app shows it with its "Paths"
button.

## How it works

iOS differs from Android in ways that shape the whole package.

| | Android (`fb_5_embedded`) | iOS (this package) |
|---|---|---|
| Engine libraries | copied from assets to a private directory and loaded from there | **stay in the app bundle** (`<App>.app/Frameworks/*.framework`) and are signed with the app; iOS does not run code that appears after installation |
| Data (`firebird.msg`, `security5.fdb`) | copied once | copied on first launch and again **whenever the bundle path changes** (update or reinstall); the `.deployed_from` marker stores the path |
| Configuration | taken from assets as is | **generated on every launch**: `firebird.conf`, `plugins.conf` with absolute `Module = …/FirebirdEngine.framework/FirebirdEngine`, and `intl/fbintl.conf` |
| ICU | loaded by name | Firebird on Darwin loads `lib/libicuuc.<maj>.<min>.dylib` **relative to the working directory**, so the package creates symlinks in `$FIREBIRD/lib/` to the `ICU*.framework` binaries and changes the working directory to `$FIREBIRD` |
| Client library for fbdb | `libfbclient.so` by name | **`getFbClientPath()`** → `…/Frameworks/Firebird.framework/Firebird`, passed to fbdb explicitly |

Each library is a separate framework: App Store Connect rejects loose
`.dylib` files and nested frameworks. The Firebird root is
`<Documents>/firebird`, with `tmp/` and `lock/` inside;
`FIREBIRD`, `FIREBIRD_TMP` and `FIREBIRD_LOCK` are set with `setenv(3)`.

`setUpEmbedded()` preloads ICU, the engine and the character sets by
absolute path with `DynamicLibrary.open`. A signing, platform or `@rpath`
problem therefore fails right there with the dyld message, rather than later
as an unclear connection error inside Firebird.

## Troubleshooting

`dyld` errors appear only in the device console: Xcode → Devices and
Simulators → Open Console, filtered by your process.

| Symptom | Cause |
|---|---|
| `DynamicLibrary.open` fails with `code signature invalid` / `not valid for use in process` | a framework was not signed when embedded; check that the pod frameworks are embedded and signed |
| `Library not loaded: @rpath/ICUdata.framework/ICUdata` | an inter-library reference was not rewritten; check the binary with `otool -L` |
| `incompatible platform` / `built for macOS` | a wrong slice; check with `vtool -show-build` |
| the engine works but `UNICODE_CI` does not; `failed to load UC icu module` in the console | ICU could not be loaded through the working directory and the symlinks; see the ICU section of the build README |
| an error about `Srp` / `AuthServer` on attach | an authentication plugin is missing; check `FirebirdSrp.xcframework` and `assets/fb/plugin_frameworks.txt` |
| an I/O error on a lock file | `FIREBIRD_LOCK` / `FIREBIRD_TMP` point outside the sandbox; check `describeSetup()` |
| after adding or removing frameworks the app does not see them | `vendored_frameworks` is a glob expanded at `pod install`; run `pod install` again |
| `describeSetup()` shows `FIREBIRD*` as `null` | expected: Dart caches `Platform.environment` on first access, before `setenv`; the engine does get the variables |

## Size

The device slice is about 50 MB uncompressed: the engine, the plugins and
ICU with its full data. If the app size matters, build ICU with a reduced
data set (`ICU_DATA_FILTER_FILE`); that is not done here.

## Building the binaries

The binaries in this package are built by the script in
[`firebird-ios-build/`](firebird-ios-build/README.md) of the repository,
from the unmodified Firebird `v5.0.4` sources plus three small patches. The
same script builds the simulator slice (`FB_IOS_SIM=1`) and other `5.0.x`
tags.

## License

The package's own code is MIT-licensed (see [`LICENSE`](LICENSE)). The
bundled Firebird and ICU binaries remain under their own licenses
(InterBase Public License 1.0, Initial Developer's Public License 1.0,
Unicode License and others): see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
[`licenses/`](licenses/).

Firebird is a registered trademark of the Firebird Foundation. This project
is not affiliated with or endorsed by the Firebird Project.
