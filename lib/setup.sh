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

opx_check_qemu() {
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        return 0
    fi
    warn "qemu-system-aarch64 missing"
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
    name=$1 dest=$2
    if [ -f "$dest" ]; then
        info "already have $name"
        return 0
    fi
    url=$(opx_github_asset_url "$name" 2>/dev/null || true)
    if [ -z "$url" ]; then
        warn "release asset $name not published yet"
        return 1
    fi
    info "downloading $name"
    opx_download "$url" "$dest"
}

opx_install_usbredirect() {
    dest=$OPX_BIN/usbredirect
    if [ -x "$dest" ]; then
        return 0
    fi
    if [ -x "$OPX_ROOT/host/usbredirect" ]; then
        cp "$OPX_ROOT/host/usbredirect" "$dest"
        chmod +x "$dest"
        return 0
    fi
    if opx_fetch_asset "usbredirect-aarch64" "$dest"; then
        chmod +x "$dest"
        return 0
    fi
    if command -v usbredirect >/dev/null 2>&1; then
        ln -sf "$(command -v usbredirect)" "$dest"
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
    disk=$OPX_IMAGES/disk.qcow2
    if [ -f "$disk" ]; then
        info "guest disk already present"
        return 0
    fi
    if opx_fetch_asset "opx-mg-ubuntu-arm64.qcow2" "$disk"; then
        return 0
    fi
    warn "prebaked guest image not in releases — falling back to Ubuntu cloud image (first boot installs firmware, needs network)"
    cloud=$OPX_IMAGES/ubuntu-24.04-server-cloudimg-arm64.img
    url="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img"
    if [ ! -f "$cloud" ]; then
        info "downloading Ubuntu 24.04 cloud image (~600MB)"
        opx_download "$url" "$cloud" || die "cloud image download failed"
    fi
    opx_need qemu-img
    info "converting to qcow2 and growing to 10G"
    qemu-img convert -O qcow2 "$cloud" "$disk"
    qemu-img resize "$disk" 10G
}

opx_link_cli() {
    src=$OPX_ROOT/bin/opx-mg
    if opx_is_termux; then
        dest="${PREFIX}/bin/opx-mg"
    else
        dest="${HOME}/.local/bin/opx-mg"
        mkdir -p "$(dirname "$dest")"
    fi
    ln -sf "$src" "$dest"
    info "CLI linked at $dest"
}

opx_cmd_setup() {
    opx_mkdirs
    info "opx-mg ${OPX_MG_VERSION} setup"
    ok=0
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
    opx_build_seed
    opx_fetch_disk || ok=1
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
    printf 'termux   %s\n' "$(opx_is_termux && echo yes || echo no)"
    printf 'termux-usb  %s\n' "$(command -v termux-usb 2>/dev/null || echo MISSING)"
    printf 'qemu     %s\n' "$(command -v qemu-system-aarch64 2>/dev/null || echo MISSING)"
    printf 'qemu-img %s\n' "$(command -v qemu-img 2>/dev/null || echo MISSING)"
    printf 'python3  %s\n' "$(command -v python3 2>/dev/null || echo MISSING)"
    printf 'usbredirect %s\n' "$([ -x "$OPX_BIN/usbredirect" ] && echo "$OPX_BIN/usbredirect" || echo MISSING)"
    printf 'disk     %s\n' "$([ -f "$OPX_IMAGES/disk.qcow2" ] && echo "$OPX_IMAGES/disk.qcow2" || echo MISSING)"
    printf 'seed     %s\n' "$([ -f "$OPX_IMAGES/seed.iso" ] && echo "$OPX_IMAGES/seed.iso" || echo MISSING)"
    printf 'edk2     %s\n' "$([ -e "$OPX_IMAGES/edk2-aarch64-code.fd" ] && echo ok || echo MISSING)"
    printf 'qemu up  %s\n' "$(opx_qemu_running && echo yes || echo no)"
    if command -v termux-usb >/dev/null 2>&1; then
        printf 'usb devices:\n'
        opx_termux_usb -l 2>/dev/null || printf '  (termux-usb -l failed)\n'
    fi
}
