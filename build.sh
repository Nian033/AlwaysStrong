#!/usr/bin/env bash
# AlwaysStrong build script.
# Downloads the upstream TEESimulator-RS + Play Integrity release ZIPs, overlays
# our scripts, and repackages each release line into an installable Magisk ZIP.
#
# Both lines are built from THIS tree — there is no second branch. module/ holds
# everything they share; module-variants/<line>/ holds the few files that differ:
#
#   module-variants/<line>/build.conf            upstream pin + which files to lift
#   module-variants/<line>/module.prop.override  module.prop keys to rewrite
#   module-variants/<line>/ship/                 files overlaid into the module
#
# Usage:
#   ./build.sh                        # both lines
#   ./build.sh --variant fork         # only the default (PlayIntegrityFork) line
#   ./build.sh --variant inject       # only the PlayIntegrityFix inject-s line
#   ./build.sh --tee v6.0.0           # override the TEESimulator-RS release tag
#   ./build.sh --tee-file PATH        # use a LOCAL TEESimulator-RS zip, skip the download
#   ./build.sh --pif v16              # override the PIF tag  (needs --variant)
#   ./build.sh --pif-file PATH        # use a LOCAL PIF zip   (needs --variant)
#   ./build.sh --clean                # wipe build/ first
#
# Output:
#   out/AlwaysStrong-<ver>.zip         PlayIntegrityFork          (default)
#   out/AlwaysStrong-<ver>-inject.zip  PlayIntegrityFix inject-s
#
# CI / nightly builds live as GitHub Actions artifacts, not release assets, so
# fetch them yourself (e.g. `gh run download -R osm0sis/PlayIntegrityFork -D ci`)
# and point --pif-file / --tee-file at the resulting module zip.
#
# Requires: bash, curl OR wget, unzip, zip, sha256sum (or shasum on macOS).

set -euo pipefail

# ---------- Configurable upstream versions ----------
# TEESimulator-RS is shared by both lines and pinned here. Each line's Play
# Integrity engine is pinned in its own module-variants/<line>/build.conf, so a
# bump to one line cannot silently move the other.
# Bump with: scripts/update-upstream.sh --apply
TEE_TAG_DEFAULT="v6.0.1-307"
TEE_ASSET_DEFAULT="TEESimulator-RS-v6.0.1-307-Release.zip"

TEE_TAG="$TEE_TAG_DEFAULT"
TEE_ASSET="$TEE_ASSET_DEFAULT"
DO_CLEAN=0
TEE_FILE=""
PIF_FILE=""
PIF_TAG_OVERRIDE=""
PIF_ASSET_OVERRIDE=""
VARIANTS_REQUESTED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tee)        TEE_TAG="$2"; shift 2 ;;
        --tee-asset)  TEE_ASSET="$2"; shift 2 ;;
        --pif)        PIF_TAG_OVERRIDE="$2"; shift 2 ;;
        --pif-asset)  PIF_ASSET_OVERRIDE="$2"; shift 2 ;;
        --tee-file)   TEE_FILE="$2"; shift 2 ;;
        --pif-file)   PIF_FILE="$2"; shift 2 ;;
        --clean)      DO_CLEAN=1; shift ;;
        --variant)    VARIANTS_REQUESTED="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# A stray CR in a pin turns the download URL into "…/v6.0.1-307<CR>/…", which
# curl rejects as malformed — and it is invisible in the build log, since the CR
# just returns the cursor. Strip it rather than debug it again.
strip_cr() { printf '%s' "${1//$'\r'/}"; }
TEE_TAG=$(strip_cr "$TEE_TAG")
TEE_ASSET=$(strip_cr "$TEE_ASSET")

# ---------- Paths ----------
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_SRC="$ROOT/module"
VARIANT_SRC="$ROOT/module-variants"
BUILD="$ROOT/build"
STAGE="$BUILD/stage"
DL="$BUILD/downloads"
OUT="$ROOT/out"

# ---------- Color helpers ----------
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

# ---------- Tool checks ----------
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need unzip
if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fL --retry 3 --connect-timeout 15 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -q -O"
else
    die "need curl or wget"
fi
if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA="shasum -a 256"
else
    yellow "warning: no sha256sum/shasum — skipping hash verification"
    SHA=""
fi

# ---------- Clean ----------
if [[ $DO_CLEAN -eq 1 ]]; then
    bold "==> Cleaning build/"
    rm -rf "$BUILD"
fi

mkdir -p "$DL" "$OUT"

# ---------- Which release lines to build ----------
ALL_VARIANTS=()
for d in "$VARIANT_SRC"/*/; do
    [[ -f "$d/build.conf" ]] && ALL_VARIANTS+=("$(basename "$d")")
done
[[ ${#ALL_VARIANTS[@]} -gt 0 ]] || die "no build lines found under module-variants/"

if [[ -n "$VARIANTS_REQUESTED" ]]; then
    IFS=',' read -r -a VARIANTS <<< "$VARIANTS_REQUESTED"
    for v in "${VARIANTS[@]}"; do
        [[ -f "$VARIANT_SRC/$v/build.conf" ]] \
            || die "unknown --variant '$v' (have: ${ALL_VARIANTS[*]})"
    done
else
    VARIANTS=("${ALL_VARIANTS[@]}")
fi

# --pif / --pif-file name ONE engine, so they only make sense for one line.
if [[ ${#VARIANTS[@]} -gt 1 ]] \
   && [[ -n "$PIF_FILE$PIF_TAG_OVERRIDE$PIF_ASSET_OVERRIDE" ]]; then
    die "--pif/--pif-asset/--pif-file apply to a single line — add --variant fork|inject"
fi

# ---------- zip (or a 7-Zip stand-in) ----------
# Git-Bash / MSYS boxes ship 7-Zip but no Info-ZIP `zip`, which used to stop the
# build dead at the packaging step. Drop a tiny shim on PATH instead — it also
# reaches the -inject sub-build, which runs its own copy of this script.
if ! command -v zip >/dev/null 2>&1; then
    SEVENZ=""
    for c in 7z 7za "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
        if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then SEVENZ="$c"; break; fi
    done
    [[ -n "$SEVENZ" ]] || die "missing required tool: zip (install Info-ZIP, or 7-Zip and re-run)"
    mkdir -p "$BUILD/shim"
    cat > "$BUILD/shim/zip" <<EOF
#!/usr/bin/env bash
# Info-ZIP stand-in backed by 7-Zip. Covers exactly what build.sh calls:
#   zip -qr <out.zip> <path...> [-x <pattern>...]
set -euo pipefail
out=""; paths=()
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -x) shift 2 ;;
        -*) shift ;;
        *)  if [[ -z "\$out" ]]; then out="\$1"; else paths+=("\$1"); fi; shift ;;
    esac
done
[[ -n "\$out" ]] || { echo "zip-shim: no output file" >&2; exit 1; }
command -v cygpath >/dev/null 2>&1 && out="\$(cygpath -w "\$out")"
exec "$SEVENZ" a -tzip -bso0 -bsp0 "-xr!.DS_Store" "\$out" "\${paths[@]}"
EOF
    chmod 755 "$BUILD/shim/zip"
    export PATH="$BUILD/shim:$PATH"
    yellow "    zip not found — packaging with 7-Zip ($SEVENZ)"
fi

# ---------- Download the shared attestation engine ----------
tee_zip="$DL/$TEE_ASSET"

if [[ -n "$TEE_FILE" ]]; then
    [[ -f "$TEE_FILE" ]] || die "--tee-file not found: $TEE_FILE"
    tee_zip="$TEE_FILE"
    green "    local TEE zip: $TEE_FILE"
elif [[ ! -f "$tee_zip" ]]; then
    bold "==> Downloading TEESimulator-RS $TEE_TAG"
    $FETCH "$tee_zip" "https://github.com/Enginex0/TEESimulator-RS/releases/download/$TEE_TAG/$TEE_ASSET" \
        || die "TEESimulator-RS download failed"
else
    green "    cached: $TEE_ASSET"
fi

# NOTE: the KSU WebUI Standalone APK is intentionally NOT bundled. On Magisk /
# APatch the module downloads it fresh from GitHub on the first [Action] press
# (see action.sh) — keeps the package small and always pulls the latest build.

# ---------- Native watcher (Rust, cross-compiled via cargo-ndk) ----------
# Compiles native/watcher/ into prebuilt/<abi>/aswatcher whenever source is
# newer than the binaries (or any binary is missing). Requires Rust + the
# four android targets + cargo-ndk + an Android NDK. If sources are unchanged
# and all four prebuilts exist, we skip — keeps incremental builds fast.

WATCHER_SRC_DIR="$ROOT/native/watcher"
WATCHER_PREBUILT="$WATCHER_SRC_DIR/prebuilt"
WATCHER_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)

watcher_needs_build() {
    [[ -d "$WATCHER_SRC_DIR" ]] || return 1
    for abi in "${WATCHER_ABIS[@]}"; do
        [[ -f "$WATCHER_PREBUILT/$abi/aswatcher" ]] || return 0
    done
    # source newer than any prebuilt binary?
    local newest_src oldest_bin
    newest_src=$(find "$WATCHER_SRC_DIR/src" "$WATCHER_SRC_DIR/Cargo.toml" \
                     -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    oldest_bin=$(find "$WATCHER_PREBUILT" -name aswatcher \
                     -printf '%T@\n' 2>/dev/null | sort -n | head -1)
    [[ -z "$newest_src" || -z "$oldest_bin" ]] && return 0
    awk -v s="$newest_src" -v b="$oldest_bin" 'BEGIN{exit !(s>b)}'
}

# Resolve ANDROID_NDK_HOME from common locations if not exported.
find_ndk() {
    [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]] && return 0
    local cands=()
    [[ -n "${ANDROID_HOME:-}"      ]] && cands+=("$ANDROID_HOME/ndk")
    [[ -n "${ANDROID_SDK_ROOT:-}"  ]] && cands+=("$ANDROID_SDK_ROOT/ndk")
    cands+=( "$HOME/Android/Sdk/ndk" "/opt/android-ndk" )
    # WSL: pick up the Windows-side Android Studio install
    for u in /mnt/c/Users/*/AppData/Local/Android/Sdk/ndk; do
        [[ -d "$u" ]] && cands+=("$u")
    done
    for base in "${cands[@]}"; do
        [[ -d "$base" ]] || continue
        # use the highest-versioned NDK in that dir
        local pick
        pick=$(ls -1 "$base" 2>/dev/null | sort -V | tail -1)
        if [[ -n "$pick" && -d "$base/$pick/toolchains/llvm/prebuilt" ]]; then
            export ANDROID_NDK_HOME="$base/$pick"
            return 0
        fi
    done
    return 1
}

# Every prebuilt present, but no Rust toolchain? Ship the committed binaries and
# say so, instead of failing the whole build. A git checkout rewrites mtimes, so
# "sources are newer" is usually just checkout order, not an actual code change.
have_all_prebuilts() {
    local dir="$1" name="$2"; shift 2
    local abi
    for abi in "$@"; do [[ -f "$dir/$abi/$name" ]] || return 1; done
    return 0
}
toolchain_ready() {
    if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    command -v cargo >/dev/null 2>&1 && command -v cargo-ndk >/dev/null 2>&1 && find_ndk
}

if watcher_needs_build && ! toolchain_ready \
   && have_all_prebuilts "$WATCHER_PREBUILT" aswatcher "${WATCHER_ABIS[@]}"; then
    yellow "    no Rust/NDK toolchain — shipping the committed aswatcher prebuilts"
elif watcher_needs_build; then
    bold "==> Building native watcher (Rust, 4 ABIs)"
    if ! command -v cargo >/dev/null 2>&1; then
        die "cargo not found. Install Rust: https://rustup.rs (then: rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android)"
    fi
    if ! command -v cargo-ndk >/dev/null 2>&1; then
        die "cargo-ndk not found. Install: cargo install cargo-ndk"
    fi
    if ! find_ndk; then
        die "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio (SDK Manager -> NDK)"
    fi
    green "    NDK: $ANDROID_NDK_HOME"
    bash "$ROOT/scripts/build-watcher.sh"
else
    green "    cached: native watcher (4 ABIs in $WATCHER_PREBUILT)"
fi

# ---------- Native fetcher (Rust + rustls, cross-compiled via cargo-ndk) -----
# Same toolchain as the watcher. asfetch gives keybox_fetch/status a real TLS
# stack so downloads work on every device — busybox wget's built-in TLS stalls
# mid-stream on some CDNs (the keybox mirror included) on curl-less devices.
ASFETCH_SRC_DIR="$ROOT/native/asfetch"
ASFETCH_PREBUILT="$ASFETCH_SRC_DIR/prebuilt"
# arm only — asfetch matters on real devices (no curl, busybox TLS stalls).
# x86/x86_64 are emulator-only; there curl/busybox already work, and shipping
# rustls for them would add ~1.9 MB to the zip for no real-device benefit.
ASFETCH_ABIS=(arm64-v8a armeabi-v7a)

asfetch_needs_build() {
    [[ -d "$ASFETCH_SRC_DIR" ]] || return 1
    for abi in "${ASFETCH_ABIS[@]}"; do
        [[ -f "$ASFETCH_PREBUILT/$abi/asfetch" ]] || return 0
    done
    local newest_src oldest_bin
    newest_src=$(find "$ASFETCH_SRC_DIR/src" "$ASFETCH_SRC_DIR/Cargo.toml" \
                     -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    oldest_bin=$(find "$ASFETCH_PREBUILT" -name asfetch \
                     -printf '%T@\n' 2>/dev/null | sort -n | head -1)
    [[ -z "$newest_src" || -z "$oldest_bin" ]] && return 0
    awk -v s="$newest_src" -v b="$oldest_bin" 'BEGIN{exit !(s>b)}'
}

if asfetch_needs_build && ! toolchain_ready \
   && have_all_prebuilts "$ASFETCH_PREBUILT" asfetch "${ASFETCH_ABIS[@]}"; then
    yellow "    no Rust/NDK toolchain — shipping the committed asfetch prebuilts"
elif asfetch_needs_build; then
    bold "==> Building native fetcher (Rust + rustls, 4 ABIs)"
    command -v cargo    >/dev/null 2>&1 || die "cargo not found. Install Rust: https://rustup.rs"
    command -v cargo-ndk >/dev/null 2>&1 || die "cargo-ndk not found. Install: cargo install cargo-ndk"
    find_ndk || die "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio (SDK Manager -> NDK)"
    green "    NDK: $ANDROID_NDK_HOME"
    bash "$ROOT/scripts/build-asfetch.sh"
else
    green "    cached: native fetcher (4 ABIs in $ASFETCH_PREBUILT)"
fi

# ---------- Build one release line ----------
# Everything below runs once per line in $VARIANTS. The line supplies its
# upstream pin and its file lists via module-variants/<line>/build.conf; the
# module scripts it overlays live in module-variants/<line>/ship/.
BUILT_ZIPS=()

build_variant() {
  local VARIANT="$1"
  local VDIR="$VARIANT_SRC/$VARIANT"
  local STAGE="$BUILD/stage-$VARIANT"

  # per-line settings — reset first so one line can never inherit another's
  local ZIP_SUFFIX="" PIF_REPO="" PIF_TAG="" PIF_ASSET="" PIF_ASSET_FILTER=""
  local PIF_FILES="" PIF_REQUIRED="" PIF_PATCH_PATHS="" PATCH_AUTOPIF4_WGET=0
  # Source through a CR-stripped copy: .gitattributes forces LF on build.conf,
  # but an editor or a tarball can still hand us CRLF, and a CR riding inside
  # PIF_TAG turns the download URL into something curl rejects as malformed —
  # invisible in the log, since a CR just returns the cursor.
  mkdir -p "$BUILD"
  tr -d '\r' < "$VDIR/build.conf" > "$BUILD/.build.conf.$VARIANT"
  # shellcheck source=/dev/null
  source "$BUILD/.build.conf.$VARIANT"
  rm -f "$BUILD/.build.conf.$VARIANT"
  [[ -n "$PIF_TAG_OVERRIDE"   ]] && PIF_TAG="$PIF_TAG_OVERRIDE"
  [[ -n "$PIF_ASSET_OVERRIDE" ]] && PIF_ASSET="$PIF_ASSET_OVERRIDE"
  [[ -n "$PIF_REPO" && -n "$PIF_TAG" && -n "$PIF_ASSET" ]] \
      || die "$VARIANT: build.conf is missing PIF_REPO / PIF_TAG / PIF_ASSET"

  bold ""
  bold "==> Building the '$VARIANT' line ($PIF_REPO $PIF_TAG)"

  # ---------- Download this line's Play Integrity engine ----------
  local pif_zip="$DL/$PIF_ASSET"
  if [[ -n "$PIF_FILE" ]]; then
      [[ -f "$PIF_FILE" ]] || die "--pif-file not found: $PIF_FILE"
      pif_zip="$PIF_FILE"
      green "    local PIF zip: $PIF_FILE"
  elif [[ ! -f "$pif_zip" ]]; then
      bold "==> Downloading $PIF_REPO $PIF_TAG"
      $FETCH "$pif_zip" "https://github.com/$PIF_REPO/releases/download/$PIF_TAG/$PIF_ASSET" \
          || die "$PIF_REPO download failed"
  else
      green "    cached: $PIF_ASSET"
  fi

# ---------- Stage layout ----------
bold "==> Staging module files"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 1) Our scripts/configs (the glue). These override anything from upstream.
cp -a "$MODULE_SRC/." "$STAGE/"

# 1a) Overlay this line's own files (engine.sh, description.txt, ...) on top.
if [[ -d "$VDIR/ship" ]]; then
    cp -a "$VDIR/ship/." "$STAGE/"
    green "    overlaid module-variants/$VARIANT/ship/"
fi

# 1a2) Apply this line's module.prop overrides. version / versionCode are NOT
#      overridable — they are defined once, in module/module.prop, so the two
#      lines can never drift apart on the number users see.
if [[ -f "$VDIR/module.prop.override" ]]; then
    # Rewritten with awk, not sed: the replacement text is a description string,
    # and in a sed replacement `&` expands to the whole match and `\` escapes —
    # so a perfectly reasonable description would silently corrupt module.prop.
    # awk takes the line as a variable and never reinterprets it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        local k="${line%%=*}"
        case "$k" in
            version|versionCode|id)
                die "$VARIANT/module.prop.override may not override '$k'" ;;
        esac
        grep -q "^${k}=" "$STAGE/module.prop" \
            || die "$VARIANT/module.prop.override sets unknown key '$k'"
        awk -v key="$k=" -v repl="$line" \
            'index($0, key) == 1 { print repl; next } { print }' \
            "$STAGE/module.prop" > "$STAGE/module.prop.new" \
            && mv "$STAGE/module.prop.new" "$STAGE/module.prop"
    done < "$VDIR/module.prop.override"
    green "    applied module.prop overrides"
fi

# 1b) Ship banner.png inside the module so the manager shows it locally
#     (module.prop: banner=/data/adb/modules/tricky_store/banner.png) instead of
#     hot-linking raw.githubusercontent.com. customize.sh extracts it on install.
if [[ -f "$ROOT/banner.png" ]]; then
    cp "$ROOT/banner.png" "$STAGE/banner.png"
    green "    bundled banner.png ($(du -h "$ROOT/banner.png" | cut -f1))"
else
    yellow "    warning: banner.png not found at repo root — module banner will be missing"
fi

# 2) Extract TEESimulator-RS binaries. We take:
#      - lib/<abi>/lib*.so (all four arches)
#      - classes.dex (renamed to tee_classes.dex to coexist with PIF's classes.dex)
#      - keybox.xml (default AOSP, only used if user has none)
#    We do NOT take its customize.sh/service.sh/post-fs-data.sh/action.sh — ours replace them.
TEE_EXTRACT="$BUILD/tee_extracted"
rm -rf "$TEE_EXTRACT"
mkdir -p "$TEE_EXTRACT"
unzip -qq -o "$tee_zip" -d "$TEE_EXTRACT"

mkdir -p "$STAGE/lib"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    if [[ -d "$TEE_EXTRACT/lib/$abi" ]]; then
        mkdir -p "$STAGE/lib/$abi"
        cp "$TEE_EXTRACT/lib/$abi"/*.so "$STAGE/lib/$abi/"
    fi
done

[[ -f "$TEE_EXTRACT/classes.dex" ]] || die "TEESimulator ZIP missing classes.dex"
cp "$TEE_EXTRACT/classes.dex" "$STAGE/tee_classes.dex"

[[ -f "$TEE_EXTRACT/keybox.xml" ]] && cp "$TEE_EXTRACT/keybox.xml" "$STAGE/keybox.xml"

# 3) Extract this line's Play Integrity engine: zygisk libs, classes.dex (PIF's,
#    stays as classes.dex) and the upstream helper scripts named by $PIF_FILES.
PIF_EXTRACT="$BUILD/pif_extracted-$VARIANT"
rm -rf "$PIF_EXTRACT"
mkdir -p "$PIF_EXTRACT"
unzip -qq -o "$pif_zip" -d "$PIF_EXTRACT"

mkdir -p "$STAGE/zygisk"
cp "$PIF_EXTRACT/zygisk"/*.so "$STAGE/zygisk/" 2>/dev/null || die "PIF zygisk libs missing"

[[ -f "$PIF_EXTRACT/classes.dex" ]] || die "PIF ZIP missing classes.dex"
cp "$PIF_EXTRACT/classes.dex" "$STAGE/classes.dex"

for f in $PIF_FILES; do
    if [[ -f "$PIF_EXTRACT/$f" ]]; then
        cp "$PIF_EXTRACT/$f" "$STAGE/$f"
    fi
done
# A silently-missing helper means the fingerprint refresh does nothing at run
# time, which is invisible until someone's verdict quietly drops. Fail here.
for f in $PIF_REQUIRED; do
    [[ -f "$STAGE/$f" ]] \
        || die "$VARIANT: PIF zip has no $f — upstream layout changed, update module-variants/$VARIANT/build.conf"
done

# 4) Stage the Rust watcher + fetcher binaries (built/cached above).
mkdir -p "$STAGE/bin"
for abi in "${WATCHER_ABIS[@]}"; do
    src="$WATCHER_PREBUILT/$abi/aswatcher"
    [[ -f "$src" ]] || die "aswatcher binary missing for $abi (build step failed?)"
    mkdir -p "$STAGE/bin/$abi"
    cp "$src" "$STAGE/bin/$abi/aswatcher"
    chmod 755 "$STAGE/bin/$abi/aswatcher"
done
for abi in "${ASFETCH_ABIS[@]}"; do
    src="$ASFETCH_PREBUILT/$abi/asfetch"
    [[ -f "$src" ]] || die "asfetch binary missing for $abi (build step failed?)"
    mkdir -p "$STAGE/bin/$abi"
    cp "$src" "$STAGE/bin/$abi/asfetch"
    chmod 755 "$STAGE/bin/$abi/asfetch"
done

# 5) Rewrite hard-coded /data/adb/modules/playintegrityfix references in PIF scripts
#    to our module id (tricky_store). Done in-place on copies inside the stage.
bold "==> Patching PIF script paths -> /data/adb/modules/tricky_store"
for f in $PIF_PATCH_PATHS; do
    f="$STAGE/$f"
    [[ -f "$f" ]] || continue
    # Linux/macOS sed compat
    if sed --version >/dev/null 2>&1; then
        SED_I=(sed -i)
    else
        SED_I=(sed -i '')
    fi
    "${SED_I[@]}" 's|/data/adb/modules/playintegrityfix|/data/adb/modules/tricky_store|g' "$f"
done

# Bound autopif4's wget calls so a hung IPv6 connect doesn't stall the whole
# bootstrap. Use the short -T (timeout, seconds) option ONLY: it's the single
# flag that toybox wget, busybox wget AND GNU wget all accept. The long forms
# (--timeout / --tries) are NOT in toybox wget, and --tries isn't in busybox
# wget either — injecting them makes every fetch error out with "unknown
# option" and the fingerprint refresh silently fails.
if [[ "$PATCH_AUTOPIF4_WGET" == "1" && -f "$STAGE/autopif4.sh" ]]; then
    bold "==> Patching autopif4.sh: wget -T 10"
    "${SED_I[@]}" 's|wget -q |wget -q -T 10 |g' "$STAGE/autopif4.sh"

    # autopif4 only falls back to busybox wget when the system wget is missing
    # or is the wget-curl shim. On a Pixel the toybox wget exists but lacks the
    # --no-check-certificate / --header / --spider options autopif4 relies on,
    # so the crawl dies. Magisk/KSU/APatch always ship a busybox that supports
    # all of them — prefer it whenever present.
    bold "==> Patching autopif4.sh: prefer busybox wget"
    perl -0777 -pi -e 's{if ! which wget >/dev/null \|\| grep -q "wget-curl" \$\(which wget\); then}{if find_busybox; then wget() { \$BUSYBOX wget "\$\@"; }; elif ! which wget >/dev/null || grep -q "wget-curl" \$(which wget); then}' "$STAGE/autopif4.sh" \
        && grep -q 'if find_busybox; then wget()' "$STAGE/autopif4.sh" \
        && green "    busybox-wget preference applied" \
        || yellow "    warning: could not apply busybox-wget preference (autopif4 layout changed?)"
fi

# 5b) Binary-patch the PIF zygisk .so libraries so they read classes.dex and
#     pif config from OUR module dir (/data/adb/modules/tricky_store) instead
#     of the upstream-hardcoded /data/adb/modules/playintegrityfix. This is
#     what lets us drop the old symlink-shim that created a stray
#     playintegrityfix folder under /data/adb/modules.
#
#     Length-preserving + filename-agnostic: we only rewrite the directory
#     prefix, padding the freed bytes with extra '/' (collapsed by the kernel)
#     or NUL (truncates the C string at the right spot). The trailing filename
#     ("/classes.dex", "/pif.json", …) is left untouched.
#       "/data/adb/modules/playintegrityfix/" (35B) -> ".../tricky_store/////" (35B)
#       "/data/adb/modules/playintegrityfix\0" (35B) -> ".../tricky_store\0\0\0\0\0" (35B)
bold "==> Binary-patching PIF zygisk path -> /data/adb/modules/tricky_store"
if command -v perl >/dev/null 2>&1; then
    SO_PATCH() {
        perl -0777 -pi -e '
            s{/data/adb/modules/playintegrityfix/}{/data/adb/modules/tricky_store/////}g;
            s{/data/adb/modules/playintegrityfix\x00}{/data/adb/modules/tricky_store\x00\x00\x00\x00\x00}g;
        ' "$1"
    }
elif command -v python3 >/dev/null 2>&1; then
    SO_PATCH() {
        python3 - "$1" <<'PY'
import sys
p=sys.argv[1]
d=open(p,'rb').read()
d=d.replace(b'/data/adb/modules/playintegrityfix/', b'/data/adb/modules/tricky_store/////')
d=d.replace(b'/data/adb/modules/playintegrityfix\x00', b'/data/adb/modules/tricky_store\x00\x00\x00\x00\x00')
open(p,'wb').write(d)
PY
    }
else
    die "need perl or python3 to binary-patch the PIF zygisk libraries"
fi
for so in "$STAGE/zygisk"/*.so; do
    [[ -f "$so" ]] || continue
    SO_PATCH "$so"
    new_refs=$(grep -ac "modules/tricky_store" "$so" 2>/dev/null) || new_refs=0
    green "    $(basename "$so"): tricky_store path refs=$new_refs"
done

# --- Hard guard: ONE module, never a stray playintegrityfix folder ---------
# After patching, NO shipped .so or PIF helper script may point at any
# /data/adb/modules/<name> other than tricky_store. If a future upstream bump
# renames or restructures PIF's hardcoded path, the byte-patch / sed silently
# misses it and PIF would recreate its own module folder under
# /data/adb/modules — exactly what we forbid. Fail the build loudly instead of
# shipping that, so an incompatible bump can never slip through unnoticed.
bold "==> Verifying PIF stays inside tricky_store (no stray module folder)"
for so in "$STAGE/zygisk"/*.so; do
    [[ -f "$so" ]] || continue
    stray=$(grep -aoE '/data/adb/modules/[A-Za-z0-9_.-]+' "$so" 2>/dev/null \
            | grep -vxF '/data/adb/modules/tricky_store' | sort -u || true)
    if [[ -n "$stray" ]]; then
        red "    $(basename "$so") references a foreign module path:"
        printf '      %s\n' $stray
        die "zygisk byte-patch incomplete — upstream changed PIF's hardcoded path. Update SO_PATCH in build.sh before shipping."
    fi
done
for f in $PIF_PATCH_PATHS; do
    [[ -f "$STAGE/$f" ]] || continue
    if grep -qF 'modules/playintegrityfix' "$STAGE/$f"; then
        die "$f still references modules/playintegrityfix after sed patch — upstream layout changed; fix the path patch in build.sh."
    fi
done
green "    ok — PIF reads only /data/adb/modules/tricky_store"

# 6) Normalize line endings on every shell/text script that ships to the device.
#    Android /system/bin/sh treats `\r` as part of arguments — a CRLF customize.sh
#    fails with cryptic "no such file" errors. Strip CR from anything text-like.
bold "==> Normalizing line endings (LF) on shipped scripts"
for f in "$STAGE"/*.sh "$STAGE"/*.prop "$STAGE/daemon" "$STAGE/module.prop" \
         "$STAGE/target.txt" "$STAGE/description.txt" "$STAGE/sepolicy.rule" \
         "$STAGE/META-INF/com/google/android/update-binary" \
         "$STAGE/META-INF/com/google/android/updater-script"; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

# 7) Ensure executable bits on shell scripts, TEE daemon, native binaries
chmod 755 "$STAGE/daemon" "$STAGE"/*.sh 2>/dev/null || true
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    [[ -f "$STAGE/bin/$abi/aswatcher" ]] && chmod 755 "$STAGE/bin/$abi/aswatcher"
    [[ -f "$STAGE/bin/$abi/asfetch" ]]   && chmod 755 "$STAGE/bin/$abi/asfetch"
done

# Note: webroot/ (KSU/APatch/MMRL WebUI) gets staged automatically by step 1's
# cp -a — no extra step needed. KSU/APatch detect the dir at runtime and
# show an "Open Web UI" entry next to the module.

# ---------- Generate ZIP ----------
  local VERSION OUT_ZIP
  VERSION=$(grep '^version=' "$STAGE/module.prop" | cut -d= -f2)
  OUT_ZIP="$OUT/AlwaysStrong-${VERSION}${ZIP_SUFFIX}.zip"
  rm -f "$OUT_ZIP"

  bold "==> Packaging $OUT_ZIP"
  ( cd "$STAGE" && zip -qr "$OUT_ZIP" . -x "*.DS_Store" )
  BUILT_ZIPS+=("$OUT_ZIP")
}

# ---------- Run every requested line ----------
for v in "${VARIANTS[@]}"; do
    build_variant "$v"
done

# ---------- Summary ----------
summarize() {
    local zip="$1"
    green "  Built: $(basename "$zip")  ($(du -h "$zip" | cut -f1))"
    green "  Path:  $zip"
    if [[ -n "$SHA" ]]; then
        green "  SHA256: $($SHA "$zip" | awk '{print $1}')"
    fi
}
green ""
for z in "${BUILT_ZIPS[@]}"; do
    summarize "$z"
    green ""
done
