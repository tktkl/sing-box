#!/usr/bin/env bash
normalize_protocol() {
    local value=${1,,}
    case $value in
        r|reality|vless-reality) printf vless-reality;;
        rh2|vless-http2-reality) printf vless-http2-reality;;
        ss|shadowsocks) printf shadowsocks;;
        hy|hy2|hysteria2) printf hysteria2;;
        door|direct) printf direct;;
        tcp|http|quic|ws) printf 'vmess-%s' "$value";;
        wss) printf vmess-ws-tls;; h2) printf vmess-h2-tls;; hu) printf vmess-httpupgrade-tls;;
        vws) printf vless-ws-tls;; vh2) printf vless-h2-tls;; vhu) printf vless-httpupgrade-tls;;
        tws) printf trojan-ws-tls;; th2) printf trojan-h2-tls;; thu) printf trojan-httpupgrade-tls;;
        trojan|tuic|anytls|socks|vmess-tcp|vmess-http|vmess-quic|vmess-ws|vmess-ws-tls|vmess-h2-tls|vmess-httpupgrade-tls|vless-ws-tls|vless-h2-tls|vless-httpupgrade-tls|trojan-ws-tls|trojan-h2-tls|trojan-httpupgrade-tls) printf '%s' "$value";;
        *) die '未知协议，请查看 sb help';;
    esac
}
choose_value() {
    local input=${1:-} old=${2:-} fallback=${3:-}
    if [[ -n $input && $input != auto ]]; then printf %s "$input"
    elif [[ $input != auto && -n $old && $old != null ]]; then printf %s "$old"
    else printf %s "$fallback"; fi
}
probe_reality() {
    local sni=$1 output
    output=$(mktemp "$SB_ROOT/run/reality-probe.XXXXXXXX")
    if ! timeout 15 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 -alpn h2 -verify_return_error -brief </dev/null >"$output" 2>&1; then
        rm -f "$output"; die 'REALITY 握手目标 TLS 1.3 检测失败，请选择另一候选或使用 --skip-probe 离线配置'
    fi
    rm -f "$output"
}
build_node() {
    local protocol=$1 old=$2 preview=$3; shift 3
    protocol=$(normalize_protocol "$protocol")
    local args=() portflag='' addressflag='' domainflag='' profile=default certflag='' nameflag='' self_signed=false skipprobe=false external_tls=false
    local pathflag='' uuidflag='' passwordflag='' methodflag='' listenflag='' value
    if [[ $protocol == *-tls ]]; then external_tls=$(jq -r '.external_tls//false' <<< "$old"); fi
    while (( $# )); do
        case $1 in
            --port|--address|--cert-domain|--domain|--cf-profile|--certificate|--name|--path|--uuid|--password|--method|--listen)
                (( $# >= 2 )) || die '选项缺少参数'; value=$2
                case $1 in
                    --port) portflag=$value;; --address) addressflag=$value;; --cert-domain|--domain) domainflag=$value;;
                    --cf-profile) profile=$value;; --certificate) certflag=$value;; --name) nameflag=$value;;
                    --path) pathflag=$value;; --uuid) uuidflag=$value;; --password) passwordflag=$value;;
                    --method) methodflag=$value;; --listen) listenflag=$value;;
                esac
                shift 2;;
            --self-signed) self_signed=true; shift;;
            --skip-probe) skipprobe=true; shift;;
            --no-auto-tls) external_tls=true; shift;;
            --*) die '未知添加选项';;
            *) args+=("$1"); shift;;
        esac
    done
    (( ${#args[@]} <= 3 )) || die '位置参数过多'
    local state id name port backend=0 address domain path uuid password username method reality='null' certificate_id='' target='' targetport=0
    state=$(read_state)
    id=$(jq -r '.id//empty' <<< "$old"); [[ -n $id ]] || id=$(new_id)
    name=$(choose_value "$nameflag" "$(jq -r '.name//empty' <<< "$old")" "$id")
    no_controls "$name" && (( ${#name} <= 100 )) || die '节点名称无效'
    address=$(choose_value "$addressflag" "$(jq -r '.address//empty' <<< "$old")" '')
    [[ -n $address ]] || address=$(detect_address)
    valid_host "$address" || die '无效连接地址'
    uuid=$(choose_value "$uuidflag" "$(jq -r '.uuid//empty' <<< "$old")" "$(core generate uuid)")
    password=$(choose_value "$passwordflag" "$(jq -r '.password//empty' <<< "$old")" "$(openssl rand -base64 24)")
    username=$(choose_value '' "$(jq -r '.username//empty' <<< "$old")" user)
    method=$(choose_value "$methodflag" "$(jq -r '.method//empty' <<< "$old")" 2022-blake3-aes-128-gcm)
    domain=$(choose_value "$domainflag" "$(jq -r '.domain//empty' <<< "$old")" '')
    path=$(choose_value "$pathflag" "$(jq -r '.path//empty' <<< "$old")" "/$(openssl rand -hex 6)")
    listenflag=$(choose_value "$listenflag" "$(jq -r '.listen//empty' <<< "$old")" '::')
    [[ $listenflag == '::' || $listenflag == 0.0.0.0 || $listenflag == 127.0.0.1 || $listenflag == ::1 ]] || die '无效监听地址'
    if [[ $protocol == *-tls ]]; then
        domain=$(choose_value "${args[0]:-}" "$domain" '')
        if [[ $protocol == trojan-* ]]; then password=$(choose_value "${args[1]:-}" "$password" "$(openssl rand -base64 24)")
        else uuid=$(choose_value "${args[1]:-}" "$uuid" "$(core generate uuid)"); fi
        path=$(choose_value "${args[2]:-}" "$path" "/$(openssl rand -hex 6)")
        port=$(choose_value "$portflag" "$(jq -r '.port//empty' <<< "$old")" "$(free_port "$state")")
        backend=$(choose_value '' "$(jq -r '.backend_port//empty|select(.>0)' <<< "$old")" "$(free_port "$state")")
        [[ $port != "$backend" ]] || backend=$(free_port "$state")
    else
        port=$(choose_value "${portflag:-${args[0]:-}}" "$(jq -r '.port//empty' <<< "$old")" "$(free_port "$state")")
        case $protocol in
            vless-*|vmess-*|tuic) uuid=$(choose_value "${args[1]:-}" "$uuid" "$(core generate uuid)");;
            shadowsocks)
                method=$(choose_value "${methodflag:-${args[2]:-}}" "$method" 2022-blake3-aes-128-gcm)
                local bytes=32
                [[ $method != 2022-blake3-aes-128-gcm ]] || bytes=16
                password=$(choose_value "${passwordflag:-${args[1]:-}}" "$(jq -r '.password//empty' <<< "$old")" "$(openssl rand -base64 "$bytes")");;
            socks)
                username=$(choose_value "${args[1]:-}" "$username" user)
                password=$(choose_value "${passwordflag:-${args[2]:-}}" "$password" "$(openssl rand -base64 24)");;
            direct)
                target=$(choose_value "${args[1]:-}" "$(jq -r '.target_server//empty' <<< "$old")" '')
                targetport=$(choose_value "${args[2]:-}" "$(jq -r '.target_port//empty|select(.>0)' <<< "$old")" '')
                valid_host "$target" || die 'door 需要有效目标地址'
                targetport=$(checked_port "$targetport");;
            *) password=$(choose_value "${passwordflag:-${args[1]:-}}" "$password" "$(openssl rand -base64 24)");;
        esac
        [[ $protocol != anytls || -z ${args[2]:-} ]] || domain=${args[2]}
    fi
    port=$(checked_port "$port")
    valid_uuid "$uuid" || die 'UUID 格式无效'
    no_controls "$password" && no_controls "$username" || die '认证信息不允许控制字符'
    [[ $path =~ ^/[a-zA-Z0-9_./~-]*$ && $path != /._sb_health_* ]] || die '路径必须是安全的绝对 URL 路径'
    if [[ $protocol == *reality ]]; then
        local sni keys private public short
        sni=$(choose_value "${args[2]:-}" "$(jq -r '.reality.sni//empty' <<< "$old")" apps.mzstatic.com)
        valid_host "$sni" || die 'SNI 无效'
        private=$(jq -r '.reality.private_key//empty' <<< "$old"); public=$(jq -r '.reality.public_key//empty' <<< "$old")
        if [[ -z $private || -z $public ]]; then
            keys=$(core generate reality-keypair)
            private=$(awk '/^PrivateKey:/ {print $2}' <<< "$keys"); public=$(awk '/^PublicKey:/ {print $2}' <<< "$keys")
        fi
        short=$(choose_value '' "$(jq -r '.reality.short_id//empty' <<< "$old")" "$(openssl rand -hex 8)")
        reality=$(jq -n --arg sni "$sni" --arg private "$private" --arg public "$public" --arg short "$short" '{sni:$sni,private_key:$private,public_key:$public,short_id:$short}')
        [[ $preview == true || $skipprobe == true ]] || probe_reality "$sni"
    fi
    if [[ $protocol == *-tls || $protocol == trojan || $protocol == hysteria2 || $protocol == tuic || $protocol == anytls || $protocol == vmess-quic ]]; then
        if [[ -z $domain && -t 0 ]]; then read -r -p '证书域名（你控制的域名）: ' domain; fi
        valid_domain "$domain" || die '此协议需要 --cert-domain 或域名位置参数；自签模式也需提供域名'
        if [[ $external_tls == true ]]; then
            [[ $protocol == *-tls ]] || die 'no-auto-tls 仅用于 HTTP 类 TLS 入口'
        else
            certificate_id=$certflag
            [[ -n $certificate_id ]] || certificate_id=$(certificate_for_domain "$state" "$domain")
            if [[ -z $certificate_id ]]; then
                if [[ $preview == true ]]; then certificate_id='preview-certificate'
                elif [[ $self_signed == true ]]; then certificate_id=$(cert_self_signed "$domain")
                else certificate_id=$(cert_issue "$domain" "$profile"); fi
            fi
            if [[ $preview != true ]]; then
                local cert; cert=$(read_state | jq --arg id "$certificate_id" '.certificates[]|select(.id==$id)')
                [[ -n $cert ]] || die '证书不存在'
                openssl x509 -in "$(jq -r .version_dir <<< "$cert")/fullchain.pem" -noout -checkhost "$domain" >/dev/null || die '证书不覆盖节点域名'
            fi
        fi
    elif [[ $external_tls == true ]]; then die '此协议不支持 no-auto-tls'; fi
    [[ $preview == true || $skipprobe == true ]] || endpoint_check "$address" "$protocol" "$port"
    jq -n --arg id "$id" --arg name "$name" --arg protocol "$protocol" --argjson port "$port" --argjson backend "$backend" --arg address "$address" --arg listen "$listenflag" \
       --arg uuid "$uuid" --arg password "$password" --arg username "$username" --arg method "$method" --arg domain "$domain" --arg path "$path" \
       --argjson reality "$reality" --arg certificate "$certificate_id" --argjson external "$external_tls" --arg target "$target" --argjson targetport "$targetport" --argjson old "$old" \
       '{id:$id,name:$name,protocol:$protocol,port:$port,backend_port:$backend,address:$address,listen:$listen,uuid:$uuid,password:$password,username:$username,method:$method,domain:$domain,path:$path,
        reality:$reality,certificate_id:$certificate,external_tls:$external,target_server:$target,target_port:$targetport,web:($old.web//""),outbound:($old.outbound//{type:"direct"})}'
}
_save_node() {
    local node=$1 expected=$2 state id existing
    state=$(read_state); id=$(jq -r .id <<< "$node")
    existing=$(jq -cS --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$state")
    if [[ -n $expected ]]; then [[ $(hash_text "$existing") == "$expected" ]] || die '该节点已被其他操作修改，请重试'
    else [[ -z $existing ]] || die '节点 ID 已存在'; fi
    state=$(jq --argjson node "$node" '.nodes=(.nodes|map(select(.id!=$node.id)))+[$node]' <<< "$state")
    _apply_state "$state"
}
save_node() {
    local node=$1 old=${2:-} expected=''
    [[ -z $old ]] || expected=$(hash_text "$(jq -cS . <<< "$old")")
    with_lock _save_node "$node" "$expected"
}
add_node() {
    local protocol=${1:-reality}; (( $# == 0 )) || shift
    local node; node=$(build_node "$protocol" '{}' false "$@")
    save_node "$node"
    jq '{id,name,protocol,port,backend_port,address,domain,outbound:{type:.outbound.type}}' <<< "$node"
}
change_node() {
    local selector=${1:-} option=${2:-} node old value
    (( $# < 1 )) || shift; (( $# < 1 )) || shift
    old=$(select_node "$selector"); node=$old
    case $option in
        name)
            value=${1:-}; no_controls "$value" && (( ${#value} <= 100 )) || die '节点名称无效'
            node=$(json_set "$old" name "$value");;
        address)
            value=${1:-}; valid_host "$value" || die '无效连接地址'
            endpoint_check "$value" "$(jq -r .protocol <<< "$old")" "$(jq -r .port <<< "$old")"
            node=$(json_set "$old" address "$value");;
        username)
            [[ $(jq -r .protocol <<< "$old") == socks ]] || die '此节点没有 Socks 用户名'
            value=${1:-}; [[ -n $value ]] && no_controls "$value" || die '用户名无效'
            node=$(json_set "$old" username "$value");;
        new) (( $# > 0 )) || die 'new 需要指定新协议'; node=$(build_node "$1" "$old" false "${@:2}");;
        full) node=$(build_node "$(jq -r .protocol <<< "$old")" "$old" false "$@");;
        outbound)
            value=${1:-}
            if [[ -z $value ]]; then
                if [[ -t 0 ]]; then read -rs -p '出口链接或 direct: ' value; printf '\n' >&2
                else IFS= read -r value || [[ -n ${value:-} ]]; fi
            fi
            value=$(outbound_from_uri "$value"); node=$(jq --argjson out "$value" '.outbound=$out' <<< "$old");;
        port)
            value=${1:-auto}; [[ $value != auto ]] || value=$(free_port "$(read_state)")
            value=$(checked_port "$value"); node=$(jq --argjson v "$value" '.port=$v' <<< "$old");;
        id)
            jq -e '.protocol|test("^(vmess|vless)|^tuic$")' <<< "$old" >/dev/null || die '此节点没有 UUID'
            value=${1:-auto}; [[ $value != auto ]] || value=$(core generate uuid)
            valid_uuid "$value" || die 'UUID 格式无效'; node=$(json_set "$old" uuid "$value");;
        passwd)
            jq -e '.protocol|test("^shadowsocks$|^socks$|^trojan|^hysteria2$|^tuic$|^anytls$")' <<< "$old" >/dev/null || die '此节点使用 UUID，不使用密码'
            value=${1:-auto}
            if [[ $value == auto ]]; then
                local bytes=24 method; method=$(jq -r .method <<< "$old")
                if [[ $(jq -r .protocol <<< "$old") == shadowsocks ]]; then [[ $method != 2022-blake3-aes-128-gcm ]] || bytes=16; [[ $method != 2022-blake3-aes-256-gcm && $method != 2022-blake3-chacha20-poly1305 ]] || bytes=32; fi
                value=$(openssl rand -base64 "$bytes")
            fi
            no_controls "$value" || die '密码不允许控制字符'; node=$(json_set "$old" password "$value");;
        method)
            [[ $(jq -r .protocol <<< "$old") == shadowsocks ]] || die '此节点没有 SS 加密方式'
            value=${1:-2022-blake3-aes-128-gcm}; [[ $value != auto ]] || value=2022-blake3-aes-128-gcm
            node=$(json_set "$old" method "$value")
            case $value in 2022-blake3-aes-128-gcm) node=$(json_set "$node" password "$(openssl rand -base64 16)");; 2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) node=$(json_set "$node" password "$(openssl rand -base64 32)");; esac;;
        sni)
            [[ $(jq -r .protocol <<< "$old") == *reality ]] || die 'sni 快捷命令用于 REALITY；证书域名使用 host 修改'
            value=${1:-apps.mzstatic.com}; [[ $value != auto ]] || value=apps.mzstatic.com
            valid_host "$value" || die 'SNI 无效'
            [[ ${2:-} == --skip-probe ]] || probe_reality "$value"
            node=$(jq --arg v "$value" '.reality.sni=$v' <<< "$old");;
        key)
            [[ $(jq -r .protocol <<< "$old") == *reality ]] || die '此节点没有 REALITY 密钥'
            local private public keys
            if [[ ${1:-auto} == auto ]]; then keys=$(core generate reality-keypair); private=$(awk '/^PrivateKey:/{print $2}' <<< "$keys"); public=$(awk '/^PublicKey:/{print $2}' <<< "$keys")
            else private=$1; public=${2:-}; fi
            [[ $private =~ ^[a-zA-Z0-9_-]{43}$ && $public =~ ^[a-zA-Z0-9_-]{43}$ ]] || die '需要有效私钥及对应公钥'
            [[ $(reality_public_key "$private") == "$public" ]] || die 'REALITY 公钥与私钥不匹配'
            node=$(jq --arg p "$private" --arg q "$public" '.reality.private_key=$p|.reality.public_key=$q' <<< "$old");;
        path)
            jq -e '.protocol|test("^vmess-(ws|http)$|-(ws|h2|httpupgrade)-tls$|^vless-http2-reality$")' <<< "$old" >/dev/null || die '此入口没有可修改的 HTTP 路径'
            value=${1:-auto}; [[ $value != auto ]] || value="/$(openssl rand -hex 6)"
            [[ $value =~ ^/[a-zA-Z0-9_./~-]*$ && $value != /._sb_health_* ]] || die '路径无效'
            node=$(json_set "$old" path "$value");;
        host)
            jq -e '.protocol|test("-tls$|^trojan$|^hysteria2$|^tuic$|^anytls$|^vmess-quic$")' <<< "$old" >/dev/null || die '此入口不使用自有证书域名'
            [[ -n ${1:-} ]] || die 'host 需要域名'
            node=$(build_node "$(jq -r .protocol <<< "$old")" "$old" false --cert-domain "$1" "${@:2}");;
        web)
            jq -e '.protocol|endswith("-tls")' <<< "$old" >/dev/null || die '此入口没有 Nginx HTTP 伪装；独立站点使用 web --domain'
            [[ $(jq -r .external_tls <<< "$old") == false ]] || die '外部 TLS 代理模式没有受管 Nginx 网站'
            value=${1:-}; nginx_web "$value" >/dev/null; node=$(json_set "$old" web "$value");;
        *) die '未知修改项';;
    esac
    save_node "$node" "$old"
    note "已修改节点 $(jq -r .id <<< "$node")"
}
delete_nodes() {
    local ids=$1; with_lock _delete_nodes "$ids"
}
_delete_nodes() { local state; state=$(read_state | jq --argjson ids "$1" '.nodes|=map(select(.id as $id|($ids|index($id))==null))'); _apply_state "$state"; }
gen_node() {
    local node state protocol=${1:-reality}; (( $# == 0 )) || shift
    node=$(build_node "$protocol" '{}' true "$@")
    state=$(read_state | jq --argjson n "$node" '.nodes=[$n]|.certificates+=[{id:"preview-certificate",version_dir:"/path/to/certificate",self_signed:false}]')
    render_config "$state"
}
