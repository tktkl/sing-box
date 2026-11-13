#!/usr/bin/env bash
set -Eeuo pipefail
export SB_HOME=${SB_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
export SB_CORE=${SB_CORE:-/usr/local/bin/sb-core}
export SB_SERVICE_MODE=none
for module in common links render service state certificates nodes maintenance install import ui cli; do source "$SB_HOME/lib/$module.sh"; done
CLI="$SB_HOME/bin/sb"
fresh_root() {
    export SB_ROOT
    SB_ROOT=$(mktemp -d /tmp/sb-test.XXXXXXXX)
    export SB_SERVICE_MODE=none
    mkdir -p "$SB_ROOT/rules"
    cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
    "$CLI" init --address 127.0.0.1 >/dev/null
}
assert_jq() { jq -e "$2" <<< "$1" >/dev/null || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; }
must_fail() {
    local output
    output=$(mktemp)
    if ( "$@" ) >"$output" 2>&1; then printf 'FAIL: expected rejection\n' >&2; rm -f "$output"; exit 1; fi
    rm -f "$output"
}
pass() { printf 'PASS %s\n' "$*"; }
cleanup_root() { [[ ${SB_SERVICE_MODE:-none} == none ]] || { service_action core stop || true; service_action nginx stop || true; }; [[ ! -d ${SB_ROOT:-/nonexistent} ]] || rm -rf "$SB_ROOT"; }
