#!/system/bin/sh
# AlwaysStrong — log collector.
#
# Dumps a diagnostic bundle to /sdcard so a user can attach it to a GitHub
# issue. Deliberately does NOT include the keybox contents (it holds private
# keys) — only its name, size and hash. The spoofed Pixel fingerprint IS
# included: it is fake by design and is exactly what a support request needs.
#
# Run it three ways:
#   - the "Collect logs" button in the WebUI (KSU / APatch / the standalone app)
#   - sh /data/adb/modules/tricky_store/collect_logs.sh   (root shell)
#   - sh action.sh logs
#
# Prints the output path on the last line so callers can show it.

MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
# fall back to the install path if run from a copy elsewhere (so the Module
# section isn't blank when someone runs the script from /sdcard or /tmp)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/tricky_store
CFG=/data/adb/tricky_store
OUT=/sdcard/AlwaysStrong-log.txt

# busybox for the tools toybox may lack (sha256sum on old devices, etc.)
BB=""
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox; do
    [ -x "$bb" ] && BB="$bb" && break
done
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif [ -n "$BB" ]; then "$BB" sha256sum; else echo "n/a"; fi; }

sec() { echo ""; echo "===== $* ====="; }

{
echo "AlwaysStrong diagnostic log"
echo "generated: $(date 2>/dev/null)"

sec "Module"
grep -E '^(name|version|versionCode)=' "$MODDIR/module.prop" 2>/dev/null
[ -f "$MODDIR/engine.sh" ] && grep -E '^ENGINE(_NAME)?=' "$MODDIR/engine.sh"

sec "Device / ROM"
for p in ro.product.brand ro.product.model ro.product.device \
         ro.build.version.release ro.build.version.sdk ro.build.fingerprint \
         ro.build.version.security_patch ro.product.cpu.abi; do
    echo "$p=$(getprop $p)"
done

sec "Root manager / Zygisk"
echo "KSU: $([ -d /data/adb/ksu ] && echo yes || echo no)"
echo "APatch: $([ -d /data/adb/ap ] && echo yes || echo no)"
echo "Magisk: $([ -d /data/adb/magisk ] && echo yes || echo no)"
echo "ZygiskNext: $([ -d /data/adb/modules/zygisksu ] && echo yes || echo no)"
echo "ReZygisk: $([ -d /data/adb/modules/rezygisk ] && echo yes || echo no)"

sec "TEE / daemon processes"
for proc in TEESimulator supervisor daemon aswatcher; do
    echo "$proc: $(pidof "$proc" 2>/dev/null || echo 'not running')"
done

sec "Spoofed fingerprint (pif.prop — safe to share)"
for f in "$CFG/pif.prop" "$MODDIR/pif.prop" "$MODDIR/custom.pif.prop"; do
    [ -s "$f" ] && { echo "--- $f"; cat "$f"; break; }
done

sec "Keybox (metadata only — contents withheld)"
KB="$CFG/keybox.xml"
if [ -s "$KB" ]; then
    echo "path: $KB"
    echo "size: $(wc -c < "$KB") bytes"
    echo "sha256: $(sha < "$KB" | awk '{print $1}')"
    echo "looks-like-keybox: $(head -c 4096 "$KB" | grep -q Keybox && echo yes || echo NO)"
    echo "custom-keybox mode: $([ -f "$CFG/custom_keybox" ] && echo on || echo off)"
else
    echo "no keybox.xml present"
fi

sec "Target list (count + first 15)"
if [ -s "$CFG/target.txt" ]; then
    echo "apps: $(grep -cvE '^[[:space:]]*$' "$CFG/target.txt")"
    grep -vE '^[[:space:]]*$' "$CFG/target.txt" | head -15
else
    echo "no target.txt"
fi

sec "Config dir"
ls -l "$CFG" 2>/dev/null

sec "autopif.log (fingerprint fetch)"
cat "$CFG/autopif.log" 2>/dev/null | tail -40 || echo "none"

sec "Conflicting modules present"
for c in playintegrityfix playintegrityfork tricky_store_v2 TrickyStore \
         tee_simulator TEESimulator safetynet-fix MagiskHidePropsConf Yurikey; do
    [ -d "/data/adb/modules/$c" ] && echo "present: $c"
done

sec "logcat (our tags, last 200 lines)"
logcat -d 2>/dev/null | grep -iE 'AlwaysStrong|TEESimulator|tricky_store|aswatcher|libinject|PlayIntegrity' | tail -200 || echo "logcat unavailable"

sec "dmesg (our tags)"
dmesg 2>/dev/null | grep -iE 'TEESimulator|tricky_store|aswatcher' | tail -40 || echo "dmesg unavailable"

echo ""
echo "===== end ====="
} > "$OUT" 2>&1

chmod 664 "$OUT" 2>/dev/null
echo "$OUT"
