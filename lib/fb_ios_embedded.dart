/// fb_ios_embedded: setup of the Firebird 5 embedded engine on iOS.
///
/// The iOS counterpart of the Android plugin `fb_5_embedded` (hipercompl),
/// with the same public API (`setUpEmbedded`, `getDefaultFBRoot`,
/// `setFBEnvVars`, `createFBDirs`, `deployFBAssets`), adapted to iOS. The key
/// differences:
///
/// 1. **Libraries are not copied.** On Android the plugin copies both the
///    `.so` files and the data to a private directory, because the engine
///    `dlopen()`s its plugins by path. iOS does not run code copied into the
///    sandbox after installation (code signing), so every `.dylib` stays
///    inside a `*.framework` in the app bundle, signed with the app. Only data
///    is copied: `firebird.msg`, `icudt*.dat` and `security5.fdb` (if present).
///
/// 2. **Configuration is generated on every launch.** On iOS the bundle path
///    contains the container UUID and changes with every update or reinstall,
///    while Firebird finds its plugins by the paths in `plugins.conf` and
///    `intl/fbintl.conf`. So `firebird.conf`, `plugins.conf` and
///    `intl/fbintl.conf` are rewritten on each start with absolute paths to
///    the frameworks.
///
/// 3. **ICU through symlinks and chdir.** On Darwin, Firebird loads ICU by the
///    *relative* path `lib/libicuuc.<maj>.<min>.dylib`
///    (`src/common/unicode_util.cpp`): `dlopen` without a search, relative to
///    the current directory of the process. The plugin creates `$FIREBIRD/lib/`
///    with symlinks to `ICU*.framework/ICU*` in the bundle and does
///    `chdir($FIREBIRD)`. If that ever fails on a device, the fallback is
///    described in the build kit README (a patch to unicode_util.cpp).
///
/// 4. **Data is redeployed when the bundle changes** (an app update or
///    reinstall): the `.deployed_from` marker stores the bundle path.
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show AssetBundle, AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Key prefix of the plugin's assets in the app bundle. Flutter puts a
/// PACKAGE's assets under `packages/<package name>/…`, not under the path from
/// its pubspec.
const String _assetPrefix = 'packages/fb_ios_embedded/assets/fb/';

/// Data files copied into the Firebird root. Everything else in `assets/fb/`
/// (.conf templates, service .txt files) is used for generation and is not
/// put into the root as is.
const Set<String> _dataAssets = <String>{
  'firebird.msg',
  'security5.fdb',
  'databases.conf',
};

/// Frameworks the plugin always expects in the bundle.
const String _fwClient = 'Firebird';
const String _fwEngine = 'FirebirdEngine';
const String _fwIntl = 'FirebirdIntl';
const List<String> _fwIcu = <String>['ICUdata', 'ICUuc', 'ICUi18n'];

/// UDF support: the engine loads `libib_util` on every start
/// (EngineStartup::init → IbUtil::initialize) and looks for it in
/// $FIREBIRD/lib; without it firebird.log gets "ib_util init failed".
/// Optional: builds older than 0.3.0 do not include it.
const String _fwIbUtil = 'FirebirdIbUtil';

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// The `.app` directory of the running app.
String getAppBundleDir() => p.dirname(Platform.resolvedExecutable);

/// The directory of embedded frameworks: `<App>.app/Frameworks`.
String getFrameworksDir() => p.join(getAppBundleDir(), 'Frameworks');

/// Absolute path to the executable of the framework `<name>.framework/<name>`.
String frameworkBinaryPath(String name) =>
    p.join(getFrameworksDir(), '$name.framework', name);

/// Path to `libfbclient`: pass it to fbdb as the client library path
/// (instead of `libfbclient.dylib` / `fbclient.dll`).
String getFbClientPath() => frameworkBinaryPath(_fwClient);

/// The Firebird root directory: `<Documents>/firebird`.
Future<String> getDefaultFBRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  return p.join(docs.path, 'firebird');
}

// ---------------------------------------------------------------------------
// Environment variables (setenv through FFI: Platform.environment is read-only)
// ---------------------------------------------------------------------------

void setFBEnvVars({
  required String firebirdRoot,
  required String firebirdTmp,
  required String firebirdLock,
}) {
  _setenv('FIREBIRD', firebirdRoot);
  _setenv('FIREBIRD_TMP', firebirdTmp);
  _setenv('FIREBIRD_LOCK', firebirdLock);
}

Future<void> createFBDirs({
  required String firebirdRoot,
  required String firebirdTmp,
  required String firebirdLock,
}) async {
  for (final d in <String>[
    firebirdRoot,
    firebirdTmp,
    firebirdLock,
    p.join(firebirdRoot, 'intl'),
    p.join(firebirdRoot, 'lib'),
    p.join(firebirdRoot, 'plugins'),
  ]) {
    await Directory(d).create(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// Assets
// ---------------------------------------------------------------------------

Future<Set<String>> _listFbAssets(AssetBundle b) async {
  // Recent Flutter (3.47) no longer writes AssetManifest.json (only
  // AssetManifest.bin), so the manifest is read through the standard API.
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final paths = manifest
      .listAssets()
      .where((a) => a.startsWith(_assetPrefix))
      .toSet();
  if (paths.isEmpty) {
    throw StateError(
      'No files under $_assetPrefix in the app bundle. Copy ios-out/assets/* '
      'from firebird-ios-build into fb_ios_embedded/assets/fb/ and check pubspec.yaml.',
    );
  }
  return paths;
}

Future<String> _readAssetText(AssetBundle b, String name) async {
  try {
    return (await b.loadString('$_assetPrefix$name')).trim();
  } catch (_) {
    throw StateError('No asset $_assetPrefix$name; build_firebird_ios.sh writes it');
  }
}

/// Copies the data files (`firebird.msg`, `icudt*.dat`, …) into [firebirdRoot].
/// Does not touch the libraries; see the library comment.
Future<void> deployFBAssets({
  required String firebirdRoot,
  AssetBundle? bundle,
}) async {
  final b = bundle ?? rootBundle;
  for (final asset in await _listFbAssets(b)) {
    final name = p.basename(asset);
    final isData = _dataAssets.contains(name) ||
        (name.startsWith('icudt') && name.endsWith('.dat'));
    if (!isData) continue;
    final data = await b.load(asset);
    await File(p.join(firebirdRoot, name)).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Configuration for the current bundle path
// ---------------------------------------------------------------------------

/// Writes `firebird.conf`, `plugins.conf` and `intl/fbintl.conf` with absolute
/// paths to the frameworks and creates the `lib/libicu*.<ver>.dylib` symlinks.
/// Called on every launch.
Future<void> writeFBConfigs({
  required String firebirdRoot,
  required String firebirdTmp,
  AssetBundle? bundle,
}) async {
  final b = bundle ?? rootBundle;
  final fwDir = getFrameworksDir();

  for (final fw in <String>[_fwClient, _fwEngine, _fwIntl, ..._fwIcu]) {
    if (!File(frameworkBinaryPath(fw)).existsSync()) {
      throw StateError(
        'No $fw.framework in the app bundle ($fwDir). Check vendored_frameworks in the podspec '
        'and that the xcframeworks are in fb_ios_embedded/ios/Frameworks/.',
      );
    }
  }

  // ---- firebird.conf: the minimum for embedded use, defaults for the rest
  final fbConf = StringBuffer()
    ..writeln('# Generated by fb_ios_embedded at launch; do not edit.')
    ..writeln('Providers = Engine13')
    ..writeln('TempDirectories = $firebirdTmp')
    ..writeln('# Everything else is default. The engine creates lock files in FIREBIRD_LOCK (env).');
  await File(p.join(firebirdRoot, 'firebird.conf')).writeAsString(fbConf.toString());

  // ---- plugins.conf: an explicit Module for each plugin framework in the bundle
  final pluginFws = (await _readAssetText(b, 'plugin_frameworks.txt'))
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  final plugConf = StringBuffer()
    ..writeln('# Generated by fb_ios_embedded at launch; do not edit.');
  for (final fw in pluginFws) {
    final regName = _pluginRegisterName(fw);
    plugConf
      ..writeln('Plugin = $regName {')
      ..writeln('\tModule = ${frameworkBinaryPath(fw)}')
      ..writeln('}')
      ..writeln();
  }
  await File(p.join(firebirdRoot, 'plugins.conf')).writeAsString(plugConf.toString());

  // ---- intl/fbintl.conf: the asset template, $(this)/fbintl → an absolute path
  final intlTemplate = await _readAssetText(b, 'fbintl.conf');
  final intlConf = intlTemplate.replaceAll(
    RegExp(r'filename\s*=\s*\$\(this\)/fbintl'),
    'filename = ${frameworkBinaryPath(_fwIntl)}',
  );
  await File(p.join(firebirdRoot, 'intl', 'fbintl.conf')).writeAsString('$intlConf\n');

  // ---- lib/libicu*.<maj>.<min>.dylib → ICU*.framework/ICU* (see item 3 above)
  final icuVer = await _readAssetText(b, 'icu_version.txt'); // e.g. "71.1"
  final major = icuVer.split('.').first;
  final libDir = Directory(p.join(firebirdRoot, 'lib'));
  await libDir.create(recursive: true);
  // followLinks: false, or a live link (same bundle, a repeated launch) is
  // listed as a File, is not deleted, and Link.create fails with "File exists".
  // Broken links (after a reinstall) were removed anyway, so the error showed
  // only on an ordinary second launch.
  for (final e in libDir.listSync(followLinks: false)) {
    if (e is Link) await e.delete();
  }
  const names = <String, String>{'ICUdata': 'libicudata', 'ICUuc': 'libicuuc', 'ICUi18n': 'libicui18n'};
  for (final entry in names.entries) {
    final target = frameworkBinaryPath(entry.key);
    for (final suffix in <String>[icuVer, major]) {
      await Link(p.join(libDir.path, '${entry.value}.$suffix.dylib')).create(target);
    }
  }
  // lib/libib_util.dylib → FirebirdIbUtil.framework/FirebirdIbUtil (if embedded).
  final ibUtil = frameworkBinaryPath(_fwIbUtil);
  if (File(ibUtil).existsSync()) {
    await Link(p.join(libDir.path, 'libib_util.dylib')).create(ibUtil);
  }
}

/// The name Firebird registers a plugin under: `FirebirdEngine` → `Engine13`,
/// `FirebirdSrp` → `Srp`, `FirebirdLegacyAuth` → `Legacy_Auth`, …
String _pluginRegisterName(String fw) {
  const map = <String, String>{
    'FirebirdEngine': 'Engine13',
    'FirebirdSrp': 'Srp',
    'FirebirdLegacyAuth': 'Legacy_Auth',
    'FirebirdLegacyUserManager': 'Legacy_UserManager',
    'FirebirdUdrEngine': 'UDR',
    'FirebirdChaCha': 'ChaCha',
  };
  return map[fw] ?? fw.replaceFirst('Firebird', '');
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// The one function to call before the first database access (before
/// `FbDb.attach` / `FbDb.createDatabase` and before libfbclient is loaded).
/// The signature matches `fb_5_embedded.setUpEmbedded`.
Future<void> setUpEmbedded({
  String? firebirdRoot,
  String? firebirdTmp,
  String? firebirdLock,
  AssetBundle? bundle,
  bool forceRedeploy = false,
}) async {
  final root = firebirdRoot ?? await getDefaultFBRoot();
  final tmp = firebirdTmp ?? p.join(root, 'tmp');
  final lock = firebirdLock ?? p.join(root, 'lock');

  await createFBDirs(firebirdRoot: root, firebirdTmp: tmp, firebirdLock: lock);

  // Data: only on the first launch or when the bundle changes (update or reinstall).
  final marker = File(p.join(root, '.deployed_from'));
  final bundleDir = getAppBundleDir();
  final deployedFrom = marker.existsSync() ? marker.readAsStringSync().trim() : null;
  if (forceRedeploy || deployedFrom != bundleDir) {
    await deployFBAssets(firebirdRoot: root, bundle: bundle);
    await marker.writeAsString(bundleDir);
  }

  // Configuration and symlinks: on every launch (the bundle path may have changed).
  await writeFBConfigs(firebirdRoot: root, firebirdTmp: tmp, bundle: bundle);

  setFBEnvVars(firebirdRoot: root, firebirdTmp: tmp, firebirdLock: lock);

  // Firebird loads ICU relative to cwd ("lib/libicuuc.<ver>.dylib").
  Directory.current = root;

  // Preload ICU and the engine by absolute path: a dyld error (signature,
  // platform, @rpath) shows up here with a clear message, rather than as an
  // unclear connection failure inside Firebird.
  for (final fw in <String>[..._fwIcu, _fwEngine, _fwIntl]) {
    ffi.DynamicLibrary.open(frameworkBinaryPath(fw));
  }
}

/// A diagnostic snapshot: paths and which files are present.
Future<Map<String, Object?>> describeSetup({String? firebirdRoot}) async {
  final root = firebirdRoot ?? await getDefaultFBRoot();
  final rootDir = Directory(root);
  final fwDir = Directory(getFrameworksDir());
  return <String, Object?>{
    'bundle': getAppBundleDir(),
    'frameworksDir': fwDir.path,
    'frameworks': fwDir.existsSync()
        ? (fwDir.listSync().map((e) => p.basename(e.path)).toList()..sort())
        : <String>[],
    'FIREBIRD': Platform.environment['FIREBIRD'],
    'FIREBIRD_TMP': Platform.environment['FIREBIRD_TMP'],
    'FIREBIRD_LOCK': Platform.environment['FIREBIRD_LOCK'],
    'cwd': Directory.current.path,
    'root': root,
    'rootFiles': rootDir.existsSync()
        ? (rootDir.listSync(recursive: true).map((e) => p.relative(e.path, from: root)).toList()..sort())
        : <String>[],
    'fbclient': getFbClientPath(),
  };
}

// ---------------------------------------------------------------------------
// setenv(3)
// ---------------------------------------------------------------------------

typedef _SetenvC = ffi.Int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int);
typedef _SetenvDart = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int);

final _SetenvDart _setenvFn =
    ffi.DynamicLibrary.process().lookupFunction<_SetenvC, _SetenvDart>('setenv');

void _setenv(String name, String value) {
  final n = name.toNativeUtf8();
  final v = value.toNativeUtf8();
  try {
    final rc = _setenvFn(n, v, 1);
    if (rc != 0) throw StateError('setenv($name) returned $rc');
  } finally {
    malloc.free(n);
    malloc.free(v);
  }
}
