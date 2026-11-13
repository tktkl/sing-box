#!/usr/bin/env bash
SB_ROOT=${SB_ROOT:-/etc/sb-manager}
SB_CORE=${SB_CORE:-/usr/local/lib/sb-manager/core/sing-box}
SB_SERVICE_MODE=${SB_SERVICE_MODE:-systemd}
export SB_UNIT=sb-manager.service
export LC_ALL=C
umask 077

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null || die "缺少依赖: $1"; }
jarg() { jq -Rn --arg value "$1" '$value'; }
hash_file() { sha256sum "$1" | cut -d ' ' -f 1; }
hash_text() { printf %s "$1" | sha256sum | cut -d ' ' -f 1; }
new_id() { printf 'n-%s\n' "$(openssl rand -hex 8)"; }
stamp() { printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%S)" "$(openssl rand -hex 4)"; }
require_root() { (( EUID == 0 )) || die '请使用 sudo 运行管理命令'; }
valid_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z][a-zA-Z0-9-]{0,62}$ ]]; }
valid_host() { [[ $1 =~ ^[a-zA-Z0-9:.][-a-zA-Z0-9:.]*$ && $1 != *..* ]]; }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
no_controls() { [[ $1 != *[$'\001'-$'\037'$'\177']* ]]; }
checked_port() { valid_port "$1" || die '端口必须是 1..65535'; printf '%d\n' "$((10#$1))"; }
urlencode() { jq -rn --arg value "$1" '$value|@uri'; }
urldecode() {
    local value=$1 output='' piece hex
    while [[ -n $value ]]; do
        if [[ $value == %* ]]; then
            hex=${value:1:2}
            [[ $hex =~ ^[[:xdigit:]]{2}$ && $hex != 00 ]] || die '无效的 URL 转义'
            printf -v piece '%b' "\\x$hex"
            output+=$piece; value=${value:3}
        else
            output+=${value:0:1}; value=${value:1}
        fi
    done
    no_controls "$output" || die 'URL 不允许控制字符'
    printf %s "$output"
}
b64encode() { printf %s "$1" | base64 | tr -d '\n'; }
b64decode() {
    local value=${1//-/+}; value=${value//_/\/}
    [[ $value =~ ^[a-zA-Z0-9+/]*={0,2}$ ]] || die '无效的 Base64'
    while (( ${#value} % 4 )); do value+='='; done
    printf %s "$value" | base64 --decode 2>/dev/null || die '无效的 Base64'
}
json_set() { jq --arg key "$2" --arg value "$3" '.[$key]=$value' <<< "$1"; }
core() { [[ -x $SB_CORE ]] || die "找不到 sing-box 内核: $SB_CORE"; "$SB_CORE" "$@"; }
check_core_version() {
    local expected actual
    expected=$(jq -r .core_version "$SB_HOME/dependencies.lock.json")
    actual=$(core_binary_version "$SB_CORE")
    [[ $actual != "$expected" ]] || return 0
    if [[ -f $SB_ROOT/core-installed.json ]] &&
       jq -e --arg version "$actual" --arg hash "$(hash_file "$SB_CORE")" \
           '.validated==true and .version==$version and .binary_sha256==$hash' "$SB_ROOT/core-installed.json" >/dev/null; then return 0; fi
    die "当前内核 $actual 尚未经过管理器校验，请执行 sb update core；内置基准版本为 $expected"
}
with_lock() (
    local fd
    mkdir -p "$SB_ROOT"
    exec {fd}>"$SB_ROOT/.write.lock"
    flock -w 60 "$fd" || die '另一个管理操作正在运行'
    local SB_LOCK_FDS="${SB_LOCK_FDS:-} $fd"
    trap 'flock -u "$fd" || true' EXIT
    "$@"
)
without_locks() (
    local lock_fd
    for lock_fd in ${SB_LOCK_FDS:-}; do exec {lock_fd}>&-; done
    exec "$@"
)
close_inherited_locks() {
    local lock_fd
    for lock_fd in ${SB_LOCK_FDS:-}; do exec {lock_fd}>&-; done
}
download() {
    local url=$1 destination=$2 digest=${3:-}
    [[ $url == https://* ]] || die '下载地址必须使用 HTTPS'
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 300 --retry 3 --retry-all-errors --output "$destination.part" "$url"
    if [[ -n $digest && $(hash_file "$destination.part") != "$digest" ]]; then
        rm -f -- "$destination.part"; die '下载文件 SHA-256 不匹配'
    fi
    mv -f -- "$destination.part" "$destination"
}
default_state() {
    jq -n '{schema_version:1,settings:{log_level:"info",dns:{type:"local"},public_address:""},nodes:[],certificates:[],websites:[]}'
}
read_state() {
    [[ -e $SB_ROOT/current/settings.json ]] || { default_state; return; }
    local files=() file
    for file in "$SB_ROOT/current/nodes/"*.json; do [[ ! -f $file ]] || files+=("$file"); done
    if (( ${#files[@]} )); then jq -s . "${files[@]}"; else printf '[]\n'; fi |
        jq --slurpfile settings "$SB_ROOT/current/settings.json" \
           --slurpfile certs "$SB_ROOT/current/certificates.json" \
           --slurpfile websites "$SB_ROOT/current/websites.json" \
           '{schema_version:1,settings:$settings[0],nodes:.,certificates:$certs[0],websites:$websites[0]}'
}
select_node() {
    local query=${1:-} matches count choice
    matches=$(read_state | jq --arg q "${query,,}" '
      [.nodes[] | select($q=="" or (.id|ascii_downcase)==$q or
        (.port|tostring)==$q or (([.name,.protocol,.domain,.id]|join(" ")|ascii_downcase)|contains($q)))]')
    count=$(jq length <<< "$matches")
    (( count > 0 )) || die '没有匹配的节点'
    if (( count == 1 )) && [[ -n $query || ! -t 0 || ${SB_REQUIRE_UNIQUE:-0} == 1 ]]; then jq -c '.[0]' <<< "$matches"; return; fi
    [[ -t 0 && ${SB_REQUIRE_UNIQUE:-0} != 1 ]] || die '匹配多个节点，请使用永久 ID 或唯一端口'
    jq -r 'to_entries[]|"\(.key+1)) \(.value.id) \(.value.protocol) :\(.value.port) \(.value.name)"' <<< "$matches" >&2
    while true; do
        printf '0) 返回 / 取消\n' >&2
        read -r -p '选择节点序号: ' choice || return 2
        [[ $choice != 0 ]] || return 2
        if [[ $choice =~ ^[0-9]{1,6}$ ]] && (( 10#$choice >= 1 && 10#$choice <= count )); then
            jq -c --argjson i "$((10#$choice-1))" '.[$i]' <<< "$matches"; return
        fi
        note '序号无效，请重新选择'
    done
}
port_is_listening() {
    local port=$1
    [[ -n $(ss -H -lnut "sport = :$port" 2>/dev/null) ]]
}
free_port() {
    local state=$1 port tries=0
    while (( tries++ < 200 )); do
        port=$((20000 + $(od -An -N2 -tu2 /dev/urandom) % 40000))
        jq -e --argjson port "$port" 'all(.nodes[]; .port!=$port and .backend_port!=$port) and all(.websites[];.port!=$port)' <<< "$state" >/dev/null || continue
        port_is_listening "$port" || { printf '%s\n' "$port"; return; }
    done
    die '无法分配空闲端口'
}
detect_address() {
    local address
    address=$(read_state | jq -r '.settings.public_address')
    if [[ -z $address ]]; then
        address=$(curl --fail --silent --show-error --max-time 8 https://api.ipify.org 2>/dev/null) || true
    fi
    valid_host "$address" || die '无法确定公网地址，请使用 --address 显式指定'
    printf '%s\n' "$address"
}
endpoint_check() {
    local address=$1 protocol=$2 port=$3 resolved
    # Literal IP endpoints do not traverse a CDN based on the SNI value.
    [[ ! $address =~ ^[0-9.]+$ && $address != *:* ]] || return 0
    resolved=$(timeout 5 getent ahosts "$address" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -) || resolved=''
    if [[ -n $resolved ]]; then note "分享域名解析: $resolved"
    else note '分享域名尚未解析成功；当前无法确认客户端接入条件'; fi
    note 'Cloudflare 代理状态未自动确定，脚本只管理 ACME TXT；域名连接需自行确认灰云或代理兼容性'
    if [[ $protocol != *-tls && $protocol != vmess-ws ]]; then
        note '此入口使用原生代理传输，普通 Cloudflare 橙云不作为受支持的接入方式'
    elif [[ ! $port =~ ^(443|2053|2083|2087|2096|8443)$ ]]; then
        note '此公网端口不在普通 Cloudflare HTTPS 代理端口集合中，请使用灰云直连或公网 IP'
    fi
}
