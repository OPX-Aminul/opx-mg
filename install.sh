#!/usr/bin/env sh
# One-shot installer. Run inside Termux:
#   curl -fsSL https://raw.githubusercontent.com/OPX-Aminul/opx-mg/main/install.sh | sh
set -eu

REPO="${OPX_MG_REPO:-OPX-Aminul/opx-mg}"
BRANCH="${OPX_MG_BRANCH:-main}"
PREFIX="${PREFIX:-}"
API="https://api.github.com/repos/${REPO}/releases/latest"

if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
    echo "This installer is meant to run inside Termux (\$PREFIX is unset)." >&2
    echo "Clone instead: git clone https://github.com/${REPO}.git && ./bin/opx-mg setup" >&2
    exit 1
fi

DEST="${PREFIX}/lib/opx-mg"
BIN="${PREFIX}/bin/opx-mg"
TMP="${PREFIX}/tmp/opx-mg-install"
mkdir -p "$DEST" "${PREFIX}/bin" "$TMP"

detect_arch() {
    case "$(uname -m 2>/dev/null || echo unknown)" in
        aarch64|arm64)                   printf '%s' aarch64 ;;
        armv7l|armv8l|armv7a|armv8a|arm) printf '%s' armv7a ;;
        x86_64|amd64)                    printf '%s' x86_64 ;;
        i?86)                            printf '%s' i686 ;;
        *)                               printf '%s' unknown ;;
    esac
}

ARCH=$(detect_arch)
case "$ARCH" in
    aarch64|armv7a) ;;
    *) echo "opx-mg: warning: unsupported host arch '$ARCH' (releases ship aarch64 and armv7a)" >&2 ;;
esac

download() {
    url=$1 dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$dest" "$url"
    else
        wget -O "$dest" "$url"
    fi
}

echo "opx-mg: installing into $DEST (host arch $ARCH)"

installed=0
if download "$API" "$TMP/latest.json"; then
    tag=""
    if command -v python3 >/dev/null 2>&1; then
        tag=$(python3 - "$TMP/latest.json" <<'PY'
import json,sys
print((json.load(open(sys.argv[1])).get("tag_name") or "").lstrip("v"))
PY
)
    fi
    if [ -n "$tag" ]; then
        echo "opx-mg: latest release v${tag}"
        tarball_url=""
        if command -v python3 >/dev/null 2>&1; then
            tarball_url=$(python3 - "$TMP/latest.json" "opx-mg-${tag}.tar.gz" <<'PY'
import json,sys
name=sys.argv[2]
d=json.load(open(sys.argv[1]))
for a in d.get("assets") or []:
    if a.get("name")==name:
        print(a.get("browser_download_url") or "")
        sys.exit(0)
sys.exit(1)
PY
) || true
        fi
        if [ -n "$tarball_url" ]; then
            archive="$TMP/opx-mg-${tag}.tar.gz"
            download "$tarball_url" "$archive"
            tar -xzf "$archive" -C "$DEST"
            installed=1
        fi
    fi
fi

if [ "$installed" -ne 1 ]; then
    echo "opx-mg: no release tarball yet, cloning ${BRANCH}"
    TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"
    archive="$TMP/src.tar.gz"
    download "$TARBALL" "$archive"
    tar -xzf "$archive" -C "$TMP"
    src=$(find "$TMP" -maxdepth 1 -type d -name 'opx-mg-*' | head -n 1)
    if [ -z "$src" ]; then
        echo "unpack failed" >&2
        exit 1
    fi
    cp -R "$src/." "$DEST/"
fi

chmod +x "$DEST/bin/opx-mg" "$DEST/install.sh" 2>/dev/null || true
ln -sf "$DEST/bin/opx-mg" "$BIN"
echo "opx-mg: linked $BIN"
echo "opx-mg: running setup (pulls usbredirect + guest disk from Releases)"
"$BIN" setup || true
echo
echo "Next (host arch: $ARCH):"
if [ "$ARCH" = armv7a ]; then
    echo "  pkg install termux-api xorriso python curl git"
    echo "  # 32-bit Termux has no QEMU package: set OPX_QEMU_BIN if you have a build"
else
    echo "  pkg install termux-api qemu-system-aarch64-headless qemu-utils xorriso python curl git"
fi
echo "  # install the Termux:API APK from the same source as Termux"
echo "  opx-mg"
echo "Update later: opx-mg -u"
