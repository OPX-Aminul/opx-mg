# shellcheck shell=sh
# opx-mg -u / update — pull latest GitHub release assets + CLI.

opx_latest_release_tag() {
    if command -v python3 >/dev/null 2>&1; then
        curl -fsSL "$OPX_RELEASE_API" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print((d.get("tag_name") or "").lstrip("v"))
'
        return
    fi
    curl -fsSL "$OPX_RELEASE_API" | tr ',' '\n' | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1
}

opx_fetch_asset_force() {
    name=$1 dest=$2
    url=$(opx_github_asset_url "$name" 2>/dev/null || true)
    if [ -z "$url" ]; then
        warn "release asset $name not published yet"
        return 1
    fi
    info "downloading $name"
    opx_download "$url" "$dest"
}

opx_refresh_cli_from_release() {
    ver=$1
    tarname="opx-mg-${ver}.tar.gz"
    tmp=$OPX_RUN/update
    mkdir -p "$tmp"
    archive=$tmp/$tarname
    if ! opx_fetch_asset_force "$tarname" "$archive"; then
        warn "CLI tarball $tarname missing — keeping current scripts"
        return 1
    fi
    dest=$OPX_ROOT
    if opx_is_termux && [ -d "${PREFIX}/lib/opx-mg" ]; then
        dest="${PREFIX}/lib/opx-mg"
    fi
    info "unpacking CLI into $dest"
    tar -xzf "$archive" -C "$dest"
    chmod +x "$dest/bin/opx-mg" "$dest/install.sh" "$dest/guest/build-image.sh" 2>/dev/null || true
    OPX_ROOT=$dest
    export OPX_ROOT
}

opx_cmd_update() {
    force_image=0
    for a in "$@"; do
        case "$a" in
            --image|--disk) force_image=1 ;;
        esac
    done
    opx_mkdirs
    info "checking latest release of ${OPX_REPO}"
    latest=$(opx_latest_release_tag 2>/dev/null || true)
    if [ -z "$latest" ]; then
        die "could not read ${OPX_RELEASE_API}"
    fi
    current=$OPX_MG_VERSION
    info "installed ${current}  latest ${latest}"
    opx_refresh_cli_from_release "$latest" || true
    if [ -f "$OPX_ROOT/VERSION" ]; then
        OPX_MG_VERSION=$(tr -d ' \n' < "$OPX_ROOT/VERSION")
    fi
    opx_fetch_asset_force "usbredirect-aarch64" "$OPX_BIN/usbredirect" && chmod +x "$OPX_BIN/usbredirect" || true
    opx_fetch_asset_force "opx-usb-shim.so" "$OPX_BIN/opx-usb-shim.so" || true
    opx_fetch_asset_force "seed.iso" "$OPX_IMAGES/seed.iso" || opx_build_seed || true
    if [ ! -f "$OPX_IMAGES/disk.qcow2" ] || [ "$force_image" -eq 1 ]; then
        if opx_qemu_running; then
            warn "VM is running — not replacing guest disk (stop first for --image)"
        else
            opx_fetch_asset_force "opx-mg-ubuntu-arm64.qcow2" "$OPX_IMAGES/disk.qcow2" || true
        fi
    else
        info "guest disk kept (opx-mg update --image to replace)"
    fi
    opx_link_cli
    info "updated to ${OPX_MG_VERSION}. run: opx-mg doctor"
}
