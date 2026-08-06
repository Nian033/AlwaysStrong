#!/system/bin/sh
# Play Integrity engine adapter — PlayIntegrityFix (inject-s).
#
# The shared module scripts never touch a pif file directly; they go through the
# functions here. build.sh overlays exactly one adapter per build, so action.sh,
# service.sh, pif_native_fetch.sh and customize.sh are identical in both.
#
# inject-s reads pif.prop straight from the module dir — no migrate.sh, no
# custom.pif.prop. Its spoof flags are true/false.

ENGINE=inject
ENGINE_NAME="PlayIntegrityFix (inject-s)"

# Upstream files (from the PIF zip) that customize.sh installs.
ENGINE_FILES="autopif.sh security_patch.sh pif.prop"

# Prop files the STRONG flags are enforced on, module dir first.
engine_pif_targets() {
    echo "$MODPATH/pif.prop $CONFIG_DIR/pif.prop"
}

# STRONG spoof settings in this engine's naming.
#   spoofProvider=false      leave the keystore provider alone — TEESimulator
#                            supplies the hardware-attested one STRONG needs.
#   spoofVendingBuild=true   Play Store build spoof (Fork calls this
#                            spoofVendingFinger).
engine_spoof_kv() {
    echo "spoofBuild=true spoofProps=true spoofProvider=false \
          spoofSignature=false spoofVendingBuild=true spoofVendingSdk=false"
}

# Spoof block appended to a freshly fetched fingerprint.
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

# engine_install_pif SRC — put a fingerprint where the zygisk reads it. The
# config-dir copy is what the WebUI, sync_patch and the status row read.
# Non-zero when this engine can't consume SRC, so callers fall through to the
# next fingerprint source instead of reporting a success that never landed.
engine_install_pif() {
    _src="$1"
    [ -s "$_src" ] || return 1
    mkdir -p "$CONFIG_DIR"
    cp -f "$_src" "$MODPATH/pif.prop" 2>/dev/null
    cp -f "$_src" "$CONFIG_DIR/pif.prop" 2>/dev/null
    # leftovers from a Fork install upgraded in place
    rm -f "$MODPATH/custom.pif.prop" "$MODPATH/custom.pif.json" 2>/dev/null
    [ -s "$MODPATH/pif.prop" ] || return 1
    engine_enforce_spoof
    return 0
}

# engine_autopif — upstream's own fetcher; the fallback when our native crawl
# fails. It writes $MODPATH/pif.prop itself and does not report failure through
# its exit code, so check the file it left behind. 0 on success.
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

# Seconds before the native crawl / upstream fetcher are killed. The crawl runs
# ~20-25s on a cold network, so 25 grazes it and forces the fallback every tap.
ENGINE_NATIVE_TIMEOUT=60
ENGINE_AUTOPIF_TIMEOUT=60
