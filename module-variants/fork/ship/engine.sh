#!/system/bin/sh
# Play Integrity engine adapter — PlayIntegrityFork.
#
# The shared module scripts never touch a pif file directly; they go through the
# functions here. build.sh overlays exactly one adapter per build, so action.sh,
# service.sh, pif_native_fetch.sh and customize.sh are identical in both.
#
# Fork's zygisk reads custom.pif.prop, which only its own migrate.sh can produce
# from a pif.prop. Its spoof flags are numeric.

ENGINE=fork
ENGINE_NAME="PlayIntegrityFork"

# Upstream files (from the PIF zip) that customize.sh installs.
ENGINE_FILES="autopif4.sh killpi.sh migrate.sh common_setup.sh example.pif.prop app_replace_list.txt"

# Prop files the STRONG flags are enforced on, module dir first.
engine_pif_targets() {
    echo "$MODPATH/custom.pif.prop $MODPATH/pif.prop \
          $CONFIG_DIR/custom.pif.prop $CONFIG_DIR/pif.prop"
}

# STRONG spoof settings in this engine's naming.
#   spoofProvider=0        leave the keystore provider alone — TEESimulator
#                          supplies the hardware-attested one STRONG needs.
#   spoofVendingFinger=1   Play Store build spoof.
engine_spoof_kv() {
    echo "spoofProvider=0 spoofVendingFinger=1 spoofBuild=1 \
          spoofProps=1 spoofSignature=0 spoofVendingSdk=0"
}

# Spoof block appended to a freshly fetched fingerprint.
engine_spoof_block() {
    cat <<'EOF'
spoofProvider=0
spoofVendingFinger=1
spoofBuild=1
spoofProps=1
spoofSignature=0
spoofVendingSdk=0
EOF
}

# engine_install_pif SRC — put a fingerprint where the zygisk reads it.
# Non-zero when this engine can't consume SRC, so callers fall through to the
# next fingerprint source instead of reporting a success that never landed.
engine_install_pif() {
    _src="$1"
    [ -s "$_src" ] || return 1
    [ -f "$MODPATH/migrate.sh" ] || return 1
    cp -f "$_src" "$MODPATH/pif.prop" 2>/dev/null
    rm -f "$MODPATH/custom.pif.prop" "$MODPATH/custom.pif.json" 2>/dev/null
    sh "$MODPATH/migrate.sh" -i -a "$MODPATH/pif.prop" >/dev/null 2>&1
    [ -s "$MODPATH/custom.pif.prop" ] || return 1
    # migrate.sh writes spoofProvider=1 / spoofVendingFinger=0, a WEAK config
    # that breaks STRONG. Enforce here so every caller is correct without
    # needing its own enforce step.
    engine_enforce_spoof
    return 0
}

# engine_autopif — upstream's own fetcher; the fallback when our native crawl
# fails. Leaves the engine's prop file in place. 0 on success.
engine_autopif() {
    [ -f "$MODPATH/autopif4.sh" ] || return 1
    sh "$MODPATH/autopif4.sh" -s -m || return 1
    [ -s "$MODPATH/custom.pif.prop" ] || return 1
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

# Seconds before the native crawl / upstream fetcher are killed.
ENGINE_NATIVE_TIMEOUT=60
ENGINE_AUTOPIF_TIMEOUT=40
