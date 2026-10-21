#!/usr/bin/env bash
# Cross-compile usbredirect + opx-usb-shim.so for Android/Termux (bionic).
#
# Builds every target in $TARGET_ARCHES (default: aarch64 armv7a):
#   usbredirect-aarch64, usbredirect-armv7a
#   opx-usb-shim-aarch64.so, opx-usb-shim-armv7a.so
# plus the legacy aarch64 alias opx-usb-shim.so.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/dist"}
NDK=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${NDK:-}}}
API=${ANDROID_API:-24}
HOST_TAG=${NDK_HOST_TAG:-linux-x86_64}
USBREDIR_VER=${USBREDIR_VER:-0.13.0}
LIBUSB_VER=${LIBUSB_VER:-1.0.27}
TARGET_ARCHES=${TARGET_ARCHES:-${TARGET_ARCH:-aarch64 armv7a}}

if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
    echo "ANDROID_NDK_HOME is not set" >&2
    exit 1
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
    echo "NDK toolchain not found: $TOOLCHAIN" >&2
    exit 1
fi

mkdir -p "$OUT" "$ROOT/.build"

build_arch() {
    arch=$1
    case "$arch" in
        aarch64)
            triple=aarch64-linux-android
            config_host=aarch64-linux-android
            ;;
        armv7a)
            triple=armv7a-linux-androideabi
            config_host=arm-linux-androideabi
            ;;
        *)
            echo "unsupported target arch: $arch" >&2
            return 1
            ;;
    esac

    (
        set -euo pipefail
        CC="$TOOLCHAIN/bin/${triple}${API}-clang"
        AR="$TOOLCHAIN/bin/llvm-ar"
        RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
        STRIP_BIN="$TOOLCHAIN/bin/llvm-strip"
        WORK="$ROOT/.build/$arch"
        PREFIX="$WORK/prefix"

        export CC AR RANLIB
        export PATH="$TOOLCHAIN/bin:$PATH"
        export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
        export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR="$PREFIX"

        mkdir -p "$OUT" "$WORK" "$PREFIX"
        cd "$WORK"

        if [ ! -d libusb ]; then
            curl -fsSL -o libusb.tgz "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"
            tar -xjf libusb.tgz
            mv "libusb-${LIBUSB_VER}" libusb
        fi
        if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
            (
                cd libusb
                ./configure --host="$config_host" --disable-udev --disable-shared --enable-static \
                    --prefix="$PREFIX" CFLAGS="-fPIC -O2" LIBS="-llog"
                make -j"$(nproc)"
                make install
            )
        fi

        # usbredir source. The upstream GitHub mirror stopped at 0.7 and
        # gitlab.freedesktop.org serves an anti-bot HTML page to curl, so
        # use the distro orig tarball first and validate every archive.
        try_usbredir_archive() {
            url=$1
            curl -fsSL -o usbredir.tar "$url" || return 1
            tar -tf usbredir.tar >/dev/null 2>&1 || return 1
            rm -rf usbredir
            mkdir -p usbredir
            tar -xf usbredir.tar -C usbredir --strip-components=1 || { rm -rf usbredir; return 1; }
            if find usbredir -name usbredirparser.c | grep -q .; then
                return 0
            fi
            rm -rf usbredir
            return 1
        }

        if [ ! -d usbredir ]; then
            for u in \
                "https://deb.debian.org/debian/pool/main/u/usbredir/usbredir_${USBREDIR_VER}.orig.tar.xz" \
                "https://archive.ubuntu.com/ubuntu/pool/main/u/usbredir/usbredir_${USBREDIR_VER}.orig.tar.xz" \
                "https://github.com/SPICEorg/usbredir/archive/refs/tags/usbredir-${USBREDIR_VER}.tar.gz"
            do
                if try_usbredir_archive "$u"; then
                    echo "usbredir source: $u"
                    break
                fi
            done
        fi
        if [ ! -d usbredir ] && command -v git >/dev/null 2>&1; then
            git clone --depth 1 --branch "usbredir-${USBREDIR_VER}" \
                https://gitlab.freedesktop.org/spice/usbredir.git usbredir \
                || git clone --depth 1 https://gitlab.freedesktop.org/spice/usbredir.git usbredir \
                || true
        fi
        if [ ! -d usbredir ] || ! find usbredir -name usbredirparser.c | grep -q .; then
            echo "could not fetch usbredir ${USBREDIR_VER} sources" >&2
            exit 1
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
#define USBREDIR_VISIBLE __attribute__((visibility("default")))
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
            -o "$OUT/usbredirect-$arch" \
            "$ROOT/host/opx-usbredirect.c" \
            "${SRCS[@]}" \
            "${INCS[@]}" \
            -L"$PREFIX/lib" -lusb-1.0 -llog -lc \
            || {
                echo "link failed; retry with pthread" >&2
                "$CC" -O2 -fPIC -include "$CFG" \
                    -o "$OUT/usbredirect-$arch" \
                    "$ROOT/host/opx-usbredirect.c" "${SRCS[@]}" "${INCS[@]}" \
                    -L"$PREFIX/lib" -lusb-1.0 -llog -lpthread -lc
            }

        "$STRIP_BIN" "$OUT/usbredirect-$arch" || true
        chmod +x "$OUT/usbredirect-$arch"

        "$CC" -shared -fPIC -O2 -o "$OUT/opx-usb-shim-$arch.so" "$ROOT/host/opx-usb-shim.c" -ldl
        "$STRIP_BIN" "$OUT/opx-usb-shim-$arch.so" || true

        if [ "$arch" = aarch64 ]; then
            cp "$OUT/opx-usb-shim-$arch.so" "$OUT/opx-usb-shim.so"
        fi

        file "$OUT/usbredirect-$arch" "$OUT/opx-usb-shim-$arch.so"
        ls -lh "$OUT/usbredirect-$arch" "$OUT/opx-usb-shim-$arch.so"
    )
}

for arch in $TARGET_ARCHES; do
    echo "== building for $arch =="
    build_arch "$arch"
done
