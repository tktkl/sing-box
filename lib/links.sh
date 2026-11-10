#!/usr/bin/env bash
declare -A Q=()
parse_query() {
    local query=$1 pair key value
    Q=()
    [[ -n $query ]] || return 0
    local pairs=()
    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        [[ $pair == *=* ]] || die '链接查询参数必须是 key=value'
        key=$(urldecode "${pair%%=*}"); value=$(urldecode "${pair#*=}")
        case $key in
            encryption|security|type|host|path|sni|peer|flow|pbk|sid|fp|alpn|allowInsecure|insecure|headerType|serviceName|packetEncoding|congestion_control|udp_relay_mode|obfs|obfs-password|plugin) ;;
            *) die "不支持的链接参数: $key" ;;
        esac
        # Whitelist before an associative-array lookup (also safe on Bash 5.1).
        [[ -n $key && ! -v Q[$key] ]] || die '链接包含空参数名或重复参数'
        Q[$key]=$value
    done
}
uri_boolean() {
    case $1 in 1|true) printf true;; 0|false|'') printf false;; *) die '无效布尔参数';; esac
}
split_authority() {
    local authority=$1 serverpart
    URI_AUTH=''
    if [[ $authority == *@* ]]; then
        URI_AUTH=${authority%@*}; serverpart=${authority##*@}
        [[ $URI_AUTH != *@* ]] || die '认证信息中的 @ 必须经过 URL 编码'
    else serverpart=$authority; fi
    if [[ $serverpart == \[* ]]; then
        [[ $serverpart =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]] || die 'IPv6 必须使用 [地址]:端口'
        URI_SERVER=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[2]}
    else
        [[ $serverpart == *:* ]] || die '链接缺少端口'
        URI_SERVER=${serverpart%:*}; URI_PORT=${serverpart##*:}
        [[ $URI_SERVER != *:* ]] || die 'IPv6 必须使用方括号'
    fi
    valid_host "$URI_SERVER" || die '无效服务器地址'
    URI_PORT=$(checked_port "$URI_PORT")
}
uri_tls() {
    local security=$1 server=$2 tls='null' insecure=false sni fp
    sni=${Q[sni]:-${Q[peer]:-$server}}
    if [[ -v Q[insecure] ]]; then insecure=$(uri_boolean "${Q[insecure]}"); fi
    if [[ -v Q[allowInsecure] ]]; then
        local alternate; alternate=$(uri_boolean "${Q[allowInsecure]}")
        [[ ! -v Q[insecure] || $alternate == "$insecure" ]] || die 'TLS 校验参数冲突'
        insecure=$alternate
    fi
    case $security in
        ''|none)
            [[ $insecure == false ]] || die '无 TLS 时不能设置 insecure'
            for sni in sni peer alpn fp pbk sid; do [[ ! -v Q[$sni] ]] || die 'TLS 参数要求启用 TLS'; done;;
        tls|reality)
            valid_host "$sni" || die '无效 SNI'
            tls=$(jq -n --arg sni "$sni" --argjson insecure "$insecure" '{enabled:true,server_name:$sni,insecure:$insecure}')
            if [[ -n ${Q[alpn]:-} ]]; then tls=$(jq --arg v "${Q[alpn]}" '.alpn=($v|split(","))' <<< "$tls"); fi
            fp=${Q[fp]:-}
            [[ $security != reality || -n $fp ]] || fp=chrome
            if [[ -n $fp ]]; then
                case $fp in chrome|firefox|edge|safari|360|qq|ios|android|random|randomized) ;;
                    *) die '不支持的 TLS 指纹';; esac
                tls=$(jq --arg fp "$fp" '.utls={enabled:true,fingerprint:$fp}' <<< "$tls")
            fi
            if [[ $security == reality ]]; then
                [[ ${Q[pbk]:-} =~ ^[a-zA-Z0-9_-]{43}$ ]] || die 'REALITY 缺少有效公钥'
                [[ ${Q[sid]:-} =~ ^([0-9a-fA-F]{2}){0,8}$ ]] || die '无效 REALITY short ID'
                [[ $insecure == false ]] || die 'REALITY 不接受 insecure'
                tls=$(jq --arg key "${Q[pbk]}" --arg sid "${Q[sid]:-}" '.reality={enabled:true,public_key:$key,short_id:$sid}' <<< "$tls")
            elif [[ -v Q[pbk] || -v Q[sid] ]]; then die 'REALITY 参数要求 security=reality'; fi
            ;;
        *) die '不支持的 security 参数';;
    esac
    printf '%s\n' "$tls"
}
uri_transport() {
    local transport=${Q[type]:-tcp} host=${Q[host]:-} path=${Q[path]:-/}
    case $transport in
        tcp|none)
            case ${Q[headerType]:-none} in
                none|'') printf null;;
                http) jq -n --arg host "$host" --arg path "$path" '{type:"http",path:$path} + (if $host=="" then {} else {host:($host|split(","))} end)';;
                *) die '不支持的 TCP headerType';;
            esac;;
        ws) jq -n --arg path "$path" --arg host "$host" '{type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end)';;
        http|h2) jq -n --arg path "$path" --arg host "$host" '{type:"http",path:$path}+(if $host=="" then {} else {host:($host|split(","))} end)';;
        httpupgrade) jq -n --arg path "$path" --arg host "$host" '{type:"httpupgrade",path:$path}+(if $host=="" then {} else {host:$host} end)';;
        quic) printf '{"type":"quic"}\n';;
        grpc) die '首版不支持上游未列出的 gRPC 传输';;
        *) die '不支持的传输类型';;
    esac
}
outbound_from_uri() {
    local link=$1 scheme payload query='' data auth method password type tls transport result key
    [[ ${#link} -le 32768 ]] || die '链接过长'
    no_controls "$link" || die '链接不允许控制字符'
    if [[ $link == direct || $link == direct:// ]]; then printf '{"type":"direct"}\n'; return; fi
    [[ $link == *://* ]] || die '请提供节点链接或 direct'
    scheme=${link%%://*}; scheme=${scheme,,}; payload=${link#*://}; payload=${payload%%#*}
    if [[ $scheme == vmess ]]; then
        data=$(b64decode "$payload")
        jq -e 'type=="object" and (.add|type)=="string" and (.id|type)=="string"' <<< "$data" >/dev/null || die '无效 VMess JSON'
        jq -e 'all(keys[]; IN("v","ps","add","port","id","aid","scy","net","type","host","path","tls","sni","alpn","fp","allowInsecure"))' <<< "$data" >/dev/null || die 'VMess JSON 包含不支持字段'
        [[ $(jq -r '.aid//0|tostring' <<< "$data") == 0 ]] || die '只支持 VMess AEAD (alterId=0)'
        URI_SERVER=$(jq -r .add <<< "$data"); URI_PORT=$(jq -r '.port|tostring' <<< "$data"); URI_AUTH=$(jq -r .id <<< "$data")
        valid_host "$URI_SERVER" && valid_uuid "$URI_AUTH" || die '无效 VMess 服务器或 UUID'
        URI_PORT=$(checked_port "$URI_PORT")
        Q=(); Q[type]=$(jq -r '.net//"tcp"' <<< "$data"); Q[security]=$(jq -r '.tls//"none"|if .=="" then "none" else . end' <<< "$data")
        for key in host path sni alpn fp allowInsecure; do
            if jq -e --arg k "$key" 'has($k) and .[$k]!=null and .[$k]!=""' <<< "$data" >/dev/null; then Q[$key]=$(jq -r --arg k "$key" '.[$k]|tostring' <<< "$data"); fi
        done
        Q[headerType]=$(jq -r '.type//"none"' <<< "$data")
        tls=$(uri_tls "${Q[security]}" "$URI_SERVER"); transport=$(uri_transport)
        result=$(jq -n --arg server "$URI_SERVER" --argjson port "$URI_PORT" --arg uuid "$URI_AUTH" --arg security "$(jq -r '.scy//"auto"' <<< "$data")" --argjson tls "$tls" --argjson transport "$transport" '{type:"vmess",server:$server,server_port:$port,uuid:$uuid,security:$security} + (if $tls==null then {} else {tls:$tls} end)+(if $transport==null then {} else {transport:$transport} end)')
        printf '%s\n' "$result"; return
    fi
    if [[ $payload == *\?* ]]; then query=${payload#*\?}; payload=${payload%%\?*}; fi
    parse_query "$query"
    if [[ $scheme == ss && $payload != *@* ]]; then payload=$(b64decode "$payload"); fi
    payload=${payload%/}
    split_authority "$payload"
    case $scheme in
        ss)
            [[ -z ${Q[plugin]:-} ]] || die '不支持 Shadowsocks plugin'
            [[ $URI_AUTH == *:* ]] && auth=$(urldecode "$URI_AUTH") || auth=$(b64decode "$URI_AUTH")
            [[ $auth == *:* ]] || die 'SS 链接缺少 method:password'
            method=${auth%%:*}; password=${auth#*:}
            no_controls "$password" || die '密码不允许控制字符'
            for key in "${!Q[@]}"; do [[ $key == plugin ]] || die "SS 不支持参数: $key"; done
            jq -n --arg server "$URI_SERVER" --argjson port "$URI_PORT" --arg method "$method" --arg password "$password" '{type:"shadowsocks",server:$server,server_port:$port,method:$method,password:$password}';;
        socks|socks5)
            [[ ${#Q[@]} == 0 ]] || die 'SOCKS 链接不支持查询参数'
            [[ $URI_AUTH == *:* ]] && auth=$(urldecode "$URI_AUTH") || auth=$(b64decode "$URI_AUTH")
            [[ $auth == *:* ]] || die 'SOCKS 链接需要认证信息'
            jq -n --arg server "$URI_SERVER" --argjson port "$URI_PORT" --arg user "${auth%%:*}" --arg pass "${auth#*:}" '{type:"socks",version:"5",server:$server,server_port:$port,username:$user,password:$pass}';;
        vless|trojan|anytls|hysteria2|hy2|tuic)
            [[ -z ${Q[encryption]:-} || ${Q[encryption]} == none ]] || die '只支持 encryption=none'
            type=$scheme; [[ $type != hy2 ]] || type=hysteria2
            auth=$(urldecode "$URI_AUTH"); [[ -n $auth ]] || die '链接缺少认证信息'
            local security=${Q[security]:-tls}
            [[ $type != vless || -v Q[security] ]] || security=none
            tls=$(uri_tls "$security" "$URI_SERVER")
            [[ $type == vless || $tls != null ]] || die '此协议需要 TLS'
            [[ $type == vless || $security != reality ]] || die 'REALITY 出口仅支持 VLESS'
            transport=null
            if [[ $type == vless || $type == trojan ]]; then transport=$(uri_transport)
            elif [[ -v Q[type] || -v Q[host] || -v Q[path] || -v Q[flow] ]]; then die '此协议不支持 V2Ray 传输参数'; fi
            result=$(jq -n --arg type "$type" --arg server "$URI_SERVER" --argjson port "$URI_PORT" --argjson tls "$tls" --argjson transport "$transport" '{type:$type,server:$server,server_port:$port}+(if $tls==null then {} else {tls:$tls} end)+(if $transport==null then {} else {transport:$transport} end)')
            if [[ $type == vless ]]; then
                valid_uuid "$auth" || die '无效 VLESS UUID'
                case ${Q[flow]:-} in ''|xtls-rprx-vision) ;; *) die '无效 VLESS flow';; esac
                [[ -z ${Q[flow]:-} || $transport == null ]] || die 'Vision 只支持 TCP'
                result=$(jq --arg uuid "$auth" --arg flow "${Q[flow]:-}" '.uuid=$uuid|.flow=$flow' <<< "$result")
                if [[ -v Q[packetEncoding] ]]; then
                    case ${Q[packetEncoding]} in ''|xudp|packetaddr) ;; *) die '不支持的 UDP 编码';; esac
                    result=$(jq --arg v "${Q[packetEncoding]}" '.packet_encoding=$v' <<< "$result")
                fi
            elif [[ $type == tuic ]]; then
                [[ $auth == *:* ]] && valid_uuid "${auth%%:*}" || die 'TUIC 需要 UUID:password'
                case ${Q[congestion_control]:-cubic} in cubic|bbr|new_reno) ;; *) die '无效拥塞控制';; esac
                case ${Q[udp_relay_mode]:-native} in native|quic) ;; *) die '无效 UDP relay mode';; esac
                result=$(jq --arg uuid "${auth%%:*}" --arg password "${auth#*:}" --arg cc "${Q[congestion_control]:-cubic}" --arg mode "${Q[udp_relay_mode]:-native}" '.uuid=$uuid|.password=$password|.congestion_control=$cc|.udp_relay_mode=$mode' <<< "$result")
            else
                result=$(jq --arg password "$auth" '.password=$password' <<< "$result")
            fi
            if [[ -v Q[obfs] || -v Q[obfs-password] ]]; then
                [[ $type == hysteria2 && ${Q[obfs]:-} == salamander && -n ${Q[obfs-password]:-} ]] || die '无效 HY2 混淆参数'
                result=$(jq --arg password "${Q[obfs-password]}" '.obfs={type:"salamander",password:$password}' <<< "$result")
            fi
            for key in "${!Q[@]}"; do
                case $key in
                    plugin|serviceName|headerType) [[ $key == headerType && ( $type == vless || $type == trojan ) ]] || die "此协议不支持参数: $key";;
                    congestion_control|udp_relay_mode) [[ $type == tuic ]] || die "此协议不支持参数: $key";;
                    packetEncoding|flow) [[ $type == vless ]] || die "此协议不支持参数: $key";;
                    encryption) [[ $type == vless ]] || die "此协议不支持参数: $key";;
                    obfs|obfs-password) [[ $type == hysteria2 ]] || die "此协议不支持参数: $key";;
                esac
            done
            printf '%s\n' "$result";;
        *) die '不支持的链接协议';;
    esac
}
uri_from_outbound() {
    local out=$1 name=${2:-node} type server port auth result query='' transport security sni value key
    type=$(jq -r .type <<< "$out")
    [[ $type != direct ]] || { printf 'direct\n'; return; }
    server=$(jq -r .server <<< "$out"); port=$(jq -r .server_port <<< "$out")
    [[ $server != *:* ]] || server="[$server]"
    case $type in
        shadowsocks)
            auth=$(jq -r '.method+":"+.password' <<< "$out")
            printf 'ss://%s@%s:%s#%s\n' "$(b64encode "$auth")" "$server" "$port" "$(urlencode "$name")"; return;;
        socks)
            auth=$(jq -r '.username+":"+.password' <<< "$out")
            printf 'socks://%s@%s:%s#%s\n' "$(b64encode "$auth")" "$server" "$port" "$(urlencode "$name")"; return;;
        vmess)
            result=$(jq -c --arg name "$name" '{v:"2",ps:$name,add:.server,port:(.server_port|tostring),id:.uuid,aid:"0",scy:(.security//"auto"),net:(.transport.type//"tcp"|if .=="http" then "h2" else . end),type:"none",host:(.transport.headers.Host//.transport.host//""|if type=="array" then join(",") else . end),path:(.transport.path//"/"),tls:(if .tls.enabled then "tls" else "" end),sni:(.tls.server_name//""),alpn:(.tls.alpn//[]|join(",")),allowInsecure:(.tls.insecure//false)}' <<< "$out")
            printf 'vmess://%s\n' "$(b64encode "$result")"; return;;
        vless) auth=$(jq -r .uuid <<< "$out");;
        tuic) auth=$(jq -r '.uuid+":"+.password' <<< "$out");;
        trojan|anytls|hysteria2) auth=$(jq -r .password <<< "$out");;
        *) die '此类型没有通用分享链接';;
    esac
    if [[ $type == tuic ]]; then
        result="$type://${auth%%:*}:$(urlencode "${auth#*:}")@$server:$port"
    else result="$type://$(urlencode "$auth")@$server:$port"; fi
    security=$(jq -r 'if .tls.reality.enabled then "reality" elif .tls.enabled then "tls" else "none" end' <<< "$out")
    query="security=$security"
    if [[ $type == vless ]]; then query+='&encryption=none'; fi
    while IFS=$'\t' read -r key value; do
        [[ -n $value ]] || continue
        query+="&$key=$(urlencode "$value")"
    done < <(jq -r '[
        ["sni",.tls.server_name],["alpn",(.tls.alpn//[]|join(","))],
        ["fp",.tls.utls.fingerprint],["pbk",.tls.reality.public_key],["sid",.tls.reality.short_id],
        ["flow",.flow],["type",(.transport.type|if .=="http" then "h2" else . end)],["host",(.transport.headers.Host//.transport.host|if type=="array" then join(",") else . end)],
        ["path",.transport.path],["obfs",.obfs.type],["obfs-password",.obfs.password],
        ["congestion_control",.congestion_control],["udp_relay_mode",.udp_relay_mode]
        ][]|select(.[1]!=null and .[1]!="")|@tsv' <<< "$out")
    if [[ $(jq -r '.tls.insecure//false' <<< "$out") == true ]]; then query+='&insecure=1'; fi
    printf '%s?%s#%s\n' "$result" "$query" "$(urlencode "$name")"
}
