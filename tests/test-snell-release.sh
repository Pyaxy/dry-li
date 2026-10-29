#!/bin/sh
# Offline release-parser tests; no package, service or network operations.
# shellcheck source-path=SCRIPTDIR
set -eu
TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SNELL_LOWSPACE_LIB_ONLY=1
# shellcheck source=../public/snell-alpine/snell-alpine-lowspace.sh
. "$TEST_DIR/../public/snell-alpine/snell-alpine-lowspace.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
assert_eq() { [ "$1" = "$2" ] || { printf 'FAIL: %s (%s != %s)\n' "$3" "$1" "$2" >&2; exit 1; }; }

RELEASE_FIXTURE='https://dl.nssurge.com/snell/snell-server-v6.0.0-linux-amd64.zip
### v6.0.0
### v5.0.1
### v5.0.0
### v4.1.1'
assert_eq "$(printf '%s\n' "$RELEASE_FIXTURE" | snell_version_from_notes v5)" 5.0.1 'v5 heading without v5 download links'
assert_eq "$(printf '%s\n' "$RELEASE_FIXTURE" | snell_version_from_notes v4)" 4.1.1 'channel isolation'
assert_eq "$(printf '%s\n' '<h3 id="v5.1.0"><span>v5.1.0</span></h3><h3>v5.0.1</h3>' | snell_version_from_notes v5)" 5.1.0 'HTML headings'
assert_eq "$(printf '%s\n' 'snell-server-v5.9.0-linux-amd64.zip snell-server-v5.10.0-linux-aarch64.zip' | snell_version_from_notes v5)" 5.10.0 'numeric version order and multiple links'
assert_eq "$(printf '%s\n' '### v6.0.0rc2' '### v6.0.0rc10' | snell_version_from_notes v6)" 6.0.0rc10 'RC ordering'
assert_eq "$(printf '%s\n' '### v6.0.0rc10' '### v6.0.0' | snell_version_from_notes v6)" 6.0.0 'final release after RC'
printf 'PASS: release headings, HTML, asset links, channel isolation and semantic ordering\n'

mode=markdown
curl() {
    for curl_url do :; done
    printf '%s\n' "$curl_url" >> "$TMP_DIR/requests"
    case "$mode:$curl_url" in
        markdown:*.md) printf '%s\n' "$RELEASE_FIXTURE" ;;
        html:*.md) return 22 ;;
        html:*) printf '<h3>v5.0.1</h3>\n' ;;
        missing:*) printf '### v6.0.0\n' ;;
        offline:*) return 6 ;;
        *) return 1 ;;
    esac
}
: > "$TMP_DIR/requests"
assert_eq "$(latest_snell_version v5 v5.0.0 2> "$TMP_DIR/message")" v5.0.1 'Markdown fetch'
assert_eq "$(wc -l < "$TMP_DIR/requests" | tr -d ' ')" 1 'unnecessary HTML fetch'
mode=html
assert_eq "$(latest_snell_version v5 v5.0.0 2> "$TMP_DIR/message")" v5.0.1 'HTML fallback'
mode=missing
assert_eq "$(latest_snell_version v5 v5.0.0 2> "$TMP_DIR/message")" v5.0.0 'missing version fallback'
grep -q '未找到 v5 版本' "$TMP_DIR/message"
mode=offline
assert_eq "$(latest_snell_version v5 v5.0.0 2> "$TMP_DIR/message")" v5.0.0 'network fallback'
grep -q '网络或 HTTP 错误' "$TMP_DIR/message"
printf 'PASS: Markdown preferred, HTML retry, missing version and network failure diagnostics\n'
