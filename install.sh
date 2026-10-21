#!/usr/bin/env sh
# One-shot installer. Run inside Termux:
#   curl -fsSL https://raw.githubusercontent.com/OPX-Aminul/opx-mg/main/install.sh | sh
set -eu

REPO="${OPX_MG_REPO:-OPX-Aminul/opx-mg}"
BRANCH="${OPX_MG_BRANCH:-main}"
PREFIX="${PREFIX:-}"

if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
    echo "This installer is meant to run inside Termux (\$PREFIX is unset)." >&2
    echo "Clone instead: git clone https://github.com/${REPO}.git && ./bin/opx-mg setup" >&2
    exit 1
fi

DEST="${PREFIX}/lib/opx-mg"
BIN="${PREFIX}/bin/opx-mg"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"

echo "opx-mg: installing into $DEST"
mkdir -p "$DEST" "${PREFIX}/bin"
TMP="${PREFIX}/tmp/opx-mg-install"
mkdir -p "$TMP"
archive="$TMP/src.tar.gz"
if command -v curl >/dev/null 2>&1; then
    curl -fL -o "$archive" "$TARBALL"
else
    wget -O "$archive" "$TARBALL"
fi
tar -xzf "$archive" -C "$TMP"
src=$(find "$TMP" -maxdepth 1 -type d -name 'opx-mg-*' | head -n 1)
if [ -z "$src" ]; then
    echo "unpack failed" >&2
    exit 1
fi
# copy tree
cp -R "$src/." "$DEST/"
chmod +x "$DEST/bin/opx-mg" "$DEST/install.sh"
ln -sf "$DEST/bin/opx-mg" "$BIN"
echo "opx-mg: linked $BIN"
echo "opx-mg: running setup"
"$BIN" setup || true
echo
echo "Next:"
echo "  pkg install termux-api qemu-system-aarch64-headless qemu-utils xorriso python"
echo "  # install the Termux:API APK from the same source as Termux"
echo "  opx-mg"
echo "Then plug a USB Wi-Fi adapter and tap OK."
