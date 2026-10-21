#!/usr/bin/env bash
# Cross-compile usbredirect-aarch64 + opx-usb-shim.so for Android/Termux (bionic).
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/dist"}
NDK=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${NDK:-}}}
API=${ANDROID_API:-24}
HOST_TAG=${NDK_HOST_TAG:-linux-x86_64}
USBREDIR_VER=${USBREDIR_VER:-0.13.0}
LIBUSB_VER=${LIBUSB_VER:-1.0.27}

if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
    echo "ANDROID_NDK_HOME is not set" >&2
    exit 1
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
STRIP_BIN="$TOOLCHAIN/bin/llvm-strip"
export CC AR RANLIB
export PATH="$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$PREFIX"

mkdir -p "$OUT" "$ROOT/.build"
PREFIX="$ROOT/.build/prefix"
WORK="$ROOT/.build"
mkdir -p "$PREFIX"
cd "$WORK"

if [ ! -d libusb ]; then
    curl -fsSL -o libusb.tgz "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"
    tar -xjf libusb.tgz
    mv "libusb-${LIBUSB_VER}" libusb
fi
if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
    (
        cd libusb
        ./configure --host=aarch64-linux-android --disable-udev --disable-shared --enable-static \
            --prefix="$PREFIX" CFLAGS="-fPIC -O2" LIBS="-llog"
        make -j"$(nproc)"
        make install
    )
fi

if [ ! -d usbredir ]; then
    if curl -fsSL -o usbredir.tgz "https://github.com/SPICEorg/usbredir/archive/refs/tags/usbredir-${USBREDIR_VER}.tar.gz"; then
        tar -xzf usbredir.tgz
        mv "usbredir-usbredir-${USBREDIR_VER}" usbredir
    elif curl -fsSL -o usbredir.tgz "https://gitlab.freedesktop.org/spice/usbredir/-/archive/usbredir-${USBREDIR_VER}/usbredir-usbredir-${USBREDIR_VER}.tar.gz"; then
        tar -xzf usbredir.tgz
        mv "usbredir-usbredir-${USBREDIR_VER}" usbredir
    else
        git clone --depth 1 https://github.com/SPICEorg/usbredir.git usbredir
    fi
fi

CFG="$WORK/config.h"
cat > "$CFG" <<EOF
#define PACKAGE_VERSION "${USBREDIR_VER}"
#define VERSION "${USBREDIR_VER}"
#define PACKAGE_STRING "usbredir ${USBREDIR_VER}"
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STDINT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_INTTYPES_H 1
EOF

PARSER=$(find usbredir -name usbredirparser.c | head -n 1)
HOSTC=$(find usbredir -name usbredirhost.c | head -n 1)
FILTER=$(find usbredir -name usbredirfilter.c | head -n 1)
[ -n "$PARSER" ] && [ -n "$HOSTC" ] || { echo "usbredir sources missing"; exit 1; }

INCS=(-I"$WORK" -I"$PREFIX/include" -I"$PREFIX/include/libusb-1.0")
while IFS= read -r d; do
    INCS+=(-I"$d")
done < <(find usbredir -type d \( -name usbredirparser -o -name usbredirhost -o -name usbredirfilter -o -name src -o -name include \) | sort)

SRCS=("$PARSER" "$HOSTC")
[ -n "$FILTER" ] && SRCS+=("$FILTER")

"$CC" -O2 -fPIC \
    -include "$CFG" \
    -o "$OUT/usbredirect-aarch64" \
    "$ROOT/host/opx-usbredirect.c" \
    "${SRCS[@]}" \
    "${INCS[@]}" \
    -L"$PREFIX/lib" -lusb-1.0 -llog -lc \
    || {
        echo "link failed; retry with pthread" >&2
        "$CC" -O2 -fPIC -include "$CFG" \
            -o "$OUT/usbredirect-aarch64" \
            "$ROOT/host/opx-usbredirect.c" "${SRCS[@]}" "${INCS[@]}" \
            -L"$PREFIX/lib" -lusb-1.0 -llog -lpthread -lc
    }

"$STRIP_BIN" "$OUT/usbredirect-aarch64" || true
chmod +x "$OUT/usbredirect-aarch64"

"$CC" -shared -fPIC -O2 -o "$OUT/opx-usb-shim.so" "$ROOT/host/opx-usb-shim.c" -ldl
"$STRIP_BIN" "$OUT/opx-usb-shim.so" || true

file "$OUT/usbredirect-aarch64" "$OUT/opx-usb-shim.so"
ls -lh "$OUT/usbredirect-aarch64" "$OUT/opx-usb-shim.so"
