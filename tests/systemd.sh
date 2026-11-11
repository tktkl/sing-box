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
    'mount -t tmpfs -o ro,nosuid,nodev,noexec tmpfs /proc/sys/fs/binfmt_misc || exit; for unit in systemd-binfmt systemd-modules-load systemd-sysctl systemd-udevd systemd-udev-trigger; do ln -sf /dev/null "/etc/systemd/system/$unit.service"; done; exec /sbin/init' >/dev/null
for ((i=0;i<60;i++)); do
    if docker exec "$name" systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then break; fi
    sleep .5
done
if (( i==60 )); then docker logs "$name" >.test-output/systemd-unavailable.log 2>&1; printf 'Real systemd unavailable; Linux VM acceptance required.\n' >&2; exit 1; fi
docker exec "$name" findmnt -n -o FSTYPE,OPTIONS /proc/sys/fs/binfmt_misc | grep -q '^tmpfs.*\bro\b'
docker exec -i -e SB_TEST_INSTALLER="${SB_TEST_INSTALLER:-0}" -e SB_TEST_OFFLINE="${SB_TEST_OFFLINE:-0}" -e SB_TEST_BOOTSTRAP="${SB_TEST_BOOTSTRAP:-0}" -e SB_TEST_RELEASE="${SB_TEST_RELEASE:-}" "$name" bash -s >.test-output/systemd.log 2>&1 <<'EOF'
set -Eeuo pipefail
export SB_HOME=/workspace SB_ROOT=/etc/sb-manager SB_CORE=/usr/local/lib/sb-manager/core/sing-box SB_SERVICE_MODE=systemd
for module in common links render service state certificates nodes maintenance install import cli; do source "/workspace/lib/$module.sh"; done
mkdir -p /usr/local/lib/sb-manager/core "$SB_ROOT/rules"
cp /opt/test-assets/geoip-cn.srs "$SB_ROOT/rules/geoip-cn.srs"
if [[ $SB_TEST_INSTALLER == 1 ]]; then
    if [[ $SB_TEST_OFFLINE == 1 ]]; then
        arch=$(dpkg --print-architecture)
        mkdir -p "$SB_ROOT/cache"
        cp "/workspace/.cache/core-linux-$arch.tar.gz" "$SB_ROOT/cache/sing-box-1.14.4-linux-$arch.tar.gz"
    fi
    # Exercise the public installer. Offline mode supplies the exact pinned tarball
    # to its normal verified cache, without replacing any installer commands.
    if [[ $SB_TEST_BOOTSTRAP == 1 ]]; then
        mkdir /opt/standalone-installer
        cp /workspace/install.sh /opt/standalone-installer/install.sh
        [[ ! -e /opt/standalone-installer/lib ]]
        bash /opt/standalone-installer/install.sh --address 127.0.0.1 --no-node
        printf 'STANDALONE RELEASE BOOTSTRAP PASSED\n'
    else bash /workspace/install.sh --address 127.0.0.1 --no-node; fi
else
    install -m755 /usr/local/bin/sb-core "$SB_CORE"
    install_release /workspace
    SB_SERVICE_MODE=none /usr/local/bin/sb init --address 127.0.0.1
    create_systemd_units
    grant_runtime_access
    systemctl daemon-reload
    systemctl enable --now sb-manager-renew.timer
fi
node=$(/usr/local/bin/sb add ss 29001 auto aes-256-gcm)
id=$(jq -r .id <<< "$node")
if [[ -n $SB_TEST_RELEASE ]]; then
    cp "$SB_ROOT/current/nodes/$id.json" /tmp/before-release-upgrade.json
    /usr/local/bin/sb update sh "$SB_TEST_RELEASE"
    cmp /tmp/before-release-upgrade.json "$SB_ROOT/current/nodes/$id.json"
    systemctl is-active --quiet sb-manager.service
    printf 'PUBLISHED RELEASE DOWNLOAD AND SCRIPT UPGRADE PASSED\n'
fi
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
# Exercise real dpkg post-install service startup under the package guard. This
# local fixture does not stand in for nginx.org APT repository compatibility.
mkdir -p /opt/nginx-package/{DEBIAN,etc/nginx/conf.d,lib/systemd/system}
cat >/opt/nginx-package/DEBIAN/control <<'PACKAGE'
Package: sb-manager-nginx-test
Version: 1.0
Architecture: all
Maintainer: sb-manager tests <tests@example.test>
Description: Disposable nginx service-start acceptance fixture
PACKAGE
cat >/opt/nginx-package/DEBIAN/postinst <<'POSTINST'
#!/bin/sh
set -e
systemctl daemon-reload
touch /tmp/nginx-postinst-attempted
deb-systemd-invoke start nginx.service || true
POSTINST
chmod 755 /opt/nginx-package/DEBIAN/postinst
printf 'server { listen 80; return 200 "package-default"; }\n' >/opt/nginx-package/etc/nginx/conf.d/default.conf
cat >/opt/nginx-package/lib/systemd/system/nginx.service <<'PACKAGEUNIT'
[Service]
Type=forking
ExecStart=/usr/local/sbin/nginx
PACKAGEUNIT
find /opt/nginx-package -type d -exec chmod 755 {} +
chmod 644 /opt/nginx-package/DEBIAN/control
dpkg-deb --build /opt/nginx-package /opt/nginx-package.deb >/dev/null
install_nginx_package /opt/nginx-package.deb
[[ -f /tmp/nginx-postinst-attempted && -f /etc/nginx/conf.d/default.conf.sb-package-disabled ]]
! systemctl is-active --quiet nginx.service
! port_is_listening 80
printf 'NGINX PACKAGE DEFAULT PORT GUARD PASSED\n'
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
core_pid=$(systemctl show sb-manager.service -p MainPID --value)
cp "$SB_ROOT/current/nginx/domains/example.test.conf" /tmp/expected-nginx.conf
cp "$SB_ROOT/current/nodes/$id.json" /tmp/expected-node.json
sed -i 's/client_body_timeout 1d/client_body_timeout 60s/' "$SB_ROOT/current/nginx/domains/example.test.conf"
/usr/local/bin/sb fix-nginx
cmp /tmp/expected-node.json "$SB_ROOT/current/nodes/$id.json"
[[ $(systemctl show sb-manager.service -p MainPID --value) == "$core_pid" ]]
sed -E 's#/\._sb_health_[a-zA-Z0-9-]+#/._sb_health_GENERATION#g; s#return 200 "[a-zA-Z0-9-]+"#return 200 "GENERATION"#g' /tmp/expected-nginx.conf >/tmp/expected-normalized.conf
sed -E 's#/\._sb_health_[a-zA-Z0-9-]+#/._sb_health_GENERATION#g; s#return 200 "[a-zA-Z0-9-]+"#return 200 "GENERATION"#g' "$SB_ROOT/current/nginx/domains/example.test.conf" >/tmp/actual-normalized.conf
cmp /tmp/expected-normalized.conf /tmp/actual-normalized.conf
# Validate upgrades against existing nodes before selecting a release. A failed
# installer after selection must restore the previous script and service files.
mkdir /opt/upgrade-good
for path in bin lib jq scripts docs VERSION dependencies.lock.json install.sh LICENSE; do
    cp -a "/workspace/$path" /opt/upgrade-good/
done
cp -a /opt/upgrade-good /opt/upgrade-invalid
printf '\ndef config($root): {unsupported_upgrade_field:true};\n' >> /opt/upgrade-invalid/jq/model.jq
old_script=$(readlink /usr/local/lib/sb-manager/script)
if /usr/local/bin/sb update sh --from /opt/upgrade-invalid; then printf 'Invalid upgrade passed preflight\n' >&2; exit 1; fi
[[ $(readlink /usr/local/lib/sb-manager/script) == "$old_script" ]]
cmp /tmp/expected-node.json "$SB_ROOT/current/nodes/$id.json"
[[ $(systemctl show sb-manager.service -p MainPID --value) == "$core_pid" ]]
cp -a /opt/upgrade-good /opt/upgrade-interrupted
sed -i '/^install_release "\$SB_HOME"$/a false # injected installer failure after release selection' /opt/upgrade-interrupted/install.sh
if /usr/local/bin/sb update sh --from /opt/upgrade-interrupted; then printf 'Injected installer failure was ignored\n' >&2; exit 1; fi
[[ $(readlink /usr/local/lib/sb-manager/script) == "$old_script" ]]
cmp /tmp/expected-node.json "$SB_ROOT/current/nodes/$id.json"
systemctl is-active --quiet sb-manager.service
/usr/local/bin/sb update sh --from /opt/upgrade-good
[[ $(readlink /usr/local/lib/sb-manager/script) != "$old_script" ]]
cmp /tmp/expected-node.json "$SB_ROOT/current/nodes/$id.json"
systemctl is-active --quiet sb-manager.service
printf 'SCRIPT UPGRADE PREFLIGHT, ROLLBACK AND REINSTALL PASSED\n'
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
