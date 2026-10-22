# shellcheck shell=sh
# USB list / request / usbredirect wrap / QMP hotplug.

opx_usb_port_for() {
    # One TCP port per bus/device so several dongles can be attached at once.
    # Every /dev/bus/usb/BBB/DDD path is the same length, so hashing the path
    # put all devices on the same port and the second bind always failed.
    _p_id=$(opx_usb_id "$1")
    _p_bus=${_p_id%%-*}
    _p_num=${_p_id##*-}
    _p_bus=$(printf '%s' "$_p_bus" | sed 's/^0*//')
    _p_num=$(printf '%s' "$_p_num" | sed 's/^0*//')
    _p_bus=${_p_bus:-1}
    _p_num=${_p_num:-1}
    case "${_p_bus}${_p_num}" in
        *[!0-9]*|'') printf '%s' "$OPX_USBREDIR_PORT_BASE" ; return 0 ;;
    esac
    printf '%s' $((OPX_USBREDIR_PORT_BASE + (_p_bus * 20) + (_p_num - 1)))
}

opx_usb_id() {
    # /dev/bus/usb/001/004 -> 001-004
    printf '%s' "$1" | sed 's|.*/usb/||;s|/|-|g'
}

opx_cmd_usb_list() {
    # Capture first: `termux-usb -l | opx_json_list` returned the pipe's last
    # status, so a failed listing still exited 0 with no output.
    _list=$(opx_termux_usb -l) || exit 1
    printf '%s\n' "$_list" | opx_json_list
}

opx_cmd_usb_request() {
    dev=$1
    [ -n "$dev" ] || die "usage: opx-mg usb request /dev/bus/usb/BBB/DDD"
    info "requesting USB permission for $dev"
    opx_termux_usb -r "$dev"
}

opx_write_wrap() {
    # wrap script that usbredirects the inherited TERMUX_USB_FD
    wrap=$OPX_RUN/usbredirect-wrap.sh
    cat > "$wrap" <<'WRAP'
#!/data/data/com.termux/files/usr/bin/sh
# Fallback shebang for non-Termux:
# !/bin/sh
set -e
LOG="${OPX_USB_LOG:-/dev/stderr}"
BIN="${OPX_USBREDIRECT_BIN:?}"
PORT="${OPX_USBREDIR_PORT:?}"
FD="${TERMUX_USB_FD:-}"
log() { printf '%s [USB] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
if [ -z "$FD" ]; then
    log "usbredirect-wrap: TERMUX_USB_FD is empty"
    exit 1
fi
DEVNODE="/proc/self/fd/${FD}"
log "usbredirect-wrap: fd=$FD node=$DEVNODE port=$PORT"
# spice usbredirect accepts a usbfs path. The inherited fd is a usbfs
# handle; /proc/self/fd/N is the portable way to name it without opening
# /dev/bus/usb (which Android blocks).
if [ -n "${OPX_USBREDIR_PIDFILE:-}" ]; then
    # $$ stays the usbredirect pid after the exec below, so detach/stop can
    # kill the process that actually holds the TCP port.
    printf '%s\n' "$$" > "$OPX_USBREDIR_PIDFILE"
fi
if [ -x "$BIN" ]; then
    log "usbredirect-wrap: exec $BIN --device $DEVNODE --as 127.0.0.1:$PORT"
    exec "$BIN" --device "$DEVNODE" --as "127.0.0.1:${PORT}"
fi
log "usbredirect-wrap: binary not executable: $BIN"
exit 1
WRAP
    chmod +x "$wrap"
    printf '%s' "$wrap"
}

opx_qmp_attach_redir() {
    id=$1
    port=$2
    char="c_${id}"
    udev="u_${id}"
    # drop leftovers from a previous run of the same id
    opx_qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"${udev}\"}}" >/dev/null 2>&1 || true
    opx_qmp "{\"execute\":\"chardev-remove\",\"arguments\":{\"id\":\"${char}\"}}" >/dev/null 2>&1 || true
    reply=$(opx_qmp "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"${char}\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"${port}\"}},\"server\":false}}}}")
    opx_qmp_ok "$reply" "QMP chardev-add" || return 1
    reply=$(opx_qmp "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-redir\",\"chardev\":\"${char}\",\"id\":\"${udev}\",\"bus\":\"xhci.0\"}}")
    opx_qmp_ok "$reply" "QMP device_add usb-redir" || return 1
    return 0
}

opx_qmp_detach_redir() {
    id=$1
    opx_qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"u_${id}\"}}" >/dev/null 2>&1 || true
    opx_qmp "{\"execute\":\"chardev-remove\",\"arguments\":{\"id\":\"c_${id}\"}}" >/dev/null 2>&1 || true
}

opx_cmd_usb_attach() {
    dev=$1
    [ -n "$dev" ] || die "usage: opx-mg usb attach /dev/bus/usb/BBB/DDD"
    opx_qemu_running || die "start the VM first: opx-mg start"
    [ -x "$OPX_BIN/usbredirect" ] || die "usbredirect missing — opx-mg setup"
    id=$(opx_usb_id "$dev")
    port=$(opx_usb_port_for "$dev")
    state=$OPX_STATE/attached-$id
    pidfile=$OPX_RUN/usbredir-$id.pid
    if [ -f "$pidfile" ]; then
        old=$(cat "$pidfile")
        if kill -0 "$old" 2>/dev/null; then
            info "$dev already attached (pid $old port $port)"
            return 0
        fi
    fi
    info "permission + usbredirect for $dev -> 127.0.0.1:$port (id $id)"
    wrap=$(opx_write_wrap)
    # Request permission first so the -e exec is not racing the dialog.
    info "waiting for USB permission dialog"
    opx_termux_usb -r "$dev" >/dev/null 2>&1 || warn "permission request returned non-zero (continuing)"
    OPX_USBREDIRECT_BIN=$OPX_BIN/usbredirect
    OPX_USBREDIR_PORT=$port
    OPX_USB_LOG=$OPX_LOG
    OPX_USBREDIR_PIDFILE=$pidfile
    export OPX_USBREDIRECT_BIN OPX_USBREDIR_PORT OPX_USB_LOG OPX_USBREDIR_PIDFILE
    rm -f "$pidfile"
    # -E exports TERMUX_USB_FD; -e is the wrap script (single argv).
    # The wrap script records its own pid in $OPX_USBREDIR_PIDFILE, which is
    # the usbredirect pid after exec — $! would only be the subshell.
    (
        exec termux-usb -E -e "$wrap" "$dev"
    ) >>"$OPX_LOG" 2>&1 &
    rpid=$!
    info "usbredirect starting (launcher pid $rpid), log -> $OPX_LOG"
    # Give usbredirect a moment to bind the TCP port.
    i=0
    ready=0
    while [ "$i" -lt 25 ]; do
        if command -v nc >/dev/null 2>&1; then
            if nc -z 127.0.0.1 "$port" 2>/dev/null; then
                ready=1
                break
            fi
        else
            # python port probe
            python3 - "$port" <<'PY' 2>/dev/null && ready=1 && break || true
import socket,sys
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except Exception:
    sys.exit(1)
PY
        fi
        sleep 0.2
        i=$((i + 1))
    done
    if [ "$ready" -ne 1 ]; then
        warn "usbredirect did not bind 127.0.0.1:$port — see $OPX_LOG"
        warn "if the log says the device path is invalid, the usbredirect build cannot open /proc/self/fd/N"
        _dead=$(cat "$pidfile" 2>/dev/null || printf '%s' "$rpid")
        kill "$_dead" 2>/dev/null || true
        rm -f "$pidfile"
        return 1
    fi
    # The wrap script owns the pidfile; fall back to the launcher pid.
    [ -f "$pidfile" ] || printf '%s\n' "$rpid" > "$pidfile"
    if ! opx_qmp_attach_redir "$id" "$port"; then
        warn "QMP hotplug failed — usbredirect is up, try: opx-mg usb attach $dev"
        return 1
    fi
    printf '%s port=%s\n' "$dev" "$port" > "$state"
    info "attached $dev as usb-redir u_${id} on port $port"
    info "in the VM: lsusb && dmesg | tail"
}

opx_cmd_usb_detach() {
    dev=$1
    [ -n "$dev" ] || die "usage: opx-mg usb detach /dev/bus/usb/BBB/DDD"
    id=$(opx_usb_id "$dev")
    if opx_qemu_running; then
        opx_qmp_detach_redir "$id"
    else
        # No QEMU socket: still clean the state files instead of dying here.
        warn "VM is not running — removing local state only"
    fi
    pidfile=$OPX_RUN/usbredir-$id.pid
    if [ -f "$pidfile" ]; then
        kpid=$(cat "$pidfile")
        kill "$kpid" 2>/dev/null || true
        rm -f "$pidfile"
    fi
    rm -f "$OPX_STATE/attached-$id"
    info "detached $dev"
}

opx_cmd_usb() {
    sub=${1:-list}
    shift $(( $# > 0 ? 1 : 0 ))
    case "$sub" in
        list|ls) opx_cmd_usb_list ;;
        request|perm) opx_cmd_usb_request "$@" ;;
        attach) opx_cmd_usb_attach "$@" ;;
        detach) opx_cmd_usb_detach "$@" ;;
        status)
            opx_cmd_usb_list
            echo "--- attached ---"
            ls "$OPX_STATE"/attached-* >/dev/null 2>&1 && cat "$OPX_STATE"/attached-* || echo none
            ;;
        *) die "usb subcommands: list | request DEV | attach DEV | detach DEV | status" ;;
    esac
}
