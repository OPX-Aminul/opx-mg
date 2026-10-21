#!/usr/bin/env bash
# Forge the release qcow2 on a desktop/CI Linux box (not on the phone).
# Needs: qemu-img, qemu-system-aarch64, cloud-localds (cloud-image-utils),
#        wget. Output: opx-mg-ubuntu-arm64.qcow2
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/opx-mg-ubuntu-arm64.qcow2"}
WORK=${OPX_MG_BUILD_WORK:-/tmp/opx-mg-image}
IMG_URL=${OPX_MG_CLOUD_URL:-https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img}

mkdir -p "$WORK"
cloud=$WORK/ubuntu-24.04-server-cloudimg-arm64.img
if [ ! -f "$cloud" ]; then
    echo "downloading cloud image"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$cloud" "$IMG_URL"
    else
        curl -fL -o "$cloud" "$IMG_URL"
    fi
fi

echo "converting + resizing"
qemu-img convert -O qcow2 "$cloud" "$OUT"
qemu-img resize "$OUT" 10G

SEED_OUT=$(dirname "$OUT")/seed.iso
if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$WORK/seed.iso" "$ROOT/guest/cloud-init/user-data" "$ROOT/guest/cloud-init/meta-data"
    cp "$WORK/seed.iso" "$SEED_OUT"
    echo "seed ISO at $SEED_OUT"
    echo "Boot once with the seed attached so cloud-init installs firmware:"
    echo "  qemu-system-aarch64 -machine virt -cpu max -m 2048 -nographic \\"
    echo "    -bios /usr/share/AAVMF/AAVMF_CODE.fd \\"
    echo "    -drive file=$OUT,if=virtio \\"
    echo "    -drive file=$WORK/seed.iso,format=raw,if=virtio,readonly=on \\"
    echo "    -netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    echo "Wait for cloud-init, then shut down. Upload $OUT as release asset opx-mg-ubuntu-arm64.qcow2"
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -V CIDATA -J -r -o "$SEED_OUT" \
        "$ROOT/guest/cloud-init/user-data" "$ROOT/guest/cloud-init/meta-data"
    echo "seed ISO at $SEED_OUT"
else
    echo "cloud-localds/xorriso missing — seed ISO not built"
fi
