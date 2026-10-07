#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
VERSION="${VERSION:-0.2.0}"
APP="$PROJECT_ROOT/dist/iMessage Exporter.app"
python3 scripts/fetch-engine.py
if [[ ! -d ThirdParty/imessage-exporter-4.3.0/vendor ]]; then python3 scripts/vendor-engine.py; fi
bash scripts/build-iphone-tools.sh
bash scripts/build-backup-reader.sh
for ARCH in arm64 x86_64; do
    swift build --disable-sandbox --cache-path .build/cache -c release --arch "$ARCH"
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/MessageArchive .build/x86_64-apple-macosx/release/MessageArchive -output "$APP/Contents/MacOS/MessageArchive"
lipo -create ThirdParty/binaries/imessage-exporter-aarch64-apple-darwin ThirdParty/binaries/imessage-exporter-x86_64-apple-darwin -output "$APP/Contents/Resources/imessage-exporter"
chmod +x "$APP/Contents/MacOS/MessageArchive" "$APP/Contents/Resources/imessage-exporter"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp ThirdParty/NOTICE.md "$APP/Contents/Resources/ThirdParty-Notice.txt"
# Include dependency copyright/license texts with the binary as well as source.
for CRATE in ThirdParty/imessage-exporter-4.3.0/vendor/*; do
    for NOTICE in "$CRATE"/LICENSE* "$CRATE"/COPYING* "$CRATE"/NOTICE*; do
        if [[ -f "$NOTICE" ]]; then
            DEST="$APP/Contents/Resources/Rust-Licenses/$(basename "$CRATE")"
            mkdir -p "$DEST"; cp "$NOTICE" "$DEST/"
        fi
    done
done
mkdir -p "$APP/Contents/Resources/iphone"
ditto ThirdParty/iphone-tools "$APP/Contents/Resources/iphone"
for ARCHIVE in ThirdParty/iphone-source-archives/*; do
    PACKAGE="$(basename "$ARCHIVE")"; PACKAGE="${PACKAGE%.tar.*}"
    mkdir -p "$APP/Contents/Resources/iphone/licenses/$PACKAGE"
    for NOTICE in "$PROJECT_ROOT/.build/iphone-arm64/$PACKAGE"/COPYING* "$PROJECT_ROOT/.build/iphone-arm64/$PACKAGE"/LICENSE*; do
        if [[ -f "$NOTICE" ]]; then cp "$NOTICE" "$APP/Contents/Resources/iphone/licenses/$PACKAGE/"; fi
    done
done
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
    for BINARY in "$APP/Contents/Resources/iphone/bin/"* "$APP/Contents/Resources/iphone/lib/"*.dylib; do
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BINARY"
    done
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/imessage-exporter"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    for BINARY in "$APP/Contents/Resources/iphone/bin/"* "$APP/Contents/Resources/iphone/lib/"*.dylib; do
        codesign --force --sign - "$BINARY"
    done
    codesign --force --sign - "$APP/Contents/Resources/imessage-exporter"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "dist/iMessage-Exporter-$VERSION-macOS-universal.zip"
printf '%s\n' "Built $APP"
