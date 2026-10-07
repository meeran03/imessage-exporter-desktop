#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
VERSION="${VERSION:-0.1.0}"
APP="$PROJECT_ROOT/dist/iMessage Exporter.app"
python3 scripts/fetch-engine.py
for ARCH in arm64 x86_64; do
    swift build --disable-sandbox --cache-path .build/cache -c release --arch "$ARCH"
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/MessageArchive .build/x86_64-apple-macosx/release/MessageArchive -output "$APP/Contents/MacOS/MessageArchive"
lipo -create ThirdParty/binaries/imessage-exporter-aarch64-apple-darwin ThirdParty/binaries/imessage-exporter-x86_64-apple-darwin -output "$APP/Contents/Resources/imessage-exporter"
chmod +x "$APP/Contents/MacOS/MessageArchive" "$APP/Contents/Resources/imessage-exporter"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp ThirdParty/NOTICE.md "$APP/Contents/Resources/ThirdParty-Notice.txt"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.meeran.imessageexporter</string>
<key>CFBundleName</key><string>iMessage Exporter</string>
<key>CFBundleDisplayName</key><string>iMessage Exporter</string>
<key>CFBundleExecutable</key><string>MessageArchive</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSContactsUsageDescription</key><string>Show saved contact names next to conversations. Your contacts stay on your Mac.</string>
</dict></plist>
EOF
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/imessage-exporter"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP/Contents/Resources/imessage-exporter"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "dist/iMessage-Exporter-$VERSION-macOS-universal.zip"
printf '%s\n' "Built $APP"
