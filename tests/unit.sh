#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
trap cleanup_root EXIT
cd "$SB_HOME"
shellcheck -S warning -x bin/sb lib/*.sh install.sh scripts/certbot-deploy-hook scripts/prepare-test-assets
for file in bin/sb lib/*.sh install.sh scripts/* tests/*.sh; do [[ ! -f $file ]] || bash -n "$file"; done
pass 'Bash syntax and ShellCheck'
fresh_root
before=$(find "$SB_ROOT" -type f | sort | xargs sha256sum)
"$CLI" gen reality 25000 auto apps.mzstatic.com --address 127.0.0.1 > /tmp/sb-gen.json
after=$(find "$SB_ROOT" -type f | sort | xargs sha256sum)
[[ $before == "$after" ]]
"$SB_CORE" check -c /tmp/sb-gen.json
pass 'gen performs no filesystem mutation'

first=$("$CLI" add r 25001 auto apps.mzstatic.com --skip-probe)
second=$("$CLI" add r 25002 auto xp.apple.com --skip-probe)
id1=$(jq -r .id <<< "$first"); id2=$(jq -r .id <<< "$second")
assert_jq "$(read_state)" '.nodes|length==2'
unchanged=$(hash_file "$SB_ROOT/current/nodes/$id2.json")
"$CLI" port "$id1" 25003
"$CLI" sni "$id1" xp.apple.com --skip-probe
[[ $(hash_file "$SB_ROOT/current/nodes/$id2.json") == "$unchanged" ]]
link='ss://YWVzLTI1Ni1nY206cGFzczp3aXRoQHNwZWNpYWw=@198.51.100.8:1234#test'
"$CLI" outbound "$id1" "$link"
"$CLI" outbound "$id2" "$link"
"$CLI" outbound "$id1" direct
assert_jq "$(read_state)" '.nodes|map(select(.outbound.type=="shadowsocks"))|length==1'
"$CLI" new "$id1" ss auto auto aes-256-gcm
assert_jq "$(read_state)" "any(.nodes[];.id==\"$id1\" and .protocol==\"shadowsocks\")"
must_fail "$CLI" info n-
must_fail "$CLI" add ss 25002 auto aes-256-gcm
pass 'stable IDs, duplicate protocol, independent outbound copies, selection and port conflicts'

for i in 1 2 3 4; do "$CLI" add tcp "$((25100+i))" >"$SB_ROOT/run/concurrent-$i.json" & done
wait
assert_jq "$(read_state)" '.nodes|length==6'
pass 'concurrent changes do not drop nodes'

for p in r rh2 ss tcp http quic ws wss h2 hu vws vh2 vhu tws th2 thu trojan hy2 tuic anytls socks door; do
    args=(--address 127.0.0.1 --port 26000 --cert-domain example.test)
    case $p in wss|h2|hu|vws|vh2|vhu|tws|th2|thu) args+=(example.test);; door) args+=(auto example.test 443);; esac
    "$CLI" gen "$p" "${args[@]}" > "$SB_ROOT/run/preview.json"
    # Native TLS previews intentionally reference user-supplied certificate paths.
    if [[ ! -f $SB_ROOT/run/preview-cert.pem ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=example.test -addext subjectAltName=DNS:example.test \
            -keyout "$SB_ROOT/run/preview-key.pem" -out "$SB_ROOT/run/preview-cert.pem" >/dev/null 2>&1
    fi
    jq --arg cert "$SB_ROOT/run/preview-cert.pem" --arg key "$SB_ROOT/run/preview-key.pem" \
       '.inbounds|=map(if .tls.certificate_path then .tls.certificate_path=$cert|.tls.key_path=$key else . end)' "$SB_ROOT/run/preview.json" > "$SB_ROOT/run/check.json"
    "$SB_CORE" check -c "$SB_ROOT/run/check.json"
done
pass 'all 22 entry templates pass sing-box 1.14.4 validation'

cert=$("$CLI" cert import example.test "$SB_ROOT/run/preview-cert.pem" "$SB_ROOT/run/preview-key.pem" --self-signed)
assert_jq "$(read_state)" '.websites|length==0'
for p in ss tcp http quic ws r rh2 trojan hy2 tuic anytls socks wss h2 hu vws vh2 vhu tws th2 thu; do
    args=(--address 127.0.0.1 --cert-domain example.test --certificate "$cert" --skip-probe)
    case $p in wss|h2|hu|vws|vh2|vhu|tws|th2|thu) args+=(example.test);; esac
    node=$(build_node "$p" '{}' false "${args[@]}")
    state=$(read_state | jq --argjson n "$node" '.nodes=[$n]')
    out=$(node_client "$state" "$(jq -r .id <<< "$node")")
    encoded=$(uri_from_outbound "$out" roundtrip)
    decoded=$(outbound_from_uri "$encoded")
    assert_jq "$decoded" '.server=="127.0.0.1" and .server_port>0'
    cfg=$(jq -n --argjson out "$decoded" '{outbounds:[$out],dns:{servers:[{type:"local",tag:"dns"}]},route:{default_domain_resolver:"dns"}}')
    printf '%s\n' "$cfg" > "$SB_ROOT/run/outbound.json"
    "$SB_CORE" check -c "$SB_ROOT/run/outbound.json"
done
pass 'all supported share formats round-trip to valid real-core outbounds'

malicious_marker="$SB_ROOT/run/injected"
must_fail outbound_from_uri 'vless://bad@127.0.0.1:443?x=1'
must_fail outbound_from_uri 'vless://bad@127.0.0.1:443?security=tls&security=none'
must_fail outbound_from_uri 'ss://not-base64@127.0.0.1:443'
must_fail outbound_from_uri 'ss://YWVzLTEyOC1nY206eA==@127.0.0.1:443?plugin=exec'
must_fail outbound_from_uri "vless://bad@127.0.0.1:443?\$(touch $malicious_marker)=x"
[[ ! -e $malicious_marker ]]
ipv6=$(outbound_from_uri 'trojan://pa%3Ass%40word@[2001:db8::1]:443?sni=example.test')
assert_jq "$ipv6" '.server=="2001:db8::1" and .password=="pa:ss@word" and .tls.insecure==false'
pass 'malformed URIs, command injection, IPv6 and escaped credentials'

debug=$("$CLI" debug)
secret=$(read_state | jq -r '.nodes[0].password')
[[ $debug != *"$secret"* ]]
printf '%s\n' 'test_TOKEN_012345678901234567890' | "$CLI" cert token set test
backup="$SB_ROOT/run/backup.tar.gz"
"$CLI" backup "$backup" >/dev/null
[[ $(stat -c %a "$backup") == 600 ]]
tar -tzf "$backup" | grep -qv credentials
mkdir "$SB_ROOT/run/unpacked"
tar -xzf "$backup" -C "$SB_ROOT/run/unpacked"
! grep -r -q 'test_TOKEN_012345678901234567890' "$SB_ROOT/run/unpacked"
nodecount=$(read_state | jq '.nodes|length')
"$CLI" del "$id1"
"$CLI" restore "$backup"
assert_jq "$(read_state)" ".nodes|length==$nodecount"
pass 'redacted diagnostics and token-free, permission-restricted backup/restore'

mkdir "$SB_ROOT/run/attack"
ln -s /etc/passwd "$SB_ROOT/run/attack/escape"
tar -czf "$SB_ROOT/run/evil.tar.gz" -C "$SB_ROOT/run/attack" .
must_fail "$CLI" restore "$SB_ROOT/run/evil.tar.gz"
pass 'unsafe archive entries rejected'
mkdir -p "$SB_ROOT/run/hook-archive/acme/config/renewal-hooks/deploy"
printf '#!/bin/sh\nexit 0\n' > "$SB_ROOT/run/hook-archive/acme/config/renewal-hooks/deploy/evil"
cp "$SB_ROOT/run/unpacked/metadata.json" "$SB_ROOT/run/hook-archive/metadata.json"
cp "$SB_ROOT/run/unpacked/state.json" "$SB_ROOT/run/hook-archive/state.json"
(cd "$SB_ROOT/run/hook-archive" || exit; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -czf "$SB_ROOT/run/hook-archive.tar.gz" -C "$SB_ROOT/run/hook-archive" .
must_fail "$CLI" restore "$SB_ROOT/run/hook-archive.tar.gz"
pass 'Certbot execution hooks cannot be restored from an archive'

current=$(readlink "$SB_ROOT/current")
must_fail "$CLI" outbound "$id2" 'ss://aW52YWxpZDp4@198.51.100.8:443'
[[ $(readlink "$SB_ROOT/current") == "$current" ]]
pass 'invalid candidate retains the exact active generation'

for type in sing-box xray v2ray; do
    if [[ $type == sing-box ]]; then
        jq -n '{inbounds:[{type:"vmess",listen_port:27001,users:[{uuid:"11111111-1111-4111-8111-111111111111"}]}],outbounds:[{type:"direct"}]}' > "$SB_ROOT/run/import.json"
    else
        jq -n '{inbounds:[{protocol:"vmess",port:27001,settings:{clients:[{id:"11111111-1111-4111-8111-111111111111"}]},streamSettings:{network:"tcp",security:"none"}}],outbounds:[{protocol:"freedom"}]}' > "$SB_ROOT/run/import.json"
    fi
    "$CLI" import "$SB_ROOT/run/import.json" >/dev/null
done
"$CLI" import "$SB_ROOT/run/import.json" --apply
assert_jq "$(read_state)" 'any(.nodes[];.port==27001 and .protocol=="vmess-tcp")'
pass 'known sing-box, Xray and V2Ray data import'
must_fail "$CLI" bbr
pass 'container BBR command refuses to alter the shared kernel'
printf 'UNIT SUITE PASSED\n'
