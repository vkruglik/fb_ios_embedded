#!/usr/bin/env bash
# fetch_firebird_msg.sh — firebird.msg for the iOS build, taken from the
# official Firebird macOS package of the same tag.
#
# The cross phase builds build_file for iOS, so firebird.msg cannot be made on
# the Mac. The file is platform-independent: the one in the official macOS
# arm64 package is byte-identical to a native build. The package is
# downloaded from the GitHub release, its SHA-256 digest is checked against
# the one GitHub publishes, and the file is extracted without installing.
#
# Usage: fetch_firebird_msg.sh <version> <destination file>
#   fetch_firebird_msg.sh 5.0.4 ~/fb/firebird.msg
#
# GITHUB_TOKEN, if set, authenticates the release lookup: anonymous calls to
# the GitHub API from shared CI runners are rate-limited and get HTTP 403.
set -euo pipefail

VERSION="${1:?usage: fetch_firebird_msg.sh <version> <destination file>}"
DEST="${2:?usage: fetch_firebird_msg.sh <version> <destination file>}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

API="https://api.github.com/repos/FirebirdSQL/firebird/releases/tags/v$VERSION"
AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
# ${AUTH[@]+...}: bash 3.2 (macOS) treats an empty array as unbound under set -u.
curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
  -o "$WORK/release.json" "$API" \
  || die "cannot read release v$VERSION from the GitHub API (HTTP 403 means a rate limit: set GITHUB_TOKEN)"
INFO="$(python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
for a in r.get("assets", []):
    if a["name"].endswith("-macos-arm64.pkg"):
        print(a["name"], a["browser_download_url"], a.get("digest") or "-")
        break
' "$WORK/release.json")" || die "cannot parse the release v$VERSION description from GitHub"
[ -n "$INFO" ] || die "release v$VERSION has no *-macos-arm64.pkg asset"
set -- $INFO
NAME="$1" URL="$2" DIGEST="$3"

echo "Downloading $NAME"
curl -fsSL -o "$WORK/$NAME" "$URL"
if [ "$DIGEST" != "-" ]; then
  GOT="sha256:$(shasum -a 256 "$WORK/$NAME" | cut -d' ' -f1)"
  [ "$GOT" = "$DIGEST" ] || die "digest mismatch for $NAME: $GOT != $DIGEST"
  echo "  digest matches GitHub: $DIGEST"
else
  echo "  WARNING: GitHub publishes no digest for this asset; not verified"
fi

pkgutil --expand-full "$WORK/$NAME" "$WORK/expanded"
MSG="$(find "$WORK/expanded" -type f -name firebird.msg -path '*/Resources/*' | head -n1)"
[ -n "$MSG" ] || die "no Resources/firebird.msg in $NAME (package layout changed?)"
mkdir -p "$(dirname "$DEST")"
cp "$MSG" "$DEST"
echo "firebird.msg ($VERSION) -> $DEST"
