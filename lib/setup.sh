# shellcheck shell=sh
# First-run installer: Termux packages, release assets, seed ISO, PATH.

opx_check_termux_api() {
    if ! command -v termux-usb >/dev/null 2>&1; then
        warn "termux-usb missing"
        cat >&2 <<'EOF'
Install Termux:API from the SAME source as Termux (F-Droid or GitHub, not Play):

  pkg install termux-api

Then install the Termux:API Android app APK from that same source.
EOF
        return 1
    fi
    # A hanging or crashing termux-usb -l usually means the APK is missing
    # or signed by a different key than the Termux app.
    if ! opx_termux_usb -l >/dev/null 2>&1; then
        warn "termux-usb -l failed — is the Termux:API APK installed and same-source?"
        return 1
    fi
    return 0
}

opx_termux_pkg_install() {
    command -v pkg >/dev/null 2>&1 || return 1
    opx_run pkg install -y "$@"
}

opx_install_qemu() {
    # Auto-install QEMU inside Termux unless OPX_NO_INSTALL=1.
    [ "${OPX_NO_INSTALL:-0}" = "1" ] && return 1
    opx_is_termux || return 1
    if [ "$OPX_HOST_ARCH" = armv7a ]; then
        # termux-main's "arm" repo ships no qemu-* at all, and TUR only has
        # qemu-system-i386 / qemu-system-x86-64. There is nothing to install,
        # so say so instead of running pkg for a package that cannot exist.
        return 1
    fi
    opx_termux_pkg_install qemu-system-aarch64-headless qemu-utils || return 1
    command -v "$OPX_QEMU_BIN" >/dev/null 2>&1
}

opx_check_qemu() {
    if command -v "$OPX_QEMU_BIN" >/dev/null 2>&1; then
        return 0
    fi
    if opx_install_qemu; then
        info "QEMU ready: $(command -v "$OPX_QEMU_BIN")"
        return 0
    fi
    warn "$OPX_QEMU_BIN missing"
    if [ "$OPX_HOST_ARCH" = armv7a ]; then
        cat >&2 <<'EOF'
32-bit Termux cannot install QEMU: termux-main's "arm" repo has no qemu
package (only aarch64 does) and TUR only ships x86 QEMU.

Most 32-bit Termux installs sit on a 64-bit phone. Check the hardware ABI:

  getprop ro.product.cpu.abi      # arm64-v8a means install 64-bit Termux

If it says arm64-v8a, install Termux (aarch64) from F-Droid or GitHub and
re-run the installer; setup then picks the aarch64 assets and QEMU.

If the phone really is 32-bit, point OPX_QEMU_BIN at your own 32-bit
qemu-system-aarch64 build; nothing else is needed.
EOF
        return 1
    fi
    cat >&2 <<'EOF'
On Termux:

  pkg install qemu-system-aarch64-headless qemu-utils

The package must include usb-redir (Termux QEMU does).
EOF
    return 1
}

opx_find_edk2() {
    for p in \
        "${PREFIX:-/usr}/share/qemu/edk2-aarch64-code.fd" \
        /usr/share/qemu/edk2-aarch64-code.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd
    do
        if [ -f "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

opx_build_seed() {
    seed=$OPX_IMAGES/seed.iso
    ud=$OPX_STATE/user-data
    md=$OPX_STATE/meta-data
    mkdir -p "$OPX_STATE"
    cp "$OPX_ROOT/guest/cloud-init/user-data" "$ud"
    cp "$OPX_ROOT/guest/cloud-init/meta-data" "$md"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -V CIDATA -J -r -o "$seed" "$ud" "$md" >/dev/null 2>&1 \
            || die "xorriso failed to build seed.iso"
        info "seed ISO -> $seed"
        return
    fi
    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$seed" -volid cidata -joliet -rock "$ud" "$md" >/dev/null 2>&1 \
            || die "genisoimage failed"
        info "seed ISO -> $seed"
        return
    fi
    warn "no xorriso/genisoimage — writing a stub seed; cloud-init may not inject the password"
    # Minimal ISO-9660 is too painful in shell; QEMU will still boot, login
    # then depends on the prebaked image having a password already.
    : > "$seed"
}

opx_fetch_asset() {
    _asset_name=$1 _asset_dest=$2 _asset_force=${3:-0}
    if [ -f "$_asset_dest" ] && [ "$_asset_force" != "1" ]; then
        info "already have $_asset_name"
        return 0
    fi
    _asset_url=$(opx_github_asset_url "$_asset_name" 2>/dev/null || true)
    if [ -z "$_asset_url" ]; then
        warn "release asset $_asset_name not published yet"
        return 1
    fi
    info "downloading $_asset_name"
    opx_download "$_asset_url" "$_asset_dest"
}

opx_fetch_asset_any() {
    # opx_fetch_asset_any DEST BASE [FORCE] — arch-specific names, then aliases
    _any_dest=$1 _any_base=$2 _any_force=${3:-0}
    for _any_name in $(opx_asset_candidates "$_any_base"); do
        if opx_fetch_asset "$_any_name" "$_any_dest" "$_any_force"; then
            return 0
        fi
    done
    return 1
}

opx_installed_arch() {
    cat "$OPX_BIN/arch" 2>/dev/null || true
}

opx_install_usbredirect() {
    _ur_dest=$OPX_BIN/usbredirect
    _ur_have=$(opx_installed_arch)
    if [ -x "$_ur_dest" ] && [ "$_ur_have" = "$OPX_HOST_ARCH" ]; then
        return 0
    fi
    if [ -x "$OPX_ROOT/host/usbredirect" ]; then
        cp "$OPX_ROOT/host/usbredirect" "$_ur_dest"
        chmod +x "$_ur_dest"
        printf '%s\n' "$OPX_HOST_ARCH" > "$OPX_BIN/arch"
        return 0
    fi
    # Arch changed or unknown: force a fresh download.
    opx_fetch_asset_any "$OPX_BIN/opx-usb-shim.so" shim 1 || true
    if opx_fetch_asset_any "$_ur_dest" usbredirect 1; then
        chmod +x "$_ur_dest"
        printf '%s\n' "$OPX_HOST_ARCH" > "$OPX_BIN/arch"
        return 0
    fi
    if command -v usbredirect >/dev/null 2>&1; then
        ln -sf "$(command -v usbredirect)" "$_ur_dest"
        printf '%s\n' "$OPX_HOST_ARCH" > "$OPX_BIN/arch"
        return 0
    fi
    warn "usbredirect binary not found — compile from spice/usbredir or wait for a release asset"
    cat >&2 <<'EOF'
Build on-device (slow, needs meson/ninja/libusb):

  pkg install meson ninja libusb pkg-config
  git clone --depth 1 https://gitlab.freedesktop.org/spice/usbredir.git
  cd usbredir && meson setup build && ninja -C build
  cp build/tools/usbredirect $PREFIX/var/lib/opx-mg/bin/usbredirect
EOF
    return 1
}

opx_fetch_disk() {
    _disk=$OPX_IMAGES/disk.qcow2
    if [ -f "$_disk" ]; then
        info "guest disk already present"
        return 0
    fi
    if opx_fetch_asset_any "$_disk" guest; then
        return 0
    fi
    warn "prebaked guest image not in releases — falling back to Ubuntu cloud image (first boot installs firmware, needs network)"
    _cloud=$OPX_IMAGES/ubuntu-24.04-server-cloudimg-${OPX_GUEST_ARCH}.img
    _cloud_url="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-${OPX_GUEST_ARCH}.img"
    if [ ! -f "$_cloud" ]; then
        info "downloading Ubuntu 24.04 cloud image (~600MB)"
        opx_download "$_cloud_url" "$_cloud" || die "cloud image download failed"
    fi
    opx_need qemu-img
    info "converting to qcow2 and growing to 10G"
    qemu-img convert -O qcow2 "$_cloud" "$_disk"
    qemu-img resize "$_disk" 10G
}

opx_link_cli() {
    src=$OPX_ROOT/bin/opx-mg
    if opx_is_termux; then
        # A symlink here would exec bin/opx-mg directly, and its
        # '#!/usr/bin/env sh' shebang does not resolve on Termux.
        opx_write_launcher "${PREFIX}/bin/opx-mg" "$src"
        dest="${PREFIX}/bin/opx-mg"
    else
        dest="${HOME}/.local/bin/opx-mg"
        mkdir -p "$(dirname "$dest")"
        ln -sf "$src" "$dest"
    fi
    info "CLI linked at $dest"
}

opx_cmd_setup() {
    opx_mkdirs
    info "opx-mg ${OPX_MG_VERSION} setup (host ${OPX_HOST_ARCH}, guest ${OPX_GUEST_ARCH})"
    ok=0
    if ! opx_arch_supported; then
        warn "unsupported host arch '${OPX_HOST_ARCH}' — only aarch64 and armv7a release binaries are published"
        ok=1
    fi
    if [ "$OPX_HOST_ARCH" = armv7a ]; then
        info "32-bit host: QEMU runs the arm64 guest in TCG (slow); mem=${OPX_MEM} smp=${OPX_SMP}"
    fi
    if opx_is_termux; then
        opx_check_termux_api || ok=1
    else
        warn "not running inside Termux — USB attach will not work here; scripts are still installed"
    fi
    opx_check_qemu || ok=1
    edk=$(opx_find_edk2 || true)
    if [ -n "$edk" ]; then
        ln -sf "$edk" "$OPX_IMAGES/edk2-aarch64-code.fd"
        info "UEFI firmware -> $edk"
    else
        warn "edk2-aarch64-code.fd not found (Termux qemu-system-aarch64-headless should ship it)"
        ok=1
    fi
    opx_install_usbredirect || ok=1
    info "preparing cloud-init seed"
    opx_fetch_asset "seed.iso" "$OPX_IMAGES/seed.iso" || opx_build_seed
    info "preparing guest disk"
    if [ "$OPX_HOST_ARCH" = armv7a ] && ! command -v "$OPX_QEMU_BIN" >/dev/null 2>&1; then
        warn "guest disk skipped: no QEMU to boot it with (set OPX_QEMU_BIN, then re-run setup)"
    else
        opx_fetch_disk || ok=1
    fi
    info "linking CLI"
    opx_link_cli
    if [ "$ok" -ne 0 ]; then
        warn "setup finished with warnings — 'opx-mg doctor' for details"
        return 1
    fi
    info "setup complete. run: opx-mg"
}

opx_cmd_doctor() {
    printf 'opx-mg %s\n' "$OPX_MG_VERSION"
    printf 'home     %s\n' "$OPX_HOME"
    printf 'arch     %s (guest %s)\n' "$OPX_HOST_ARCH" "$OPX_GUEST_ARCH"
    printf 'termux   %s\n' "$(opx_is_termux && echo yes || echo no)"
    printf 'termux-usb  %s\n' "$(command -v termux-usb 2>/dev/null || echo MISSING)"
    printf 'qemu     %s\n' "$(command -v "$OPX_QEMU_BIN" 2>/dev/null || echo MISSING)"
    printf 'qemu-img %s\n' "$(command -v qemu-img 2>/dev/null || echo MISSING)"
    printf 'python3  %s\n' "$(command -v python3 2>/dev/null || echo MISSING)"
    printf 'usbredirect %s\n' "$([ -x "$OPX_BIN/usbredirect" ] && echo "$OPX_BIN/usbredirect" || echo MISSING)"
    printf 'disk     %s\n' "$([ -f "$OPX_IMAGES/disk.qcow2" ] && echo "$OPX_IMAGES/disk.qcow2" || echo MISSING)"
    printf 'seed     %s\n' "$([ -f "$OPX_IMAGES/seed.iso" ] && echo "$OPX_IMAGES/seed.iso" || echo MISSING)"
    printf 'edk2     %s\n' "$([ -e "$OPX_IMAGES/edk2-aarch64-code.fd" ] && echo ok || echo MISSING)"
    printf 'qemu up  %s\n' "$(opx_qemu_running && echo yes || echo no)"
    printf 'log      %s\n' "$OPX_LOG"
    if command -v termux-usb >/dev/null 2>&1; then
        printf 'usb devices:\n'
        opx_termux_usb -l 2>/dev/null || printf '  (termux-usb -l failed)\n'
    fi
}
