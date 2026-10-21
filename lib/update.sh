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
    _force_name=$1 _force_dest=$2
    _force_url=$(opx_github_asset_url "$_force_name" 2>/dev/null || true)
    if [ -z "$_force_url" ]; then
        warn "release asset $_force_name not published yet"
        return 1
    fi
    info "downloading $_force_name"
    opx_download "$_force_url" "$_force_dest"
}

opx_fetch_asset_any_force() {
    # opx_fetch_asset_any_force DEST BASE — arch-specific first, then aliases
    _af_dest=$1 _af_base=$2
    for _af_name in $(opx_asset_candidates "$_af_base"); do
        if opx_fetch_asset_force "$_af_name" "$_af_dest"; then
            return 0
        fi
    done
    return 1
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
    if opx_fetch_asset_any_force "$OPX_BIN/usbredirect" usbredirect; then
        chmod +x "$OPX_BIN/usbredirect"
        printf '%s\n' "$OPX_HOST_ARCH" > "$OPX_BIN/arch"
    fi
    opx_fetch_asset_any_force "$OPX_BIN/opx-usb-shim.so" shim || true
    opx_fetch_asset_any_force "$OPX_IMAGES/seed.iso" seed || opx_build_seed || true
    if [ ! -f "$OPX_IMAGES/disk.qcow2" ] || [ "$force_image" -eq 1 ]; then
        if opx_qemu_running; then
            warn "VM is running — not replacing guest disk (stop first for --image)"
        else
            opx_fetch_asset_any_force "$OPX_IMAGES/disk.qcow2" guest || true
        fi
    else
        info "guest disk kept (opx-mg update --image to replace)"
    fi
    opx_link_cli
    info "updated to ${OPX_MG_VERSION}. run: opx-mg doctor"
}
