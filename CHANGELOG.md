## 0.3.0

First public release. Firebird 5.0.4, ICU 71.1, iOS 15.0 or later, device
slice only. Verified on a device with Xcode 27.2 and Flutter 3.47.8.

Fixes found while testing on a device:

- The asset list is read with `AssetManifest.loadFromAssetBundle`: Flutter
  3.47 no longer writes `AssetManifest.json`.
- Package assets are looked up under `packages/fb_ios_embedded/assets/fb/`.
- `describeSetup()` compiles (a cascade inside `?:` needed parentheses).
- Restarting the same bundle no longer fails with "File exists": stale ICU
  symlinks are listed with `followLinks: false` and removed.
- `FirebirdIbUtil.framework` and the `lib/libib_util.dylib` symlink: the
  engine loads `ib_util` on every start.
- The minimum iOS version is 15.0, as required by Flutter 3.47.

## 0.2.0

Unpublished. One framework per library; configuration generated on every
launch; data redeployed when the bundle path changes.
