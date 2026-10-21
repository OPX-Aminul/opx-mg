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
OPX_LOG="$OPX_RUN/opx-mg.log"

OPX_REPO="${OPX_MG_REPO:-OPX-Aminul/opx-mg}"
OPX_RELEASE_API="https://api.github.com/repos/${OPX_REPO}/releases/latest"
OPX_RAW="https://raw.githubusercontent.com/${OPX_REPO}/main"

OPX_USBREDIR_PORT_BASE="${OPX_USBREDIR_PORT_BASE:-23456}"
OPX_SSH_PORT="${OPX_SSH_PORT:-2222}"
OPX_MEM="${OPX_MEM:-2048}"
OPX_SMP="${OPX_SMP:-4}"
OPX_WATCH_INTERVAL="${OPX_WATCH_INTERVAL:-3}"

opx_mkdirs() {
    mkdir -p "$OPX_BIN" "$OPX_IMAGES" "$OPX_RUN" "$OPX_STATE"
}

opx_ts() { date '+%Y-%m-%d %H:%M:%S'; }

opx_log() {
    opx_mkdirs
    printf '%s [%s] %s\n' "$(opx_ts)" "$1" "$2" | tee -a "$OPX_LOG" >&2
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
    url=$1 dest=$2
    tmp="${dest}.part"
    mkdir -p "$(dirname "$dest")"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url" || {
            rm -f "$tmp"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url" || {
            rm -f "$tmp"
            return 1
        }
    else
        die "need curl or wget"
    fi
    mv "$tmp" "$dest"
}

opx_github_asset_url() {
    # opx_github_asset_url NAME  -> prints browser_download_url
    name=$1
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
" "$name"
        return
    fi
    return 1
}

opx_qmp() {
    # send one QMP command (JSON object as $1), print reply
    sock=$OPX_RUN/qmp.sock
    [ -S "$sock" ] || die "QEMU is not running (no $sock)"
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

opx_termux_usb() {
    if command -v termux-usb >/dev/null 2>&1; then
        termux-usb "$@"
        return
    fi
    die "termux-usb not found — install Termux:API (pkg install termux-api) and the matching Termux:API APK"
}
