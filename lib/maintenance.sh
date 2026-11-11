#!/usr/bin/env bash
download_core() {
    local version=${1:-1.14.4} destination=${2:-$SB_CORE} arch asset url digest temp cached
    version=${version#v}
    [[ $version == "$(jq -r .core_version "$SB_HOME/dependencies.lock.json")" ]] || die '此版本没有兼容性锁定清单，拒绝降级或未经验证的升级'
    case $(uname -m) in aarch64|arm64) arch=arm64;; x86_64|amd64) arch=amd64;; *) die '仅支持 amd64/arm64';; esac
    asset="sing-box-$version-linux-$arch.tar.gz"
    url=$(jq -r --arg a "$asset" '.assets[$a].url' "$SB_HOME/dependencies.lock.json")
    digest=$(jq -r --arg a "$asset" '.assets[$a].sha256' "$SB_HOME/dependencies.lock.json")
    [[ $url != null && $digest =~ ^[a-f0-9]{64}$ ]] || die '缺少内核下载校验值'
    mkdir -p "$SB_ROOT/cache" "$(dirname "$destination")"
    temp=$(mktemp -d "$SB_ROOT/cache/core.XXXXXXXX")
    cached="$SB_ROOT/cache/$asset"
    if [[ ! -f $cached || $(hash_file "$cached") != "$digest" ]]; then download "$url" "$cached" "$digest"; fi
    tar -xzf "$cached" -C "$temp"
    install -m 755 "$temp/sing-box-$version-linux-$arch/sing-box" "$destination"
    rm -rf -- "$temp"
}
backup_create() {
    local destination=${1:-$PWD/sb-manager-$(stamp).tar.gz} temp
    destination=$(realpath -m "$destination")
    [[ ! -e $destination ]] || die '备份目标已存在'
    temp=$(mktemp -d "$SB_ROOT/run/backup.XXXXXXXX")
    read_state > "$temp/state.json"
    cp -aL "$SB_ROOT/certificates" "$temp/certificates"
    if [[ -d $SB_ROOT/acme/config ]]; then
        mkdir -p "$temp/acme"
        cp -aL "$SB_ROOT/acme/config" "$temp/acme/config"
        rm -rf -- "$temp/acme/config/renewal-hooks"
        rm -f -- "$temp/acme/config/cli.ini"
    fi
    jq -n --arg root "$SB_ROOT" --arg version "$(cat "$SB_HOME/VERSION")" '{format:1,root:$root,script_version:$version,created_at:(now|todateiso8601),cloudflare_token_included:false}' > "$temp/metadata.json"
    (cd "$temp" || exit; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
    tar -czf "$destination" -C "$temp" .
    chmod 600 "$destination"
    rm -rf -- "$temp"
    printf '%s\n' "$destination"
}
backup_extract_checked() {
    local archive=$1 destination=$2 member kind count=0
    [[ -f $archive && $(stat -c %s "$archive") -le 536870912 ]] || die '备份不存在或压缩文件超过 512 MiB'
    while IFS= read -r member; do
        (( count+=1 )); (( count <= 100000 )) || die '备份文件数量过多'
        [[ $member != /* && $member != *\\* && $member != *'/../'* && $member != ../* && $member != */.. && $member != *$'\r'* ]] || die '备份包含不安全路径'
        [[ $member =~ ^[a-zA-Z0-9_./:-]+$ ]] || die '备份文件名包含不支持的字符'
        case ${member#./} in ''|state.json|metadata.json|SHA256SUMS|certificates|certificates/*|acme|acme/*) ;; *) die '备份包含未知资源';; esac
    done < <(tar -tzf "$archive")
    while IFS= read -r kind; do [[ $kind == d || $kind == - ]] || die '备份不允许链接或特殊文件'; done < <(tar -tvzf "$archive" | cut -c1)
    tar -tvzf "$archive" | awk '{sum+=$3} END {exit sum>536870912}' || die '备份展开后超过 512 MiB'
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$destination"
    [[ -f $destination/metadata.json && -f $destination/state.json && -f $destination/SHA256SUMS ]] || die '缺少备份元数据'
    jq -e '.format==1 and .cloudflare_token_included==false' "$destination/metadata.json" >/dev/null || die '备份格式不支持'
    local calculated
    calculated=$(mktemp "$SB_ROOT/run/checksums.XXXXXXXX")
    (cd "$destination" || exit; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) > "$calculated"
    cmp -s "$destination/SHA256SUMS" "$calculated" || { rm -f "$calculated"; die '备份完整性校验失败'; }
    rm -f "$calculated"
    [[ ! -e $destination/credentials ]] || die '备份不应包含 Cloudflare Token'
    [[ ! -e $destination/acme/config/renewal-hooks && ! -e $destination/acme/config/cli.ini ]] || die '备份不允许 Certbot 执行钩子或全局选项'
}
backup_restore() {
    local archive=$1 temp oldroot state cert path file
    temp=$(mktemp -d "$SB_ROOT/run/restore.XXXXXXXX")
    backup_extract_checked "$archive" "$temp"
    oldroot=$(jq -r .root "$temp/metadata.json")
    [[ $oldroot == /* && $oldroot != *..* && $oldroot != *$'\n'* ]] || die '备份原目录无效'
    state=$(cat "$temp/state.json")
    jq -e -L "$SB_HOME/jq" 'include "model";valid_state' <<< "$state" >/dev/null || die '备份节点结构无效'
    while IFS= read -r cert; do
        path=$(jq -r .version_dir <<< "$cert")
        [[ $path == "$oldroot/certificates/"* && $path != *..* ]] || die '证书路径超出备份范围'
        path="$temp/${path#"$oldroot/"}"
        validate_certificate "$path/fullchain.pem" "$path/privkey.pem" "$(jq .domains <<< "$cert")" "$(jq .self_signed <<< "$cert")"
    done < <(jq -c '.certificates[]' <<< "$state")
    cp -an "$temp/certificates/." "$SB_ROOT/certificates/"
    state=$(jq --arg old "$oldroot" --arg new "$SB_ROOT" '.certificates|=map(.version_dir=($new+(.version_dir|ltrimstr($old))))' <<< "$state")
    apply_state "$state"
    if [[ -d $temp/acme/config ]]; then
        mkdir -p "$SB_ROOT/acme/config"
        cp -an "$temp/acme/config/." "$SB_ROOT/acme/config/"
        for file in "$SB_ROOT/acme/config/renewal/"*.conf; do
            [[ -f $file ]] || continue
            # Never restore arbitrary executable hooks from an archive.
            sed -E '/^[[:space:]]*([a-z_]*hook|[a-z_]*hooks)[[:space:]]*=/d' "$file" > "$file.tmp"
            # root paths are validated above; JSON escaping is not used as shell escaping.
            local escaped_old escaped_new
            escaped_old=${oldroot//\//\\/}; escaped_new=${SB_ROOT//\//\\/}
            sed "s/$escaped_old/$escaped_new/g" "$file.tmp" > "$file"
            rm -f "$file.tmp"
        done
    fi
    rm -rf -- "$temp"
    note '恢复完成；Cloudflare Token 未恢复，请重新配置后检查续期'
}
set_dns() {
    local mode=${1:-none} address=${2:-} dns
    case $mode in
        none|local) dns='{"type":"local"}';;
        11|1111) dns='{"type":"udp","server":"1.1.1.1"}';;
        88|8888) dns='{"type":"udp","server":"8.8.8.8"}';;
        cf|cloudflare) dns='{"type":"h3","server":"cloudflare-dns.com","path":"/dns-query"}';;
        gg|google) dns='{"type":"h3","server":"dns.google","path":"/dns-query"}';;
        family|nosex) dns='{"type":"h3","server":"family.cloudflare-dns.com","path":"/dns-query"}';;
        set)
            [[ -n $address ]] || die 'dns set 需要解析器地址'
            local type=udp host path=/dns-query port=''
            if [[ $address == *://* ]]; then type=${address%%://*}; host=${address#*://}; else host=$address; fi
            if [[ $host == */* ]]; then path=/${host#*/}; host=${host%%/*}; fi
            if [[ $host == \[*\]:* || ( $host == *:* && $host != *:*:* ) ]]; then split_authority "$host"; host=$URI_SERVER; port=$URI_PORT; fi
            case $type in udp|tcp|tls|https|quic|h3) ;; *) die '不支持的 DNS 类型';; esac
            valid_host "$host" && no_controls "$path" || die 'DNS 地址无效'
            dns=$(jq -n --arg t "$type" --arg h "$host" --arg p "$path" --arg port "$port" '{type:$t,server:$h}+(if $t=="https" or $t=="h3" then {path:$p} else {} end)+(if $port!="" then {server_port:($port|tonumber)} else {} end)');;
        *) die '未知 DNS 选项';;
    esac
    with_lock _set_dns "$dns"
    note '全局 DNS 已更新，影响所有节点'
}
_set_dns() { local state; state=$(read_state | jq --argjson dns "$1" '.settings.dns=$dns'); _apply_state "$state"; }
website_set() {
    local domain=$1 web=${2:-} port=${3:-443} profile=${4:-default} cert state record
    valid_domain "$domain" || die '网站域名无效'; port=$(checked_port "$port"); nginx_web "$web" >/dev/null
    cert=$(certificate_for_domain "$(read_state)" "$domain")
    [[ -n $cert ]] || cert=$(cert_issue "$domain" "$profile")
    record=$(jq -n --arg d "$domain" --arg w "$web" --arg c "$cert" --argjson p "$port" '{domain:$d,port:$p,web:$w,certificate_id:$c}')
    with_lock _website_set "$record"
}
_website_set() { local state; state=$(read_state | jq --argjson w "$1" '.websites=(.websites|map(select(.domain!=$w.domain)))+[$w]'); _apply_state "$state"; }
_website_delete() { local state; state=$(read_state | jq --arg d "$1" '.websites|=map(select(.domain!=$d))'); _apply_state "$state"; }
update_core() {
    local version=${1:-1.14.4} temp previous="$SB_CORE.previous"
    temp=$(mktemp "$SB_ROOT/run/core.XXXXXXXX")
    download_core "$version" "$temp"
    "$temp" check -c "$SB_ROOT/current/config.json" >/dev/null || die '新内核不支持当前配置'
    cp -p "$SB_CORE" "$previous"
    install -m 755 "$temp" "$SB_CORE.new"; mv -f "$SB_CORE.new" "$SB_CORE"
    if ! SB_FORCE_CORE=1 "$SB_HOME/bin/sb" fix-all; then
        mv -f "$previous" "$SB_CORE"; service_action core restart
        die '内核更新失败，已恢复旧内核'
    fi
    rm -f "$temp"
}
bbr_enable() {
    [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]] || die '当前内核不提供拥塞控制信息'
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || die '内核未提供 BBR；不加载宿主模块'
    [[ ! -f /.dockerenv ]] || die '不在容器中修改 BBR；请在目标 Linux 主机执行'
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-sb-manager-bbr.conf
    sysctl -p /etc/sysctl.d/90-sb-manager-bbr.conf
}
