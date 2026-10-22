# shellcheck shell=sh
# One diagnostic log for setup, VM, USB and guest serial output.

opx_logs_system_info() {
    # Writes $OPX_LOGS/system-info.txt and prints its path.
    opx_mkdirs
    _si=$OPX_LOGS/system-info.txt
    {
        printf 'generated: %s\n' "$(opx_ts)"
        printf 'opx-mg: %s\n' "$OPX_MG_VERSION"
        printf 'arch: %s (guest %s)\n' "$OPX_HOST_ARCH" "$OPX_GUEST_ARCH"
        printf 'termux: %s\n' "$(opx_is_termux && echo yes || echo no)"
        printf 'home: %s\n' "$OPX_HOME"
        printf 'uname: %s\n' "$(uname -a 2>/dev/null || echo unknown)"
        printf 'qemu: %s\n' "$(command -v "$OPX_QEMU_BIN" 2>/dev/null || echo MISSING)"
        printf 'qemu-img: %s\n' "$(command -v qemu-img 2>/dev/null || echo MISSING)"
        printf 'termux-usb: %s\n' "$(command -v termux-usb 2>/dev/null || echo MISSING)"
        printf 'usbredirect: %s\n' "$([ -x "$OPX_BIN/usbredirect" ] && echo "$OPX_BIN/usbredirect" || echo MISSING)"
        printf 'vm: %s\n' "$(opx_qemu_running && echo running || echo stopped)"
        printf 'attached:\n'
        _any=0
        for _st in "$OPX_STATE"/attached-*; do
            [ -f "$_st" ] || continue
            _any=1
            printf '  %s\n' "$(cat "$_st")"
        done
        [ "$_any" -eq 0 ] && printf '  none\n'
        printf 'usb devices:\n'
        if command -v termux-usb >/dev/null 2>&1; then
            opx_termux_usb -l 2>/dev/null || printf '  (termux-usb -l failed)\n'
        else
            printf '  (termux-usb not installed)\n'
        fi
    } > "$_si"
    printf '%s' "$_si"
}

opx_cmd_logs() {
    sub=${1:-show}
    case "$sub" in
        path)
            printf '%s\n' "$OPX_LOG"
            ;;
        show|tail)
            if [ -f "$OPX_LOG" ]; then
                tail -n "${2:-200}" "$OPX_LOG"
            else
                info "no log yet: $OPX_LOG"
            fi
            ;;
        system)
            _si=$(opx_logs_system_info)
            cat "$_si"
            ;;
        bundle|share)
            opx_mkdirs
            opx_log INFO "log bundle requested"
            opx_logs_system_info >/dev/null
            _stamp=$(date +%Y%m%d-%H%M%S)
            _out=${2:-$PWD/opx-mg-logs-$_stamp.tar.gz}
            tar -czf "$_out" -C "$OPX_HOME" logs
            info "log bundle: $_out"
            printf '%s\n' "$_out"
            ;;
        clean-note)
            printf '%s\n' "Logs live in $OPX_LOGS; remove old opx-mg.log.* files manually."
            ;;
        *)
            die "logs subcommands: path | show [N] | system | bundle [FILE]"
            ;;
    esac
}
