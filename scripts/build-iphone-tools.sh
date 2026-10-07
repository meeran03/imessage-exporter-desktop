#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
python3 scripts/fetch-iphone-sources.py
JOBS="${BUILD_JOBS:-8}"
for ARCH in arm64 x86_64; do
    PREFIX="$PROJECT_ROOT/.build/iphone-$ARCH/prefix"
    mkdir -p "$PREFIX" "$PROJECT_ROOT/.build/iphone-$ARCH"
    export MACOSX_DEPLOYMENT_TARGET=13.0
    export CC="clang -arch $ARCH"
    export CXX="clang++ -arch $ARCH"
    export CFLAGS="-O2 -mmacosx-version-min=13.0"
    export CXXFLAGS="$CFLAGS"
    export CPPFLAGS="-I$PREFIX/include"
    export LDFLAGS="-L$PREFIX/lib -mmacosx-version-min=13.0"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    export libcurl_CFLAGS="-I$(xcrun --show-sdk-path)/usr/include"
    export libcurl_LIBS="-lcurl"
    while IFS= read -r ARCHIVE; do
        NAME="$(basename "$ARCHIVE")"
        PACKAGE="${NAME%.tar.*}"
        SOURCE="$PROJECT_ROOT/.build/iphone-$ARCH/$PACKAGE"
        if [[ -f "$SOURCE/.built" ]]; then continue; fi
        mkdir -p "$SOURCE"
        tar -xf "$ARCHIVE" -C "$SOURCE" --strip-components=1
        printf '%s\n' "Building $PACKAGE for ${ARCH}..."
        (
            cd "$SOURCE"
            if [[ "$PACKAGE" == openssl-* ]]; then
                TARGET=darwin64-arm64-cc
                if [[ "$ARCH" == x86_64 ]]; then TARGET=darwin64-x86_64-cc; fi
                perl Configure "$TARGET" shared no-tests no-apps --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=13.0 || exit $?
                make -j "$JOBS" || exit $?
                make install_sw || exit $?
            else
                HOST=aarch64-apple-darwin
                if [[ "$ARCH" == x86_64 ]]; then HOST=x86_64-apple-darwin; fi
                ./configure --prefix="$PREFIX" --host="$HOST" --disable-static --enable-shared --without-cython --without-python || exit $?
                make -j "$JOBS" || exit $?
                make install || exit $?
            fi
            touch .built
        ) > "$SOURCE/build.log" 2>&1 || { tail -50 "$SOURCE/build.log"; exit 1; }
    done < <(python3 - <<'PY'
import json
from pathlib import Path
for item in json.loads(Path('ThirdParty/iphone-sources.json').read_text()):
    print(str(Path.cwd()/'ThirdParty/iphone-source-archives'/item['url'].rsplit('/',1)[1]))
PY
    )
done
python3 scripts/package-iphone-tools.py
