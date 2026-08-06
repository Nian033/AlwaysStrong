#!/usr/bin/env bash
# Check (and optionally apply) latest TEESimulator-RS and PlayIntegrityFork releases.
#
# Usage:
#   scripts/update-upstream.sh            # dry-run, print whether anything is newer
#   scripts/update-upstream.sh --apply    # bump build.sh pinned tags to latest
#   scripts/update-upstream.sh --apply --build   # also re-run build.sh after patching
#   scripts/update-upstream.sh --stable-only     # ignore prereleases
#
# Prereleases COUNT by default. TEESimulator-RS ships its newest builds as
# prereleases (the "CI build" posted in the channel) — /releases/latest hides
# those, which is why this used to report "up to date" against a newer upstream.
#
# Set GH_TOKEN (or GITHUB_TOKEN) to authenticate the API calls: unauthenticated
# CI runners share a 60 req/h pool per IP and were getting rate-limited.
#
# Exit codes:
#   0  nothing to update
#   1  error
#  10  updates available (dry-run only)
#  11  updates applied

set -euo pipefail

APPLY=0
DO_BUILD=0
ALLOW_PRE=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --build) DO_BUILD=1; shift ;;
        --stable-only) ALLOW_PRE=0; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
else echo "missing: python3" >&2; exit 1
fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
CURL_AUTH=()
[[ -n "$TOKEN" ]] && CURL_AUTH=(-H "Authorization: Bearer $TOKEN")

api_latest() {
    # Newest release (prereleases included unless --stable-only) plus the asset
    # name we care about. PIF ships one .zip per release; TEE ships Debug +
    # Release — we always pick the Release one. Drafts are always skipped.
    local repo="$1" prefer="$2"
    curl -sSL --retry 2 --max-time 30 "${CURL_AUTH[@]}" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases?per_page=20" \
    | "$PY" -c "
import json, sys
raw = json.load(sys.stdin)
if isinstance(raw, dict):                       # rate limit / 404 -> {'message': ...}
    sys.exit('github api: ' + raw.get('message', 'unexpected response'))
allow_pre = '$ALLOW_PRE' == '1'
rels = [r for r in raw if not r['draft'] and (allow_pre or not r['prerelease'])]
rels = [r for r in rels if any(a['name'].endswith('.zip') for a in r.get('assets', []))]
if not rels:
    sys.exit('no release with a .zip asset in ${repo}')
rel = max(rels, key=lambda r: r['published_at'])
names = [a['name'] for a in rel['assets'] if a['name'].endswith('.zip')]
prefer = '$prefer'
print(rel['tag_name'])
print(next((n for n in names if prefer and prefer in n), names[0]))
print('prerelease' if rel['prerelease'] else 'stable')
" | tr -d '\r'
    # ^ Windows Python writes CRLF. mapfile -t only strips the LF, so the CR rode
    # along into the value and got baked INSIDE the quotes in build.sh
    # (TEE_TAG_DEFAULT="v6.0.1-307<CR>"). Downloads then died on a malformed URL.
}

current_value() {
    grep -E "^$1=" "$BUILD_SH" | head -1 | cut -d= -f2- | tr -d '\"'
}

echo '==> Querying upstream GitHub releases'
mapfile -t TEE < <(api_latest "Enginex0/TEESimulator-RS" "Release")
mapfile -t PIF < <(api_latest "osm0sis/PlayIntegrityFork" "")

TEE_TAG_NEW="${TEE[0]}"; TEE_ASSET_NEW="${TEE[1]}"; TEE_KIND="${TEE[2]:-}"
PIF_TAG_NEW="${PIF[0]}"; PIF_ASSET_NEW="${PIF[1]}"; PIF_KIND="${PIF[2]:-}"

[[ -n "$TEE_TAG_NEW" && -n "$TEE_ASSET_NEW" ]] || { echo "TEE lookup failed" >&2; exit 1; }
[[ -n "$PIF_TAG_NEW" && -n "$PIF_ASSET_NEW" ]] || { echo "PIF lookup failed" >&2; exit 1; }

TEE_TAG_CUR=$(current_value TEE_TAG_DEFAULT)
TEE_ASSET_CUR=$(current_value TEE_ASSET_DEFAULT)
PIF_TAG_CUR=$(current_value PIF_TAG_DEFAULT)
PIF_ASSET_CUR=$(current_value PIF_ASSET_DEFAULT)

echo "    TEE: $TEE_TAG_CUR  ->  $TEE_TAG_NEW   ($TEE_ASSET_NEW, $TEE_KIND)"
echo "    PIF: $PIF_TAG_CUR  ->  $PIF_TAG_NEW   ($PIF_ASSET_NEW, $PIF_KIND)"

# --- the other release line -------------------------------------------------
# build.sh emits BOTH zips from one run, but each line pins its own upstream in
# its own branch's build.sh — so checking only this branch silently leaves the
# sibling on a stale engine. Report it here (read-only: patching another branch
# from a working tree you are not on is how you lose edits) and say how to apply.
sibling_report() {
    local ref sib_build sib_repo sib_tag sib_prefer
    if grep -q 'KOWX712/PlayIntegrityFix' "$BUILD_SH"; then ref=main; else ref=inject; fi
    git -C "$ROOT" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || return 0

    sib_build=$(git -C "$ROOT" show "${ref}:build.sh" 2>/dev/null) || return 0
    # the PIF download line specifically — TEE's URL sits above it in build.sh
    sib_repo=$(printf '%s' "$sib_build" \
        | grep -F 'releases/download/$PIF_TAG' \
        | grep -oE 'github\.com/[^/]+/[^/]+/releases/download' | head -1 \
        | cut -d/ -f2,3)
    sib_tag=$(printf '%s' "$sib_build" | sed -n 's/^PIF_TAG_DEFAULT="\(.*\)"/\1/p' | head -1)
    [[ -n "$sib_repo" && -n "$sib_tag" ]] || return 0
    case "$sib_repo" in *PlayIntegrityFix*) sib_prefer=inject-s ;; *) sib_prefer="" ;; esac

    local out
    out=$(api_latest "$sib_repo" "$sib_prefer") || return 0
    local new_tag
    new_tag=$(printf '%s' "$out" | sed -n 1p | tr -d '\r')
    [[ -n "$new_tag" ]] || return 0

    if [[ "$sib_tag" == "$new_tag" ]]; then
        echo "    $ref line: $sib_tag (up to date, $sib_repo)"
    else
        echo "    $ref line: $sib_tag  ->  $new_tag   ($sib_repo)"
        echo "               apply with: git checkout $ref && scripts/update-upstream.sh --apply"
    fi
}
sibling_report

CHANGED=0
[[ "$TEE_TAG_CUR" != "$TEE_TAG_NEW" || "$TEE_ASSET_CUR" != "$TEE_ASSET_NEW" ]] && CHANGED=1
[[ "$PIF_TAG_CUR" != "$PIF_TAG_NEW" || "$PIF_ASSET_CUR" != "$PIF_ASSET_NEW" ]] && CHANGED=1

if [[ $CHANGED -eq 0 ]]; then
    echo '==> Up to date.'
    exit 0
fi

if [[ $APPLY -eq 0 ]]; then
    echo '==> Updates available. Re-run with --apply to bump build.sh to the new tags.'
    exit 10
fi

echo '==> Patching pinned versions'
patch_kv() {
    local file="$1" key="$2" val="${3//$'\r'/}"
    if grep -qE "^${key}=" "$file"; then
        sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$file" && rm -f "$file.bak"
    fi
}

patch_kv "$BUILD_SH" TEE_TAG_DEFAULT     "$TEE_TAG_NEW"
patch_kv "$BUILD_SH" TEE_ASSET_DEFAULT   "$TEE_ASSET_NEW"
patch_kv "$BUILD_SH" PIF_TAG_DEFAULT     "$PIF_TAG_NEW"
patch_kv "$BUILD_SH" PIF_ASSET_DEFAULT   "$PIF_ASSET_NEW"

echo '==> Patched.'

if [[ $DO_BUILD -eq 1 ]]; then
    echo '==> Re-running build.sh --clean'
    bash "$BUILD_SH" --clean
fi

exit 11
