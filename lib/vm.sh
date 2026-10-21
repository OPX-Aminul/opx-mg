# shellcheck shell=sh
# QEMU start / stop / console / ssh.

opx_qemu_bin() {
    command -v qemu-system-aarch64
}

opx_cmd_start() {
    opx_mkdirs
    if opx_qemu_running; then
        info "QEMU already running pid $(cat "$OPX_RUN/qemu.pid")"
        return 0
    fi
    [ -f "$OPX_IMAGES/disk.qcow2" ] || die "no guest disk — run: opx-mg setup"
    [ -e "$OPX_IMAGES/edk2-aarch64-code.fd" ] || die "no UEFI firmware — pkg install qemu-system-aarch64-headless"
    qemu=$(opx_qemu_bin) || die "qemu-system-aarch64 not on PATH"
    seed_args=""
    if [ -s "$OPX_IMAGES/seed.iso" ]; then
        seed_args="-drive file=${OPX_IMAGES}/seed.iso,format=raw,if=virtio,readonly=on"
    fi
    info "starting QEMU mem=${OPX_MEM} smp=${OPX_SMP} ssh=127.0.0.1:${OPX_SSH_PORT}"
    # Background: serial goes to a log; user attaches with `opx-mg console`.
    # shellcheck disable=SC2086
    "$qemu" \
        -machine virt,gic-version=3 \
        -cpu max \
        -accel tcg,thread=multi \
        -m "$OPX_MEM" -smp "$OPX_SMP" \
        -nographic \
        -bios "$OPX_IMAGES/edk2-aarch64-code.fd" \
        -drive "file=${OPX_IMAGES}/disk.qcow2,if=virtio,cache=writeback" \
        $seed_args \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${OPX_SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device qemu-xhci,id=xhci,p2=8,p3=8 \
        -qmp "unix:${OPX_RUN}/qmp.sock,server,wait=off" \
        -pidfile "$OPX_RUN/qemu.pid" \
        -serial "file:${OPX_RUN}/console.log" \
        -monitor "unix:${OPX_RUN}/monitor.sock,server,wait=off" \
        -daemonize \
        || die "QEMU failed to start — see $OPX_RUN/console.log"
    info "QEMU up pid $(cat "$OPX_RUN/qemu.pid")"
    info "console: opx-mg console     ssh: opx-mg ssh"
}

opx_cmd_stop() {
    if ! opx_qemu_running; then
        info "QEMU is not running"
        rm -f "$OPX_RUN/qemu.pid" "$OPX_RUN/qmp.sock"
        return 0
    fi
    pid=$(cat "$OPX_RUN/qemu.pid")
    info "stopping QEMU pid $pid"
    opx_qmp '{"execute":"quit"}' >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        i=$((i + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$OPX_RUN/qemu.pid"
    # usbredirect processes die with their fds; clean pid files
    for f in "$OPX_RUN"/usbredir-*.pid; do
        [ -f "$f" ] || continue
        kpid=$(cat "$f" 2>/dev/null) || true
        [ -n "$kpid" ] && kill "$kpid" 2>/dev/null || true
        rm -f "$f"
    done
    info "stopped"
}

opx_cmd_console() {
    opx_qemu_running || die "QEMU is not running"
    # Follow the serial log. Ctrl-C returns to Termux, VM keeps running.
    info "serial log (Ctrl-C to detach, VM stays up)"
    exec tail -f "$OPX_RUN/console.log"
}

opx_cmd_ssh() {
    opx_qemu_running || die "QEMU is not running — opx-mg start"
    info "ssh opx@127.0.0.1:${OPX_SSH_PORT}  (password: opx)"
    exec ssh -p "$OPX_SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        opx@127.0.0.1 "$@"
}

opx_cmd_status() {
    if opx_qemu_running; then
        printf 'vm       running pid %s\n' "$(cat "$OPX_RUN/qemu.pid")"
    else
        printf 'vm       stopped\n'
    fi
    printf 'ssh      127.0.0.1:%s\n' "$OPX_SSH_PORT"
    printf 'qmp      %s\n' "$OPX_RUN/qmp.sock"
    n=0
    for f in "$OPX_STATE"/attached-*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        printf 'usb      %s\n' "$(cat "$f")"
    done
    [ "$n" -eq 0 ] && printf 'usb      none attached\n'
}
