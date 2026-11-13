#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
trap cleanup_root EXIT
REAL_CORE=/usr/local/bin/sb-core
FIXTURE_VERSION=1.99.0
fixture_root=$(mktemp -d /tmp/sb-core-fixtures.XXXXXXXX)
trap 'cleanup_root; rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"
cat > "$fixture_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url='' destination=''
while (( $# )); do
    case $1 in --output) destination=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac
done
case $url in
    https://api.github.com/repos/SagerNet/sing-box/releases/latest|https://api.github.com/repos/SagerNet/sing-box/releases/tags/*) source="$SB_CORE_FIXTURE/release.json";;
    https://api.github.com/repos/SagerNet/sing-box/compare/*) source="$SB_CORE_FIXTURE/compare.json";;
    https://codeload.github.com/SagerNet/sing-box/tar.gz/refs/tags/*) source="$SB_CORE_FIXTURE/source-${url##*/}.tar.gz";;
    https://github.com/SagerNet/sing-box/releases/download/*) source="$SB_CORE_FIXTURE/${url##*/}";;
    *) exit 22;;
esac
[[ -f $source ]] || exit 22
cp "$source" "$destination"
CURL
chmod +x "$fixture_root/bin/curl"
export PATH="$fixture_root/bin:$PATH"
new_case() {
    cleanup_root
    SB_ROOT=$(mktemp -d /tmp/sb-core-test.XXXXXXXX)
    SB_CORE="$SB_ROOT/core/sing-box"
    export SB_ROOT SB_CORE SB_SERVICE_MODE=none
    mkdir -p "$SB_ROOT/core" "$SB_ROOT/rules"
    cp "$REAL_CORE" "$SB_CORE"
    cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
    "$CLI" init --address 127.0.0.1 >/dev/null
    export SB_SERVICE_MODE=process
    node=$("$CLI" add ss 28251 auto aes-256-gcm)
    id=$(jq -r .id <<< "$node")
    before_binary=$(hash_file "$SB_CORE")
    before_generation=$(readlink "$SB_ROOT/current")
    cp "$SB_ROOT/current/nodes/$id.json" "$SB_ROOT/run/expected-node.json"
    export SB_CORE_FIXTURE="$SB_ROOT/fixture"
    mkdir -p "$SB_CORE_FIXTURE"
}
# Synthetic versions let us inject failures while using the real core for check
# and traffic. Actual official cross-version upgrades are a separate live test.
make_release() {
    local mode=${1:-ok} arch directory asset hash
    arch=$(dpkg --print-architecture)
    directory="$SB_CORE_FIXTURE/sing-box-$FIXTURE_VERSION-linux-$arch"
    asset="sing-box-$FIXTURE_VERSION-linux-$arch.tar.gz"
    mkdir -p "$directory"
    cat > "$directory/sing-box" <<CORE
#!/usr/bin/env bash
set -Eeuo pipefail
case \${1:-} in
    version) printf 'sing-box version $FIXTURE_VERSION\\n'; exit 0;;
    check) [[ $mode != check-fail ]] || { printf 'removed_field: json: unknown field\\n' >&2; exit 42; };;
    run)
        [[ $mode != run-fail ]] || exit 42
        if [[ $mode == pause ]]; then touch "\$SB_ROOT/run/core-start-paused"; exec sleep 60; fi;;
esac
exec /usr/local/bin/sb-core "\$@"
CORE
    chmod +x "$directory/sing-box"
    tar -czf "$SB_CORE_FIXTURE/$asset" -C "$SB_CORE_FIXTURE" "${directory##*/}"
    hash=$(hash_file "$SB_CORE_FIXTURE/$asset")
    jq -n --arg version "$FIXTURE_VERSION" --arg asset "$asset" --arg hash "$hash" \
        '{draft:false,prerelease:false,tag_name:("v"+$version),body:"New configuration option: new_optional_field. Deprecated old_field.",assets:[{name:$asset,digest:("sha256:"+$hash),browser_download_url:("https://github.com/SagerNet/sing-box/releases/download/v"+$version+"/"+$asset)}]}' > "$SB_CORE_FIXTURE/release.json"
    jq -n '{files:[{filename:"option/tls.go",patch:"@@ -1 +1 @@\n- Old string `json:\"old_field,omitempty\"`\n+ New string `json:\"new_optional_field,omitempty\"`\n- Stable bool `json:\"enabled,omitempty\"`\n+ Stable *bool `json:\"enabled,omitempty\"`"}]}' > "$SB_CORE_FIXTURE/compare.json"
}
unchanged() {
    [[ $(hash_file "$SB_CORE") == "$before_binary" ]]
    [[ $(readlink "$SB_ROOT/current") == "$before_generation" ]]
    cmp "$SB_ROOT/run/expected-node.json" "$SB_ROOT/current/nodes/$id.json"
}
new_case
make_release
before_pid=$(cat "$SB_ROOT/run/core.pid")
"$CLI" update core --check > "$SB_ROOT/run/check-output" 2>&1
unchanged
[[ $(cat "$SB_ROOT/run/core.pid") == "$before_pid" ]]
grep -q '新增: option/tls.go · new_optional_field' "$SB_ROOT/run/check-output"
grep -q '移除/迁移: option/tls.go · old_field' "$SB_ROOT/run/check-output"
! grep -q '新增:.*enabled' "$SB_ROOT/run/check-output"
pass 'check-only shows new/removed fields without restarting or changing node data'
"$CLI" update core > "$SB_ROOT/run/update-output" 2>&1
[[ $(core_binary_version "$SB_CORE") == "$FIXTURE_VERSION" ]]
jq -e '.phase=="committed"' "$SB_ROOT/core-update.json" >/dev/null
cmp "$SB_ROOT/run/expected-node.json" "$SB_ROOT/current/nodes/$id.json"
service_active core
"$CLI" port "$id" 28252
port_is_listening 28252
"$CLI" update core > "$SB_ROOT/run/already-current" 2>&1
grep -q '当前已是目标版本' "$SB_ROOT/run/already-current"
pass 'latest update, verified core metadata, stable node data and later management work'
# A template change on a later script release must still preflight this core.
preflight_install
pass 'script preflight accepts a newer core previously validated by the manager'
cp "$SB_ROOT/current/nodes/$id.json" "$SB_ROOT/run/expected-node.json"
rm "$SB_ROOT/core-installed.json"
"$CLI" update core > "$SB_ROOT/run/revalidate-current" 2>&1
check_core_version
cmp "$SB_ROOT/run/expected-node.json" "$SB_ROOT/current/nodes/$id.json"
pass 'same-version update repairs missing validation metadata through official artifact verification'

new_case
make_release
jq -n '{files:[range(0;300)|{filename:("other/"+tostring+".go"),patch:""}]}' > "$SB_CORE_FIXTURE/compare.json"
for version in "$(core_binary_version "$SB_CORE")" "$FIXTURE_VERSION"; do
    source_directory="$SB_CORE_FIXTURE/sing-box-$version"
    mkdir -p "$source_directory/option/nested"
    printf '%s\n' 'type Stable struct { Enabled bool `json:"enabled,omitempty"` }' > "$source_directory/option/tls.go"
    if [[ $version == "$FIXTURE_VERSION" ]]; then field=added_from_source; else field=removed_from_source; fi
    printf 'type Nested struct { Field string `json:"%s,omitempty"` }\n' "$field" > "$source_directory/option/nested/transport.go"
    tar -czf "$SB_CORE_FIXTURE/source-v$version.tar.gz" -C "$SB_CORE_FIXTURE" "sing-box-$version"
done
"$CLI" update core --check > "$SB_ROOT/run/source-output" 2>&1
unchanged
grep -q '新增: option/nested/transport.go · added_from_source' "$SB_ROOT/run/source-output"
grep -q '移除/迁移: option/nested/transport.go · removed_from_source' "$SB_ROOT/run/source-output"
report=$(find "$SB_ROOT/reports" -mindepth 2 -maxdepth 2 -name fields.json)
jq -e '.status=="complete" and .method=="official-source-option-tags" and (.added|length)==1 and (.removed|length)==1' "$report" >/dev/null
pass 'truncated GitHub comparison falls back to complete official source tags, including nested option files'

new_case
make_release
jq '.prerelease=true' "$SB_CORE_FIXTURE/release.json" > "$SB_CORE_FIXTURE/release.tmp"
mv "$SB_CORE_FIXTURE/release.tmp" "$SB_CORE_FIXTURE/release.json"
must_fail "$CLI" update core
unchanged
make_release
jq '.assets[0].digest="sha256:"+("0"*64)' "$SB_CORE_FIXTURE/release.json" > "$SB_CORE_FIXTURE/release.tmp"
mv "$SB_CORE_FIXTURE/release.tmp" "$SB_CORE_FIXTURE/release.json"
must_fail "$CLI" update core
unchanged
make_release
jq '.assets[0].browser_download_url="https://example.test/untrusted.tar.gz"' "$SB_CORE_FIXTURE/release.json" > "$SB_CORE_FIXTURE/release.tmp"
mv "$SB_CORE_FIXTURE/release.tmp" "$SB_CORE_FIXTURE/release.json"
must_fail "$CLI" update core
unchanged
pass 'prerelease, checksum mismatch and non-official artifact URL preserve the old core'

new_case
make_release check-fail
must_fail "$CLI" update core
unchanged
service_active core
pass 'new required/removed field validation failure leaves running services untouched'

new_case
make_release run-fail
must_fail "$CLI" update core
unchanged
service_active core
port_is_listening 28251
jq -e '.phase=="rolled-back"' "$SB_ROOT/core-update.json" >/dev/null
"$CLI" port "$id" 28252
pass 'failed real process startup restores binary, metadata, generation, listeners and write lock'

new_case
make_release
rm "$SB_CORE_FIXTURE/compare.json"
"$CLI" update core --check > "$SB_ROOT/run/unavailable" 2>&1
grep -q '字段差异未能完整获取' "$SB_ROOT/run/unavailable"
unchanged
pass 'unavailable field comparison is explicitly reported rather than claiming no new fields'

new_case
make_release
service_action core stop
"$CLI" update core > "$SB_ROOT/run/stopped-update" 2>&1
! service_active core
cmp "$SB_ROOT/run/expected-node.json" "$SB_ROOT/current/nodes/$id.json"
pass 'update retains a deliberately stopped service state'

new_case
make_release pause
setsid "$CLI" update core > "$SB_ROOT/run/interrupted-update" 2>&1 &
apply_pid=$!
for ((i=0;i<150;i++)); do [[ ! -f $SB_ROOT/run/core-start-paused ]] || break; sleep .1; done
if (( i==150 )); then kill -KILL -- "-$apply_pid" 2>/dev/null || true; die '未进入内核更新中断阶段'; fi
kill -KILL -- "-$apply_pid"
wait "$apply_pid" 2>/dev/null || true
"$CLI" status > "$SB_ROOT/run/recovered.json"
unchanged
service_active core
port_is_listening 28251
jq -e '.phase=="rolled-back"' "$SB_ROOT/core-update.json" >/dev/null
pass 'SIGKILL during binary switch recovers old binary and original services on next command'
printf 'CORE UPDATE SUITE PASSED\n'
