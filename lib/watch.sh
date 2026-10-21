# shellcheck shell=sh
# Poll termux-usb -l and attach anything new.

opx_cmd_watch() {
    opx_qemu_running || die "start the VM first: opx-mg start"
    info "watching USB (every ${OPX_WATCH_INTERVAL}s) — Ctrl-C to stop the watcher, VM stays up"
    seen=$OPX_STATE/watch-seen
    mkdir -p "$OPX_STATE"
    : > "$seen"
    trap 'info "watcher stopped"; exit 0' INT TERM
    while true; do
        now=$OPX_RUN/watch-now
        opx_termux_usb -l 2>/dev/null | opx_json_list | sort > "$now" || true
        while IFS= read -r dev; do
            [ -n "$dev" ] || continue
            if grep -Fxq "$dev" "$seen" 2>/dev/null; then
                continue
            fi
            info "new USB device $dev"
            if opx_cmd_usb_attach "$dev"; then
                printf '%s\n' "$dev" >> "$seen"
            else
                warn "attach failed for $dev (will retry)"
            fi
        done < "$now"
        # drop seen entries that vanished
        if [ -s "$seen" ]; then
            tmp=$OPX_RUN/watch-keep
            : > "$tmp"
            while IFS= read -r old; do
                grep -Fxq "$old" "$now" && printf '%s\n' "$old" >> "$tmp"
            done < "$seen"
            mv "$tmp" "$seen"
        fi
        sleep "$OPX_WATCH_INTERVAL"
    done
}
