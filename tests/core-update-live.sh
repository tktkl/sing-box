#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
export SB_ROOT
SB_ROOT=$(mktemp -d /tmp/sb-core-live.XXXXXXXX)
export SB_CORE="$SB_ROOT/core/sing-box" SB_SERVICE_MODE=none
trap cleanup_root EXIT
mkdir -p "$SB_ROOT/core" "$SB_ROOT/rules" "$SB_ROOT/run"
cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
previous=$(jq -r .previous_version "$SB_HOME/tests/core-update.lock.json")
arch=$(dpkg --print-architecture)
asset="sing-box-$previous-linux-$arch.tar.gz"
digest=$(jq -r --arg arch "$arch" '.archives[$arch]' "$SB_HOME/tests/core-update.lock.json")
url="https://github.com/SagerNet/sing-box/releases/download/v$previous/$asset"
core_extract "$previous" "$asset" "$url" "$digest" "$SB_CORE"
jq -n --arg version "$previous" --arg asset "$asset" --arg url "$url" --arg digest "$digest" \
    '{version:$version,asset:$asset,url:$url,archive_sha256:$digest}' > "$SB_ROOT/run/previous-asset.json"
core_install_metadata "$SB_ROOT/run/previous-asset.json" "$SB_CORE"
"$CLI" init --address 127.0.0.1
export SB_SERVICE_MODE=process
node=$("$CLI" add ss 28261 auto aes-256-gcm)
id=$(jq -r .id <<< "$node")
cp "$SB_ROOT/current/nodes/$id.json" "$SB_ROOT/run/expected-node.json"
before=$(hash_file "$SB_CORE")
generation=$(readlink "$SB_ROOT/current")
pid=$(cat "$SB_ROOT/run/core.pid")
"$CLI" update core --check
[[ $(hash_file "$SB_CORE") == "$before" && $(readlink "$SB_ROOT/current") == "$generation" && $(cat "$SB_ROOT/run/core.pid") == "$pid" ]]
printf 'LIVE CHECK-ONLY PRESERVED OLD BINARY AND SERVICE\n'
"$CLI" update core
current=$(core_binary_version "$SB_CORE")
[[ $(printf '%s\n' "$previous" "$current" | sort -V | head -n1) == "$previous" && $current != "$previous" ]]
service_active core
cmp "$SB_ROOT/run/expected-node.json" "$SB_ROOT/current/nodes/$id.json"
jq -e '.phase=="committed"' "$SB_ROOT/core-update.json" >/dev/null
"$CLI" port "$id" 28262
port_is_listening 28262
"$CLI" update core --check
printf 'OFFICIAL CORE CROSS-VERSION UPGRADE PASSED: %s -> %s\n' "$previous" "$current"
