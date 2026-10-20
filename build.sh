#!/bin/zsh
# Builds build/TouchDriver.app (universal: Apple silicon + Intel) and runs the mapping self-test.
set -euo pipefail
cd "${0:A:h}"

APP=build/TouchDriver.app
BIN=$APP/Contents/MacOS/TouchDriver
SOURCES=(Sources/*.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    -o "build/obj/TouchDriver-$arch" "${SOURCES[@]}"
done
lipo -create build/obj/TouchDriver-arm64 build/obj/TouchDriver-x86_64 -output "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Signing. Set SIGN_IDENTITY to a "Developer ID Application" certificate name or
# SHA-1 hash to sign for distribution (hardened runtime + secure timestamp);
# without it the app is signed ad-hoc. macOS ties Input Monitoring / Accessibility
# grants to the signature, so an ad-hoc rebuild may need re-enabling in Privacy & Security.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

"$BIN" --selftest
echo "Built $APP"
