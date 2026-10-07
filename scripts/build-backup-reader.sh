#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=13.0
if [[ -x "$PROJECT_ROOT/.build/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$PROJECT_ROOT/.build/cargo"
    export RUSTUP_HOME="$PROJECT_ROOT/.build/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
fi
cd "$PROJECT_ROOT/BackupReader"
export CARGO_TARGET_DIR="$PROJECT_ROOT/.build/backup-reader"
if [[ ! -f Cargo.lock ]]; then cargo generate-lockfile --offline; fi
for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --release --locked --offline --target "$TARGET"
done
mkdir -p "$PROJECT_ROOT/ThirdParty/iphone-tools/bin"
lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/backup-reader" "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/backup-reader" -output "$PROJECT_ROOT/ThirdParty/iphone-tools/bin/backup-reader"
codesign --force --sign - "$PROJECT_ROOT/ThirdParty/iphone-tools/bin/backup-reader"
