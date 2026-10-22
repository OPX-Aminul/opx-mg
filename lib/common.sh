# shellcheck shell=sh
# Shared paths, logging, download. Sourced by every opx-mg command.

if [ -n "${OPX_ROOT:-}" ] && [ -f "$OPX_ROOT/VERSION" ]; then
    OPX_MG_VERSION=$(tr -d ' \n' < "$OPX_ROOT/VERSION")
fi
: "${OPX_MG_VERSION:=0.1.0}"

opx_detect_prefix() {
    if [ -n "${OPX_MG_HOME:-}" ]; then
        printf '%s' "$OPX_MG_HOME"
        return
    fi
    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ]; then
        printf '%s' "$PREFIX/var/lib/opx-mg"
        return
    fi
    printf '%s' "${HOME:?}/.opx-mg"
}

OPX_HOME="$(opx_detect_prefix)"
OPX_BIN="$OPX_HOME/bin"
OPX_IMAGES="$OPX_HOME/images"
OPX_RUN="$OPX_HOME/run"
OPX_STATE="$OPX_HOME/state"
OPX_LOGS="$OPX_HOME/logs"
# One persistent file with setup, VM, USB and guest serial output. Rotation
# only happens at session start while the VM is down, so a running QEMU never
# loses the file it is appending to.
OPX_LOG="$OPX_LOGS/opx-mg.log"
OPX_LOG_MAX_BYTES="${OPX_LOG_MAX_BYTES:-2097152}"

OPX_REPO="${OPX_MG_REPO:-OPX-Aminul/opx-mg}"
OPX_RELEASE_API="https://api.github.com/repos/${OPX_REPO}/releases/latest"
OPX_RAW="https://raw.githubusercontent.com/${OPX_REPO}/main"

# Host arch of the Termux userspace, not the kernel: a 32-bit Termux on a
# 64-bit phone reports armv8l and must get the armv7a binaries.
opx_detect_arch() {
    _opx_arch=""
    case "$(uname -m 2>/dev/null || echo unknown)" in
        aarch64|arm64)                  _opx_arch=aarch64 ;;
        armv7l|armv8l|armv7a|armv8a|arm) _opx_arch=armv7a ;;
        x86_64|amd64)                   _opx_arch=x86_64 ;;
        i?86)                           _opx_arch=i686 ;;
    esac
    if [ -z "$_opx_arch" ] && command -v getprop >/dev/null 2>&1; then
        case "$(getprop ro.product.cpu.abi 2>/dev/null || true)" in
            arm64-v8a)            _opx_arch=aarch64 ;;
            armeabi-v7a|armeabi)  _opx_arch=armv7a ;;
            x86_64)               _opx_arch=x86_64 ;;
            x86)                  _opx_arch=i686 ;;
        esac
    fi
    printf '%s' "${_opx_arch:-unknown}"
}

OPX_HOST_ARCH="${OPX_HOST_ARCH:-$(opx_detect_arch)}"
export OPX_HOST_ARCH

opx_arch_supported() {
    case "$OPX_HOST_ARCH" in
        aarch64|armv7a) return 0 ;;
        *) return 1 ;;
    esac
}

# Guest disk arch. Override with OPX_GUEST_ARCH when pairing a custom QEMU
# with an armhf guest; the stock arm64 image is used for both host arches.
OPX_GUEST_ARCH="${OPX_GUEST_ARCH:-arm64}"

opx_asset_candidates() {
    # opx_asset_candidates usbredirect|shim|guest|seed
    # Prints release asset names, newest naming first, then legacy aliases.
    _opx_base=$1
    case "$_opx_base" in
        usbredirect)
            printf '%s\n' "usbredirect-${OPX_HOST_ARCH}"
            ;;
        shim)
            printf '%s\n' "opx-usb-shim-${OPX_HOST_ARCH}.so"
            # Releases before 0.2 only shipped the aarch64 shim under this name.
            [ "$OPX_HOST_ARCH" = aarch64 ] && printf '%s\n' "opx-usb-shim.so"
            ;;
        guest)
            printf '%s\n' "opx-mg-ubuntu-${OPX_GUEST_ARCH}.qcow2"
            ;;
        seed)
            printf '%s\n' "seed.iso"
            ;;
        *)
            printf '%s\n' "$_opx_base"
            ;;
    esac
}

OPX_USBREDIR_PORT_BASE="${OPX_USBREDIR_PORT_BASE:-23456}"
OPX_SSH_PORT="${OPX_SSH_PORT:-2222}"
# Both arches boot the arm64 guest; override for a custom 32-bit QEMU build.
OPX_QEMU_BIN="${OPX_QEMU_BIN:-qemu-system-aarch64}"
# 32-bit hosts have a small address space; TCG + a 2G guest is not viable.
if [ "$OPX_HOST_ARCH" = armv7a ]; then
    : "${OPX_MEM:=1024}"
    : "${OPX_SMP:=2}"
else
    : "${OPX_MEM:=2048}"
    : "${OPX_SMP:=4}"
fi
OPX_WATCH_INTERVAL="${OPX_WATCH_INTERVAL:-3}"

opx_mkdirs() {
    mkdir -p "$OPX_BIN" "$OPX_IMAGES" "$OPX_RUN" "$OPX_STATE" "$OPX_LOGS"
}

opx_ts() { date '+%Y-%m-%d %H:%M:%S'; }

opx_log_rotate() {
    [ -f "$OPX_LOG" ] || return 0
    opx_qemu_running && return 0
    _size=$(wc -c < "$OPX_LOG" 2>/dev/null || echo 0)
    [ "${_size:-0}" -gt "$OPX_LOG_MAX_BYTES" ] || return 0
    _rot="$OPX_LOG.$(date +%Y%m%d-%H%M%S)"
    mv "$OPX_LOG" "$_rot" 2>/dev/null || return 0
    opx_log INFO "log rotated: $_rot"
}

opx_log() {
    opx_mkdirs
    printf '%s [%s] %s\n' "$(opx_ts)" "$1" "$2" | tee -a "$OPX_LOG" >&2
}

opx_log_session_start() {
    opx_mkdirs
    opx_log_rotate
    opx_log INFO "=== start: ${1:-opx-mg} | version $OPX_MG_VERSION | arch $OPX_HOST_ARCH | guest $OPX_GUEST_ARCH | termux $(opx_is_termux && echo yes || echo no) | cwd $(pwd)"
}

opx_log_session_end() {
    _rc=$?
    opx_log INFO "=== end: exit $_rc"
    return "$_rc"
}

# opx_run COMMAND [ARGS...] — stream output to the terminal, append it to the
# single log file, and return the command's real exit status (POSIX sh has no
# pipefail, so the status is carried out of the pipeline in a file).
opx_run() {
    opx_log INFO "exec: $*"
    _opx_rc_file="$OPX_RUN/.opx-rc"
    mkdir -p "$OPX_RUN"
    : > "$_opx_rc_file"
    { { if "$@" 2>&1; then printf '0' > "$_opx_rc_file"; else printf '%s' "$?" > "$_opx_rc_file"; fi; } | tee -a "$OPX_LOG" >&2; }
    _opx_rc=$(cat "$_opx_rc_file" 2>/dev/null || true)
    [ -n "$_opx_rc" ] || _opx_rc=1
    if [ "$_opx_rc" -ne 0 ]; then
        opx_log WARN "exec failed ($_opx_rc): $*"
    fi
    return "$_opx_rc"
}

info() { opx_log INFO "$*"; }
warn() { opx_log WARN "$*"; }
die()  { opx_log ERROR "$*"; exit 1; }

opx_need() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

opx_is_termux() {
    [ -n "${PREFIX:-}" ] && [ -d "/data/data/com.termux/files" ]
}

# opx_write_launcher DEST SCRIPT
# Termux has no /usr/bin/env, so exec'ing a script that starts with
# '#!/usr/bin/env sh' fails with "not found" unless the Termux exec wrapper
# is installed. The launcher uses the absolute Termux sh path and passes the
# real CLI to sh, so bin/opx-mg's own shebang is never used.
opx_write_launcher() {
    _l_dest=$1 _l_script=$2
    _l_sh="${PREFIX:-/usr}/bin/sh"
    [ -x "$_l_sh" ] || _l_sh=$(command -v sh 2>/dev/null) || _l_sh=/bin/sh
    mkdir -p "$(dirname "$_l_dest")"
    # Never write through an old symlink: it would truncate the real script.
    rm -f "$_l_dest"
    cat > "$_l_dest" <<EOF
#!$_l_sh
# opx-mg launcher — generated by setup/install, do not edit.
exec "$_l_sh" "$_l_script" "\$@"
EOF
    chmod +x "$_l_dest"
}

opx_json_list() {
    # stdin: JSON array of strings -> one path per line
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list):
    for x in d:
        print(x)
'
        return
    fi
    tr -d '[]" ' | tr ',' '\n' | sed '/^$/d'
}

opx_download() {
    # opx_download URL DEST
    _dl_url=$1 _dl_dest=$2
    _dl_tmp="${_dl_dest}.part"
    mkdir -p "$(dirname "$_dl_dest")"
    opx_log INFO "download: $_dl_url -> $_dl_dest"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$_dl_tmp" "$_dl_url" || {
            rm -f "$_dl_tmp"
            opx_log WARN "download failed: $_dl_url"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$_dl_tmp" "$_dl_url" || {
            rm -f "$_dl_tmp"
            opx_log WARN "download failed: $_dl_url"
            return 1
        }
    else
        die "need curl or wget"
    fi
    mv "$_dl_tmp" "$_dl_dest"
    _dl_size=$(wc -c < "$_dl_dest" 2>/dev/null || echo 0)
    opx_log INFO "downloaded: $_dl_dest (${_dl_size} bytes)"
}

opx_github_asset_url() {
    # opx_github_asset_url NAME  -> prints browser_download_url
    _asset_name=$1
    if command -v python3 >/dev/null 2>&1; then
        curl -fsSL "$OPX_RELEASE_API" | python3 -c "
import json,sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for a in d.get('assets') or []:
    if a.get('name')==name:
        print(a.get('browser_download_url',''))
        sys.exit(0)
sys.exit(1)
" "$_asset_name"
        return
    fi
    return 1
}

opx_qmp() {
    # send one QMP command (JSON object as $1), print reply
    sock=$OPX_RUN/qmp.sock
    [ -S "$sock" ] || die "QEMU is not running (no $sock)"
    command -v python3 >/dev/null 2>&1 \
        || die "python3 is required for QMP hotplug (pkg install python)"
    python3 - "$sock" "$1" <<'PY'
import json, socket, sys
sock_path, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(8)
s.connect(sock_path)
def recv_obj(sock):
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            return json.loads(line.decode())
    if buf:
        return json.loads(buf.decode())
    return {}
hello = recv_obj(s)
s.sendall(b'{"execute":"qmp_capabilities"}\n')
recv_obj(s)
s.sendall((cmd if cmd.endswith("\n") else cmd + "\n").encode())
print(json.dumps(recv_obj(s)))
s.close()
PY
}

opx_qemu_running() {
    [ -f "$OPX_RUN/qemu.pid" ] || return 1
    pid=$(cat "$OPX_RUN/qemu.pid" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null
}

opx_qmp_ok() {
    # opx_qmp_ok REPLY WHAT — a QMP error has no "return" member; an empty
    # reply (python3 died, socket closed) must not count as success either.
    case "$1" in
        *'"return"'*) return 0 ;;
        *) warn "${2:-QMP command} failed: ${1:-no reply from QEMU}" ; return 1 ;;
    esac
}

opx_termux_usb() {
    # termux-api is a normal package; the APK is not, so this only fixes half
    # of a missing install. Self-heal the package, then say what is left.
    if ! command -v termux-usb >/dev/null 2>&1 && opx_is_termux \
        && [ "${OPX_NO_INSTALL:-0}" != "1" ] && command -v pkg >/dev/null 2>&1; then
        info "termux-usb missing — installing termux-api"
        opx_run pkg install -y termux-api || true
    fi
    if command -v termux-usb >/dev/null 2>&1; then
        termux-usb "$@"
        return
    fi
    die "termux-usb not found — install Termux:API (pkg install termux-api) and the matching Termux:API APK"
}
