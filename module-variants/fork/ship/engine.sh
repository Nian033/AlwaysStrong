#!/system/bin/sh
# AlwaysStrong engine adapter — PlayIntegrityFork.
#
# Everything that differs between the two Play Integrity engines lives here, so
# the shared scripts (action.sh, service.sh, pif_native_fetch.sh, customize.sh)
# stay identical across both builds. build.sh overlays exactly one of
# module-variants/<engine>/ onto module/ when it stages a zip.
#
# Fork reads custom.pif.prop, produced from pif.prop by its own migrate.sh, and
# uses numeric spoof flags.

ENGINE=fork
ENGINE_NAME="PlayIntegrityFork"

# Upstream files (shipped inside the PIF zip) that customize.sh installs.
ENGINE_FILES="autopif4.sh killpi.sh migrate.sh common_setup.sh app_replace_list.txt example.pif.prop"

# Every prop file the STRONG flags must be enforced on, module dir first.
engine_pif_targets() {
    echo "$MODPATH/custom.pif.prop $MODPATH/pif.prop \
          $CONFIG_DIR/custom.pif.prop $CONFIG_DIR/pif.prop"
}

# The STRONG spoof settings, in this engine's own naming.
#   spoofProvider=0        -> leave the keystore provider alone. TEESimulator
#                             already supplies the hardware-attested keystore
#                             STRONG needs; PIF must not override it.
#   spoofVendingFinger=1   -> Play Store build spoof.
engine_spoof_kv() {
    echo "spoofProvider=0 spoofVendingFinger=1 spoofBuild=1 \
          spoofProps=1 spoofSignature=0 spoofVendingSdk=0"
}

# The spoof block appended to a freshly fetched fingerprint (pif.prop syntax).
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

# engine_install_pif SRC — put a fetched/static pif.prop where the zygisk reads
# it. Fork's zygisk reads custom.pif.prop, which only migrate.sh can produce.
# Returns non-zero when the engine cannot consume the file, so callers can fall
# through to the next fingerprint source instead of reporting a false success.
engine_install_pif() {
    _src="$1"
    [ -s "$_src" ] || return 1
    [ -f "$MODPATH/migrate.sh" ] || return 1
    cp -f "$_src" "$MODPATH/pif.prop" 2>/dev/null
    rm -f "$MODPATH/custom.pif.prop" "$MODPATH/custom.pif.json" 2>/dev/null
    sh "$MODPATH/migrate.sh" -i -a "$MODPATH/pif.prop" >/dev/null 2>&1
    [ -s "$MODPATH/custom.pif.prop" ] || return 1
    # migrate.sh writes spoofProvider=1 / spoofVendingFinger=0 — a WEAK config
    # that breaks STRONG. Re-enforce right here so every caller (boot, hourly,
    # Action) is correct without needing its own enforce step.
    engine_enforce_spoof
    return 0
}

# engine_autopif — upstream's own fetcher, used as the fallback when our native
# crawl fails. Must leave the engine's prop file in place. Returns 0 on success.
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
