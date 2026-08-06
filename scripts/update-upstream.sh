#!/usr/bin/env bash
# Check (and optionally apply) the latest upstream releases for every part of
# AlwaysStrong: the shared TEESimulator-RS pin in build.sh, plus each release
# line's own Play Integrity pin in module-variants/<line>/build.conf.
#
# Usage:
#   scripts/update-upstream.sh                   # dry-run, report what is newer
#   scripts/update-upstream.sh --apply           # bump the pins
#   scripts/update-upstream.sh --apply --build   # bump, then rebuild everything
#   scripts/update-upstream.sh --stable-only     # ignore prereleases
#
# Prereleases count by default: TEESimulator-RS ships its newest builds that way
# (the "CI build" posted in the channel), and /releases/latest hides them, so a
# check that skipped prereleases would sit on a stale engine and call it current.
#
# Set GH_TOKEN (or GITHUB_TOKEN) to authenticate the API calls: unauthenticated
# CI runners share a 60 req/h pool per IP and run into the limit.
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
VARIANT_SRC="$ROOT/module-variants"

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
    # name we care about. Repos that publish several variants per release are
    # narrowed by $2; TEE ships Debug + Release, so we ask for "Release".
    # Drafts are always skipped.
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
prefer = '$prefer'
rels = [r for r in raw if not r['draft'] and (allow_pre or not r['prerelease'])]
def assets(r):
    # newest upload first, so a re-cut revision within one tag (e.g.
    # PlayIntegrityFix_v4.7-1-inject-s.zip replacing …_v4.7-inject-s.zip) wins
    # instead of whichever order the API happened to return
    a = sorted((x for x in r.get('assets', []) if x['name'].endswith('.zip')),
               key=lambda x: x.get('created_at', ''), reverse=True)
    n = [x['name'] for x in a]
    return [x for x in n if prefer in x] or ([] if prefer else n)
rels = [r for r in rels if assets(r)]
if not rels:
    sys.exit('no release with a matching .zip asset in ${repo}')
rel = max(rels, key=lambda r: r['published_at'])
print(rel['tag_name'])
print(assets(rel)[0])
print('prerelease' if rel['prerelease'] else 'stable')
" | tr -d '\r'
    # ^ Windows Python writes CRLF and a read strips only the LF, so without this
    # the CR ends up inside the quotes of the pin it patches
    # (PIF_TAG="v4.7-inject-s<CR>") and the download URL dies as malformed.
}

# read_kv FILE KEY — the quoted value of a KEY="..." assignment
read_kv() { sed -n "s/^$2=\"\{0,1\}//p" "$1" | head -1 | sed 's/"$//'; }

# patch_kv FILE KEY VALUE
patch_kv() {
    local file="$1" key="$2" val="${3//$'\r'/}"
    grep -qE "^${key}=" "$file" || return 0
    sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$file" && rm -f "$file.bak"
}

CHANGED=0
FAILED=0

echo '==> Querying upstream GitHub releases'

# ---------------------------------------------- shared attestation engine ----
if TEE_OUT=$(api_latest "Enginex0/TEESimulator-RS" "Release"); then
    TEE_TAG_NEW=$(sed -n 1p <<<"$TEE_OUT")
    TEE_ASSET_NEW=$(sed -n 2p <<<"$TEE_OUT")
    TEE_KIND=$(sed -n 3p <<<"$TEE_OUT")
    TEE_TAG_CUR=$(read_kv "$BUILD_SH" TEE_TAG_DEFAULT)
    TEE_ASSET_CUR=$(read_kv "$BUILD_SH" TEE_ASSET_DEFAULT)

    if [[ "$TEE_TAG_CUR" == "$TEE_TAG_NEW" && "$TEE_ASSET_CUR" == "$TEE_ASSET_NEW" ]]; then
        echo "    TEE            $TEE_TAG_CUR (up to date, $TEE_KIND)"
    else
        echo "    TEE            $TEE_TAG_CUR  ->  $TEE_TAG_NEW   ($TEE_ASSET_NEW, $TEE_KIND)"
        CHANGED=1
        if [[ $APPLY -eq 1 ]]; then
            patch_kv "$BUILD_SH" TEE_TAG_DEFAULT   "$TEE_TAG_NEW"
            patch_kv "$BUILD_SH" TEE_ASSET_DEFAULT "$TEE_ASSET_NEW"
        fi
    fi
else
    echo "    TEE            lookup failed" >&2
    FAILED=1
fi

# ------------------------------------ each release line's own PIF engine ----
# Compare the TAG only. Repos like KOWX712/PlayIntegrityFix re-cut assets within
# one tag (…-1-inject-s.zip), and chasing the asset name would open a PR on
# every re-upload, so a pinned revision stays pinned until the tag itself moves.
for conf in "$VARIANT_SRC"/*/build.conf; do
    [[ -f "$conf" ]] || continue
    line=$(basename "$(dirname "$conf")")
    repo=$(read_kv "$conf" PIF_REPO)
    tag_cur=$(read_kv "$conf" PIF_TAG)
    filter=$(read_kv "$conf" PIF_ASSET_FILTER)
    [[ -n "$repo" && -n "$tag_cur" ]] || { echo "    $line: build.conf incomplete" >&2; FAILED=1; continue; }

    if ! out=$(api_latest "$repo" "$filter"); then
        printf '    %-14s lookup failed (%s)\n' "$line" "$repo" >&2
        FAILED=1
        continue
    fi
    tag_new=$(sed -n 1p <<<"$out")
    asset_new=$(sed -n 2p <<<"$out")
    kind=$(sed -n 3p <<<"$out")

    if [[ "$tag_cur" == "$tag_new" ]]; then
        printf '    %-14s %s (up to date, %s, %s)\n' "$line" "$tag_cur" "$repo" "$kind"
    else
        printf '    %-14s %s  ->  %s   (%s, %s)\n' "$line" "$tag_cur" "$tag_new" "$asset_new" "$kind"
        CHANGED=1
        if [[ $APPLY -eq 1 ]]; then
            patch_kv "$conf" PIF_TAG   "$tag_new"
            patch_kv "$conf" PIF_ASSET "$asset_new"
        fi
    fi
done

[[ $FAILED -eq 1 ]] && exit 1

if [[ $CHANGED -eq 0 ]]; then
    echo '==> Up to date.'
    exit 0
fi

if [[ $APPLY -eq 0 ]]; then
    echo '==> Updates available. Re-run with --apply to bump the pins.'
    exit 10
fi

echo '==> Patched.'

if [[ $DO_BUILD -eq 1 ]]; then
    echo '==> Re-running build.sh --clean'
    bash "$BUILD_SH" --clean
fi

exit 11
