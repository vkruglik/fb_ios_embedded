# Releasing

The binaries are never committed to git. A release goes like this:

1. Update `version` in `pubspec.yaml` and `s.version` in
   `ios/fb_ios_embedded.podspec`, add a `CHANGELOG.md` entry, commit, tag
   `v<version>` and push the tag.
2. The **Build Firebird for iOS** workflow builds the binaries from source
   and attaches `fb_ios_embedded-binaries-v<version>.zip` (with its
   `.sha256`) to the GitHub release.
3. On a Mac, in a clean clone of this repository at the tag:

   ```bash
   curl -fLO https://github.com/vkruglik/fb_ios_embedded/releases/download/v<version>/fb_ios_embedded-binaries-v<version>.zip
   curl -fLO https://github.com/vkruglik/fb_ios_embedded/releases/download/v<version>/fb_ios_embedded-binaries-v<version>.zip.sha256
   shasum -a 256 -c fb_ios_embedded-binaries-v<version>.zip.sha256
   firebird-ios-build/install_into_plugin.sh fb_ios_embedded-binaries-v<version>.zip .
   ```

4. Run the example on a device: `cd example && flutter run -d <device>`,
   then Paths → Deploy → Create database → Write/read → Collation.
5. `dart pub publish --dry-run`, then `dart pub publish`. `.pubignore` lets
   the binaries into the package while `.gitignore` keeps them out of git.
