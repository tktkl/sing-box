#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
name="sb-acme-local-$RANDOM-$$"
image=${SB_TEST_IMAGE:-sb-manager-test:local}
arch=$(docker image inspect --format '{{.Architecture}}' "$image")
mkdir -p .test-output
cleanup() {
    local rc=$?
    if (( rc != 0 )); then docker exec "$name" bash -c 'tail -n 60 /state/pebble.log /state/dns.log /state/acme/logs/letsencrypt.log' >.test-output/acme-local-failure.log 2>&1 || true; fi
    docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --init --name "$name" --label sb-manager.test=true --network none \
    -v "$PWD:/workspace:ro" --tmpfs /state:mode=0700,exec --entrypoint sleep "$image" infinity >/dev/null
for binary in pebble pebble-challtestsrv; do
    file=".cache/$binary-linux-$arch.tar.gz"
    [[ -f $file ]] || { printf 'Missing locked ACME test binary: %s\n' "$file" >&2; exit 1; }
    expected=$(jq -r --arg name "$binary-linux-$arch.tar.gz" '.pebble.assets[$name].sha256' dependencies.lock.json)
    if command -v sha256sum >/dev/null; then actual=$(sha256sum "$file" | cut -d ' ' -f1); else actual=$(shasum -a256 "$file" | cut -d ' ' -f1); fi
    [[ $actual == "$expected" ]] || { printf 'ACME asset checksum failed\n' >&2; exit 1; }
    docker exec -i "$name" sh -c 'cat > "$1"' sh "/state/$binary.tar.gz" < "$file"
done
docker exec -i "$name" bash -s >.test-output/acme-local.log 2>&1 <<'EOF'
set -Eeuo pipefail
export SB_HOME=/workspace SB_ROOT=/state/manager SB_CORE=/usr/local/bin/sb-core SB_SERVICE_MODE=process
for module in common links render service state certificates nodes maintenance install import cli; do source "/workspace/lib/$module.sh"; done
mkdir -p /state/tools "$SB_ROOT/rules"
tar -xzf /state/pebble.tar.gz -C /state/tools
tar -xzf /state/pebble-challtestsrv.tar.gz -C /state/tools
cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
/workspace/bin/sb init --address 127.0.0.1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -keyout /state/pebble.key -out /state/pebble.pem >/dev/null 2>&1
printf '{"pebble":{"listenAddress":"127.0.0.1:14000","managementListenAddress":"127.0.0.1:15000","certificate":"/state/pebble.pem","privateKey":"/state/pebble.key","httpPort":5002,"tlsPort":5001,"externalAccountBindingRequired":false,"retryAfter":{"authz":1,"order":1}}}\n' >/state/pebble.json
dns=$(find /state/tools -type f -name pebble-challtestsrv | head -n1)
pebble=$(find /state/tools -type f -name pebble | head -n1)
chmod +x "$dns" "$pebble"
"$dns" -dnsserver 127.0.0.1:8053 -management 127.0.0.1:8055 -http01 '' -https01 '' -doh '' -tlsalpn01 '' >/state/dns.log 2>&1 &
PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 "$pebble" -config /state/pebble.json -dnsserver 127.0.0.1:8053 >/state/pebble.log 2>&1 &
for ((i=0;i<50;i++)); do curl --cacert /state/pebble.pem --silent --fail https://localhost:14000/dir >/dev/null && break; sleep .1; done
curl --cacert /state/pebble.pem --silent --fail https://localhost:15000/roots/0 >/state/root.pem
# Trust the temporary ACME root only inside this disposable test container.
cat /state/root.pem >> /etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/state/pebble.pem
cat >/state/auth-hook <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -n --arg host "_acme-challenge.$CERTBOT_DOMAIN." --arg value "$CERTBOT_VALIDATION" '{host:$host,value:$value}' |
  curl --silent --show-error --fail -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8055/set-txt
HOOK
cat >/state/cleanup-hook <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -n --arg host "_acme-challenge.$CERTBOT_DOMAIN." '{host:$host}' |
  curl --silent --show-error --fail -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8055/clear-txt
HOOK
chmod +x /state/auth-hook /state/cleanup-hook
id=$(cert_id '["example.test"]')
mkdir -p "$SB_ROOT/run/renewed"
certbot certonly --manual --preferred-challenges dns --manual-auth-hook /state/auth-hook --manual-cleanup-hook /state/cleanup-hook \
  --non-interactive --agree-tos --register-unsafely-without-email --server https://localhost:14000/dir \
  --config-dir "$SB_ROOT/acme/config" --work-dir "$SB_ROOT/acme/work" --logs-dir "$SB_ROOT/logs/acme" \
  --cert-name "$id" --key-type ecdsa -d example.test
record=$(certificate_record "$id" '["example.test"]' test "$SB_ROOT/acme/config/live/$id/fullchain.pem" "$SB_ROOT/acme/config/live/$id/privkey.pem" false)
with_lock _save_certificates "[$record]"
node=$(/workspace/bin/sb add trojan 29443 auto --cert-domain example.test --certificate "$id")
[[ $(jq -r .protocol <<< "$node") == trojan ]]
old=$(jq -r .version_dir <<< "$record")
certbot renew --force-renewal --no-random-sleep-on-renew --non-interactive --server https://localhost:14000/dir \
  --config-dir "$SB_ROOT/acme/config" --work-dir "$SB_ROOT/acme/work" --logs-dir "$SB_ROOT/logs/acme" \
  --deploy-hook /workspace/scripts/certbot-deploy-hook
[[ -f $SB_ROOT/run/renewed/$id.json ]]
record=$(certificate_record "$id" '["example.test"]' test "$SB_ROOT/acme/config/live/$id/fullchain.pem" "$SB_ROOT/acme/config/live/$id/privkey.pem" false)
[[ $(jq -r .version_dir <<< "$record") != "$old" ]]
with_lock _save_certificates "[$record]"
expected=$(openssl x509 -in "$(jq -r .version_dir <<< "$record")/fullchain.pem" -noout -fingerprint -sha256)
served=$(openssl s_client -connect 127.0.0.1:29443 -servername example.test </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256)
[[ $expected == "$served" ]]
python3 - <<'PY'
import socket, struct
name = b''.join(bytes([len(x)]) + x.encode() for x in '_acme-challenge.example.test'.split('.')) + b'\0'
query = struct.pack('!6H', 12345, 0x100, 1, 0, 0, 0) + name + struct.pack('!2H', 16, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
sock.sendto(query, ('127.0.0.1', 8053))
reply, _ = sock.recvfrom(65535)
header = struct.unpack('!6H', reply[:12])
assert header[0] == 12345 and header[3] == 0, 'ACME TXT record was not cleaned up'
PY
/workspace/bin/sb stop
printf 'LOCAL ACME DNS-01, RENEWAL, DEPLOY HOOK AND SERVED CERTIFICATE PASSED\n'
EOF
cat .test-output/acme-local.log
