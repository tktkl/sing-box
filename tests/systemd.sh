#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
name="sb-systemd-$RANDOM-$$"
mkdir -p .test-output
cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        docker exec "$name" bash -c 'systemctl status sb-manager.service --no-pager; journalctl -u sb-manager.service -n 50 --no-pager; cat /etc/sb-manager/logs/core.log; namei -l /etc/sb-manager/current/config.json /etc/sb-manager/rules/geoip-cn.srs; stat /etc/sb-manager/transaction.json' >.test-output/systemd-failure.log 2>&1 || true
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --name "$name" --label sb-manager.test=true --privileged --cgroupns private \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp -v "$PWD:/workspace:ro" \
    --entrypoint /bin/bash "${SB_TEST_IMAGE:-sb-manager-test:local}" -c \
    'for unit in systemd-binfmt systemd-modules-load systemd-sysctl systemd-udevd systemd-udev-trigger; do ln -sf /dev/null "/etc/systemd/system/$unit.service"; done; exec /sbin/init' >/dev/null
for ((i=0;i<60;i++)); do
    if docker exec "$name" systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then break; fi
    sleep .5
done
if (( i==60 )); then docker logs "$name" >.test-output/systemd-unavailable.log 2>&1; printf 'Real systemd unavailable; Linux VM acceptance required.\n' >&2; exit 1; fi
docker exec -i "$name" bash -s >.test-output/systemd.log 2>&1 <<'EOF'
set -Eeuo pipefail
export SB_HOME=/workspace SB_ROOT=/etc/sb-manager SB_CORE=/usr/local/lib/sb-manager/core/sing-box SB_SERVICE_MODE=systemd
for module in common links render service state certificates nodes maintenance install import cli; do source "/workspace/lib/$module.sh"; done
mkdir -p /usr/local/lib/sb-manager/core "$SB_ROOT/rules"
install -m755 /usr/local/bin/sb-core "$SB_CORE"
cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
install_release /workspace
SB_SERVICE_MODE=none /usr/local/bin/sb init --address 127.0.0.1
create_systemd_units
grant_runtime_access
systemctl daemon-reload
systemctl enable --now sb-manager-renew.timer
node=$(/usr/local/bin/sb add ss 29001 auto aes-256-gcm)
id=$(jq -r .id <<< "$node")
systemctl is-active --quiet sb-manager.service
[[ $(systemctl show sb-manager.service -p User --value) == sb-manager ]]
ss -lnut 'sport = :29001' | grep -q 29001
/usr/local/bin/sb port "$id" 29002
ss -lnut 'sport = :29002' | grep -q 29002
kill -KILL "$(systemctl show sb-manager.service -p MainPID --value)"
sleep 3
systemctl is-active --quiet sb-manager.service
systemctl start sb-manager-renew.service
systemctl is-active --quiet sb-manager-renew.timer
systemctl restart sb-manager.service
/usr/local/bin/sb test
# Exercise the real shared nginx service, including asynchronous port handoffs.
mkdir -p /etc/nginx/conf.d
cat >/etc/nginx/nginx.conf <<'NGINX'
pid /run/nginx.pid;
error_log /var/log/nginx-test.log warn;
events {}
http { access_log off; include /etc/nginx/conf.d/*.conf; }
NGINX
cat >/etc/systemd/system/nginx.service <<'UNIT'
[Unit]
Description=Disposable nginx systemd acceptance fixture
[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStart=/usr/local/sbin/nginx -c /etc/nginx/nginx.conf
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -QUIT $MAINPID
UNIT
systemctl daemon-reload
/usr/local/bin/sb new "$id" wss example.test auto /tunnel --port 29002 --self-signed
systemctl is-active --quiet nginx.service
[[ $(find "$SB_ROOT/current/nginx/domains" -type f | wc -l) == 1 ]]
old_generation=$(readlink "$SB_ROOT/current")
mkdir -p /etc/systemd/system/nginx.service.d
printf '[Service]\nExecReload=\nExecReload=/bin/true\n' >/etc/systemd/system/nginx.service.d/stale.conf
systemctl daemon-reload
if /usr/local/bin/sb path "$id" /changed-without-reload; then printf 'Stale nginx falsely passed acceptance\n' >&2; exit 1; fi
[[ $(readlink "$SB_ROOT/current") == "$old_generation" ]]
[[ $(jq -r .phase "$SB_ROOT/transaction.json") == rolled-back ]]
rm /etc/systemd/system/nginx.service.d/stale.conf
systemctl daemon-reload
/usr/local/bin/sb new "$id" ss 29002 auto aes-256-gcm
ss -lnut 'sport = :29002' | grep -q 29002
# Retained, unrelated resources must survive uninstall.
mkdir -p /etc/nginx/conf.d
printf '# unrelated\n' >/etc/nginx/conf.d/unrelated.conf
/usr/local/bin/sb uninstall
[[ -f /etc/nginx/conf.d/unrelated.conf && -f "$SB_ROOT/current/nodes/$id.json" ]]
! systemctl is-active --quiet sb-manager.service
printf 'SYSTEMD SUITE PASSED\n'
EOF
cat .test-output/systemd.log
