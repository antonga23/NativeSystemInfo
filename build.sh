#!/bin/bash
# Build NativeSystemInfo.app. Command Line Tools only - no Xcode project needed.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/System Information.app"
BIN="NativeSystemInfo"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling..."
swiftc -O \
    -framework AppKit -framework SwiftUI -framework CoreGraphics \
    -o "$APP/Contents/MacOS/$BIN" \
    Sources/main.swift \
    Sources/Log.swift \
    Sources/SystemData.swift \
    Sources/SPReport.swift \
    Sources/Coverage.swift \
    Sources/Interceptor.swift \
    Sources/ReplacementWindow.swift \
    Sources/RootView.swift

cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so the designated requirement does not change between
# builds. TCC grants (Accessibility, needed for Device Management detection) are bound to
# the signature - an ad-hoc signature changes every build and the grant is silently lost.
IDENTITY="NativeSystemInfo Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --options runtime --timestamp=none \
             --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    echo "WARNING: '$IDENTITY' not found, falling back to ad-hoc (TCC grants will not persist)"
    echo "         see README 'Code signing' to recreate it"
    codesign --force --sign - "$APP"
fi

codesign --verify --strict --verbose=1 "$APP"

echo "built: $APP"
