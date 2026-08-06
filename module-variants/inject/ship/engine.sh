#!/system/bin/sh
# AlwaysStrong engine adapter — PlayIntegrityFix (inject-s).
#
# Everything that differs between the two Play Integrity engines lives here, so
# the shared scripts (action.sh, service.sh, pif_native_fetch.sh, customize.sh)
# stay identical across both builds. build.sh overlays exactly one of
# module-variants/<engine>/ onto module/ when it stages a zip.
#
# inject-s reads pif.prop straight from the module dir — no migrate.sh, no
# custom.pif.prop — and uses true/false spoof flags.

ENGINE=inject
ENGINE_NAME="PlayIntegrityFix (inject-s)"

# Upstream files (shipped inside the PIF zip) that customize.sh installs.
ENGINE_FILES="autopif.sh security_patch.sh pif.prop"

# Every prop file the STRONG flags must be enforced on, module dir first.
engine_pif_targets() {
    echo "$MODPATH/pif.prop $CONFIG_DIR/pif.prop"
}

# The STRONG spoof settings, in this engine's own naming.
#   spoofProvider=false      -> leave the keystore provider alone. TEESimulator
#                               already supplies the hardware-attested keystore
#                               STRONG needs; PIF must not override it.
#   spoofVendingBuild=true   -> Play Store build spoof (Fork calls this
#                               spoofVendingFinger).
engine_spoof_kv() {
    echo "spoofBuild=true spoofProps=true spoofProvider=false \
          spoofSignature=false spoofVendingBuild=true spoofVendingSdk=false"
}

# The spoof block appended to a freshly fetched fingerprint (pif.prop syntax).
engine_spoof_block() {
    cat <<'EOF'
spoofBuild=true
spoofProps=true
spoofProvider=false
spoofSignature=false
spoofVendingBuild=true
spoofVendingSdk=false
DEBUG=false
EOF
}

# engine_install_pif SRC — put a fetched/static pif.prop where the zygisk reads
# it. inject-s reads $MODPATH/pif.prop directly, so this is a copy; the
# config-dir copy is what the WebUI, sync_patch and the status row read.
engine_install_pif() {
    _src="$1"
    [ -s "$_src" ] || return 1
    mkdir -p "$CONFIG_DIR"
    cp -f "$_src" "$MODPATH/pif.prop" 2>/dev/null
    cp -f "$_src" "$CONFIG_DIR/pif.prop" 2>/dev/null
    # leftovers from a Fork install that was upgraded in place
    rm -f "$MODPATH/custom.pif.prop" "$MODPATH/custom.pif.json" 2>/dev/null
    [ -s "$MODPATH/pif.prop" ] || return 1
    engine_enforce_spoof
    return 0
}

# engine_autopif — upstream's own fetcher, used as the fallback when our native
# crawl fails. inject-s's autopif.sh writes $MODPATH/pif.prop itself and does
# not report failure through its exit code, so verify the file it left behind.
engine_autopif() {
    [ -f "$MODPATH/autopif.sh" ] || return 1
    sh "$MODPATH/autopif.sh"
    grep -q 'FINGERPRINT=google/' "$MODPATH/pif.prop" 2>/dev/null || return 1
    mkdir -p "$CONFIG_DIR"
    cp -f "$MODPATH/pif.prop" "$CONFIG_DIR/pif.prop" 2>/dev/null
    engine_enforce_spoof
    return 0
}

# Apply the STRONG flags to every prop file this engine may read.
engine_enforce_spoof() {
    _sed=${SED_I:-sed -i}
    for _f in $(engine_pif_targets); do
        [ -f "$_f" ] || continue
        for _kv in $(engine_spoof_kv); do
            _k="${_kv%=*}"; _v="${_kv#*=}"
            if grep -qE "^${_k}=" "$_f"; then
                $_sed "s|^${_k}=.*|${_k}=${_v}|" "$_f"
            else
                echo "${_k}=${_v}" >> "$_f"
            fi
        done
    done
}

# Seconds before the native crawl / upstream fetcher are killed. The multi-page
# crawl runs ~20-25s on a cold network; 25s kept grazing it and forcing the
# fallback on every tap.
ENGINE_NATIVE_TIMEOUT=60
ENGINE_AUTOPIF_TIMEOUT=60
