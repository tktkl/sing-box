#!/usr/bin/env bash
preflight_install() (
    set -Eeuo pipefail
    local state directory
    check_core_version
    rules_verify
    state=$(read_state)
    jq -e -L "$SB_HOME/jq" 'include "model";valid_state' <<< "$state" >/dev/null || die '新版脚本无法读取现有节点'
    directory=$(mktemp -d "$SB_ROOT/run/upgrade-check.XXXXXXXX")
    trap 'rm -rf -- "$directory"' EXIT
    write_generation "$state" "$directory"
    core check -c "$directory/config.json"
    if has_nginx "$state"; then
        check_nginx_version "$state"
        validate_nginx "$directory" || { cat "$directory/nginx-check.log" >&2; die '新版 Nginx 模板不兼容现有配置'; }
    fi
)
install_release() {
    local source=$1 release version path wrapper
    version=$(cat "$source/VERSION"); [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '脚本版本格式错误'
    for wrapper in /usr/local/bin/sb /usr/local/bin/sing-box; do
        if [[ -e $wrapper ]] && ! grep -q 'sb-manager-owned' "$wrapper" 2>/dev/null; then die "命令路径已被其他安装占用: $wrapper；不会自动接管"; fi
    done
    mkdir -p /usr/local/lib/sb-manager/releases
    release="/usr/local/lib/sb-manager/releases/$version-$(stamp)"
    mkdir -p "$release"
    for path in bin lib jq scripts docs VERSION dependencies.lock.json install.sh LICENSE; do
        [[ ! -e $source/$path ]] || cp -a "$source/$path" "$release/$path"
    done
    chmod -R go-w "$release"
    chmod 755 /usr/local/lib/sb-manager /usr/local/lib/sb-manager/releases "$release"
    chmod +x "$release/bin/sb" "$release/install.sh" "$release/scripts/"*
    ln -s "$release" /usr/local/lib/sb-manager/.script.new
    mv -Tf /usr/local/lib/sb-manager/.script.new /usr/local/lib/sb-manager/script
    for wrapper in /usr/local/bin/sb /usr/local/bin/sing-box; do
        cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
# sb-manager-owned
exec /usr/local/lib/sb-manager/script/bin/sb "$@"
EOF
        chmod 755 "$wrapper"
    done
}
grant_runtime_access() {
    getent group sb-manager >/dev/null || groupadd --system sb-manager
    id sb-manager >/dev/null 2>&1 || useradd --system --gid sb-manager --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sb-manager
    chmod 755 /usr/local/lib/sb-manager /usr/local/lib/sb-manager/core
    chmod 755 "$SB_CORE"
    chgrp sb-manager "$SB_ROOT"; chmod 751 "$SB_ROOT"
    local path
    for path in generations certificates rules www; do
        [[ -d $SB_ROOT/$path ]] || continue
        chgrp -R sb-manager "$SB_ROOT/$path"
        find "$SB_ROOT/$path" -type d -exec chmod 750 {} +
        find "$SB_ROOT/$path" -type f -exec chmod 640 {} +
    done
    chmod 755 "$SB_ROOT/www"; chmod 644 "$SB_ROOT/www/index.html"
}
create_systemd_units() {
    mkdir -p /etc/systemd/system "$SB_ROOT/logs"
    cat > /etc/systemd/system/sb-manager.service <<EOF
[Unit]
Description=Independent sing-box nodes managed by sb-manager
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
User=sb-manager
Group=sb-manager
ExecStart=$SB_CORE run -c $SB_ROOT/current/config.json
Restart=on-failure
RestartSec=2
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
StandardOutput=append:$SB_ROOT/logs/core.log
StandardError=append:$SB_ROOT/logs/core.log
UMask=0027
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/sb-manager-renew.service <<EOF
[Unit]
Description=Renew and transactionally deploy sb-manager certificates
[Service]
Type=oneshot
Environment=SB_ROOT=$SB_ROOT
ExecStart=/usr/local/bin/sb cert renew
UMask=0077
EOF
    cat > /etc/systemd/system/sb-manager-renew.timer <<'EOF'
[Unit]
Description=Check sb-manager certificate renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/sb-manager <<EOF
$SB_ROOT/logs/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  copytruncate
  create 0640 root root
}
EOF
}
install_nginx_package() (
    set -Eeuo pipefail
    local package=$1
    [[ ! -e /etc/systemd/system/nginx.service && ! -L /etc/systemd/system/nginx.service &&
       ! -e /run/systemd/system/nginx.service && ! -L /run/systemd/system/nginx.service ]] || die '已存在 Nginx 服务定义或屏蔽状态，拒绝自动替换'
    systemctl cat nginx.service >/dev/null 2>&1 && die '已存在 Nginx 服务定义，拒绝自动替换'
    [[ ! -e /etc/nginx/conf.d/default.conf && ! -L /etc/nginx/conf.d/default.conf ]] || die '已存在 Nginx 默认网站，拒绝覆盖'
    finish_nginx_package() {
        local rc=$?
        trap - EXIT
        # Only this fresh package can have created this file. Disable it before
        # unmasking so package scripts can never expose an unsolicited port 80.
        if [[ -f /etc/nginx/conf.d/default.conf ]]; then mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.sb-package-disabled; fi
        systemctl unmask nginx.service
        if (( rc != 0 )); then systemctl disable nginx.service >/dev/null 2>&1 || true; fi
        exit "$rc"
    }
    trap finish_nginx_package EXIT
    systemctl mask nginx.service
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >&2
)
install_nginx() {
    command -v nginx >/dev/null && return 0
    [[ $SB_SERVICE_MODE == systemd ]] || die '缺少 Nginx；测试镜像需要显式安装锁定版本'
    need apt-get
    source /etc/os-release
    local repo=ubuntu keyring temp fingerprint version
    [[ $ID != debian ]] || repo=debian
    apt-get update >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg ca-certificates curl >&2
    temp=$(mktemp -d "$SB_ROOT/run/nginx-key.XXXXXXXX")
    download https://nginx.org/keys/nginx_signing.key "$temp/signing.asc"
    fingerprint=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
    gpg --homedir "$temp" --batch --import "$temp/signing.asc" >/dev/null 2>&1
    gpg --homedir "$temp" --batch --with-colons --fingerprint "$fingerprint" | grep -q "$fingerprint" || die 'Nginx APT 签名指纹不匹配'
    keyring=/usr/share/keyrings/sb-manager-nginx.gpg
    gpg --homedir "$temp" --batch --export "$fingerprint" > "$keyring"; chmod 644 "$keyring"
    printf 'deb [signed-by=%s] https://nginx.org/packages/%s %s nginx\n' "$keyring" "$repo" "$VERSION_CODENAME" > /etc/apt/sources.list.d/sb-manager-nginx.list
    apt-get update >&2
    version=$(apt-cache madison nginx | awk '{print $3}' | grep '^1\.30\.6-' | head -n1)
    [[ -n $version ]] || die '官方仓库没有锁定版本 Nginx 1.30.6'
    install_nginx_package "nginx=$version"
    rm -rf "$temp"
}
ensure_nginx_integration() {
    [[ $SB_SERVICE_MODE == systemd ]] || return 0
    install_nginx
    mkdir -p /etc/nginx/conf.d
    if [[ -f /etc/nginx/conf.d/sb-manager.conf ]] && ! grep -q 'sb-manager-owned' /etc/nginx/conf.d/sb-manager.conf; then die 'Nginx include 文件属于其他安装'; fi
    printf '# sb-manager-owned\ninclude %s/current/nginx/domains/*.conf;\n' "$SB_ROOT" > /etc/nginx/conf.d/sb-manager.conf
}
update_nginx() {
    local version=${1:-1.30.6} actual
    [[ $version == 1.30.6 ]] || die '只允许锁定并验证的 Nginx 1.30.6'
    install_nginx
    actual=$(nginx -v 2>&1); actual=${actual#*nginx/}; actual=${actual%% *}
    [[ $actual == "$version" ]] || die "现有 Nginx $actual 不是本项目锁定版本；请先用系统包管理器显式升级到 $version，本命令不替换共用软件"
    nginx -t
    service_action nginx reload
}
update_script() {
    local version=${1:-} source temp digest
    if [[ $version == --from ]]; then
        source=$(realpath "${2:?需要本地发布目录}")
        [[ -f $source/install.sh && -f $source/dependencies.lock.json ]] || die '缺少发布文件'
        "$source/bin/sb" help >/dev/null
        "$source/install.sh" --reinstall
        return
    fi
    if [[ -z $version ]]; then version=$(curl --fail --silent --show-error https://api.github.com/repos/tktkl/sing-box/releases/latest | jq -r .tag_name); fi
    version=${version#v}; [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '没有可用的版本化脚本发布'
    temp=$(mktemp -d "$SB_ROOT/run/update.XXXXXXXX")
    download "https://github.com/tktkl/sing-box/releases/download/v$version/sb-manager-$version.tar.gz.sha256" "$temp/checksum"
    digest=$(cut -d ' ' -f1 "$temp/checksum"); [[ $digest =~ ^[a-f0-9]{64}$ ]] || die '发布校验格式无效'
    download "https://github.com/tktkl/sing-box/releases/download/v$version/sb-manager-$version.tar.gz" "$temp/release.tar.gz" "$digest"
    local member
    while IFS= read -r member; do [[ $member != /* && $member != *..* && $member != *\\* ]] || die '发布包路径无效'; done < <(tar -tzf "$temp/release.tar.gz")
    while IFS= read -r member; do [[ $member == d || $member == - ]] || die '发布包不允许链接或特殊文件'; done < <(tar -tvzf "$temp/release.tar.gz" | cut -c1)
    tar -xzf "$temp/release.tar.gz" -C "$temp"
    [[ -x $temp/sb-manager-$version/install.sh ]] || die '发布包结构错误'
    "$temp/sb-manager-$version/install.sh" --reinstall
    rm -rf "$temp"
}
uninstall_manager() {
    local wrapper
    if [[ $SB_SERVICE_MODE == systemd ]]; then
        systemctl disable --now sb-manager-renew.timer "$SB_UNIT" || true
        rm -f /etc/systemd/system/sb-manager{,-renew}.service /etc/systemd/system/sb-manager-renew.timer
        if [[ -f /etc/nginx/conf.d/sb-manager.conf ]] && grep -q sb-manager-owned /etc/nginx/conf.d/sb-manager.conf; then
            rm /etc/nginx/conf.d/sb-manager.conf
            nginx -t && systemctl reload nginx
        fi
        rm -f /etc/logrotate.d/sb-manager
        systemctl daemon-reload
    else service_action core stop; service_action nginx stop; fi
    for wrapper in /usr/local/bin/sb /usr/local/bin/sing-box; do
        if [[ -f $wrapper ]] && grep -q sb-manager-owned "$wrapper"; then rm -f "$wrapper"; fi
    done
    note '已移除本项目服务与快捷命令；保留管理目录中的节点、证书和凭据，可自行备份后清理'
}
