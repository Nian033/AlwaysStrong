#!/system/bin/sh
# Attestation-engine adapter — TrickyStore, 5ec1cff fork (--engine trickystore).
#
# See attest/tee.sh for the contract. TrickyStore is NOT zygisk: a native
# service.apk is launched through app_process and injects into keystore2. The
# config it reads (/data/adb/tricky_store/keybox.xml + target.txt) is exactly
# what the shared AlwaysStrong scripts (keybox_fetch.sh, build_target_txt.sh,
# the WebUI) already manage, so only the install + daemon differ from TEE.

ATTEST=trickystore
ATTEST_NAME="TrickyStore"

attest_install() {
    case "$ARCH" in
        arm64|arm|x64) : ;;
        *) abort "TrickyStore engine supports arm64/arm/x64 only (got $ARCH)" ;;
    esac
    # TrickyStore's lib dirs are named arm64/arm/x64 — the same tokens as $ARCH.
    install_file "lib/$ARCH/libtricky_store.so" "$MODPATH"
    install_file "service.apk"                  "$MODPATH"
    install_file "machikado.$ARCH"              "$MODPATH"
    mv "$MODPATH/machikado.$ARCH" "$MODPATH/machikado"
    install_file "mazoku"                       "$MODPATH"
    chmod 755 "$MODPATH/machikado" "$MODPATH/mazoku" "$MODPATH/daemon" 2>/dev/null
    ui_print "TrickyStore installed ($ARCH)"
}

# TrickyStore hijacks keystore2 by injecting at the `service` boot stage, BEFORE
# sys.boot_completed (this is what upstream's own service.sh does). Starting it
# late — where the TEE engine starts, after boot_completed — misses the window
# and the daemon crash-loops with EBADF, so it never injects. Opt into the early
# start; service.sh honours attest_early. Confirmed against a standalone vanilla
# install: early start => one persistent daemon, 0 errors, STRONG.
attest_early() { return 0; }

# Run the app_process daemon in a restart loop (it exec's into
# --nice-name=TrickyStore). cd to $MODDIR so its relative ./service.apk
# resolves. Idempotent via a loop-pid marker: the early start and the watchdog
# both call this, so a live loop is left alone rather than stacked (parallel
# loops fight over the keystore2 ptrace and all but one get EBADF).
attest_start() {
    _lk=/data/adb/tricky_store/.ts_loop
    if [ -f "$_lk" ] && kill -0 "$(cat "$_lk" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    ( cd "$MODDIR" || exit 1
      while true; do
          ./daemon
          [ $? -ne 0 ] && break
          sleep 2
      done ) &
    echo $! > "$_lk" 2>/dev/null
}

attest_alive() {
    pidof TrickyStore >/dev/null 2>&1
}
