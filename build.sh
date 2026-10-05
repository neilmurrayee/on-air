#!/bin/bash
# Builds "On Air.app" from Sources/. Needs only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="On Air"
BUNDLE="build/${APP_NAME}.app"
BINARY="OnAir"

# ./build.sh --test   logic tests plus performance budgets (see Tests/main.swift)
# ./build.sh --bench  performance only, longer runs
# Native architecture only, and no app bundle: just the sources and the tests.
if [[ "${1:-}" == "--test" || "${1:-}" == "--bench" ]]; then
    mkdir -p build
    SOURCES=()
    for f in Sources/*.swift; do [[ "$f" == Sources/main.swift ]] || SOURCES+=("$f"); done
    echo "Compiling tests…"
    swiftc -swift-version 5 -O \
        -framework AppKit -framework CoreAudio -framework CoreMediaIO -framework ServiceManagement \
        -o build/OnAirTests "${SOURCES[@]}" Tests/*.swift
    exec build/OnAirTests "$1"
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${BINARY}</string>
    <key>CFBundleIdentifier</key><string>com.local.onair</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Menu bar only: no Dock icon, never steals focus. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Universal: Apple Silicon and Intel. swiftc builds one architecture at a time, so
# build each and stitch them together with lipo.
ARCHS=(arm64 x86_64)
SLICES=()

for arch in "${ARCHS[@]}"; do
    echo "Compiling ${arch}…"
    swiftc \
        -swift-version 5 \
        -O \
        -target "${arch}-apple-macos13.0" \
        -framework AppKit \
        -framework CoreAudio \
        -framework CoreMediaIO \
        -framework ServiceManagement \
        -o "build/${BINARY}-${arch}" \
        Sources/*.swift
    SLICES+=("build/${BINARY}-${arch}")
done

lipo -create -output "$BUNDLE/Contents/MacOS/$BINARY" "${SLICES[@]}"
rm -f "${SLICES[@]}"
echo "Architectures: $(lipo -archs "$BUNDLE/Contents/MacOS/$BINARY")"

# Signing. With a Developer ID in SIGN_IDENTITY the app can be notarised and will
# open cleanly on anyone's Mac; without one we fall back to an ad-hoc signature,
# which is fine locally but trips Gatekeeper on every other machine.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "Signing as ${SIGN_IDENTITY}…"
    codesign --force --deep --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$BUNDLE"
    codesign --verify --strict --verbose=2 "$BUNDLE"
else
    codesign --force --sign - "$BUNDLE" 2>/dev/null || echo "note: ad-hoc signing skipped"
    echo "note: ad-hoc signed. Fine here; other Macs will warn. See README > Sharing."
fi

echo "Built $BUNDLE"

# ./build.sh --install  puts it in /Applications, which is where a login item wants
# to live: a stable path that does not get tidied away like ~/Downloads.
# ./build.sh --zip  produces a zip to hand to someone else. ditto (not the Finder's
# compress, and not `zip`) is what preserves the code signature intact.
if [[ "${1:-}" == "--zip" ]]; then
    ZIP="build/${APP_NAME// /-}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    echo "Wrote $ZIP"
fi

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    pkill -f "${APP_NAME}.app/Contents/MacOS/${BINARY}" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$BUNDLE" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "Installed $DEST"
fi
