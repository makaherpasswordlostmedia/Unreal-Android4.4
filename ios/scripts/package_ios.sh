#!/usr/bin/env bash
# Usage: package_ios.sh <build-dir> [out-dir]  -> UnrealiOS.ipa (unsigned/ldid fake-signed)
set -euo pipefail
B="${1:?build dir}"; OUT="${2:-$B/out}"
R="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$B/UnrealiOS"; [ -f "$BIN" ] || { echo "no $BIN"; exit 1; }
rm -rf "$OUT/Payload"; APP="$OUT/Payload/UnrealiOS.app"; mkdir -p "$APP"
cp "$BIN" "$APP/UnrealiOS"
cp "$R/resources/Info.plist" "$APP/"
find "$R/resources" -maxdepth 1 -name '*.png' -exec cp {} "$APP/" \;
LDID="${LDID:-$(command -v ldid || ls ${THEOS:-/nonexistent}/toolchain/linux/iphone/bin/ldid 2>/dev/null || true)}"
if [ -n "$LDID" ]; then "$LDID" -S"$R/resources/entitlements.plist" "$APP/UnrealiOS"; else echo "warning: ldid not found, binary unsigned"; fi
(cd "$OUT" && rm -f UnrealiOS.ipa && zip -qr UnrealiOS.ipa Payload)
echo "built $OUT/UnrealiOS.ipa"
