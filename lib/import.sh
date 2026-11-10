#!/usr/bin/env bash
# Import accepts data only. Legacy scripts, shell fragments and hooks are never sourced.
reality_public_key() {
    local private=$1 temp
    temp=$(mktemp "$SB_ROOT/run/x25519.XXXXXXXX")
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20' > "$temp"
    b64decode "$private" >> "$temp"
    openssl pkey -inform DER -in "$temp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
    rm -f "$temp"
}
import_preview_file() {
    local file=$1 raw inbound protocol transport security id uuid password domain port path private public short certchain certkey node
    raw=$(jq . "$file") || die '导入只接受有效 JSON 配置，不执行旧脚本'
    jq -e '(.inbounds|length)==1' <<< "$raw" >/dev/null || die '仅支持单入口文件；共享监听或多入口需先人工拆分'
    if jq -e '.inbounds[0].protocol!=null' <<< "$raw" >/dev/null; then
        raw=$(jq -f "$SB_HOME/jq/import-xray.jq" <<< "$raw") || die 'Xray/V2Ray 配置无法等价转换'
    fi
    jq -e '((.route.rules//[])|length)==0 and ((.inbounds[0].users//[])|length)<=1 and ((.outbounds//[])|all(.type=="direct"))' <<< "$raw" >/dev/null || die '拒绝复杂路由、多用户或非直连的隐式出口转换'
    inbound=$(jq '.inbounds[0]' <<< "$raw")
    jq -e 'all(keys[];IN("type","tag","listen","listen_port","users","password","method","tls","transport","override_address","override_port","congestion_control"))' <<< "$inbound" >/dev/null || die '入口含未支持字段，拒绝丢失原行为'
    protocol=$(jq -r .type <<< "$inbound"); transport=$(jq -r '.transport.type//"tcp"' <<< "$inbound")
    security=$(jq -r 'if .tls.reality.enabled then "reality" elif .tls.enabled then "tls" else "none" end' <<< "$inbound")
    jq -e '(.users//[]|all((.alterId//0)==0)) and
      (.tls//{}|all(keys[];IN("enabled","server_name","certificate_path","key_path","reality","alpn"))) and
      (.transport//{}|all(keys[];IN("type","host","path","headers"))) and
      ((.transport.headers//{})|all(keys[];IN("host","Host")))' <<< "$inbound" >/dev/null || die '存在无法等价保留的 TLS、传输或用户参数'
    # In the legacy Caddy topology TLS was outside sing-box; use a safe domain
    # from its explicit Host and require an existing manager certificate on apply.
    local legacy_external=false
    if [[ $security == none && $transport != tcp && $(jq -r '.listen//""' <<< "$inbound") == 127.0.0.1 ]]; then
        domain=$(jq -r '.transport.headers.Host//.transport.headers.host//(.transport.host|if type=="array" then .[0] else . end)//empty' <<< "$inbound")
        if [[ -n $domain ]] && valid_domain "$domain"; then security=tls; legacy_external=true; fi
    fi
    case $protocol in
        vless)
            if [[ $security == reality ]]; then [[ $transport != http ]] && protocol=vless-reality || protocol=vless-http2-reality
            elif [[ $security == tls && $transport != tcp ]]; then [[ $transport != http ]] || transport=h2; protocol="vless-$transport-tls"
            else die '此 VLESS 入口不在上游兼容矩阵中'; fi;;
        vmess|trojan)
            if [[ $protocol == trojan && $transport == tcp ]]; then :
            elif [[ $security == tls && $transport != quic ]]; then [[ $transport != http ]] || transport=h2; protocol="$protocol-$transport-tls"
            else protocol="$protocol-$transport"; fi;;
        shadowsocks|socks|tuic|hysteria2|anytls|direct) ;;
        *) die '不支持的入口类型';;
    esac
    protocol=$(normalize_protocol "$protocol")
    id=$(new_id); port=$(jq -r .listen_port <<< "$inbound"); port=$(checked_port "$port")
    domain=$(jq -r '.tls.server_name//.transport.headers.Host//.transport.headers.host//(.transport.host|if type=="array" then .[0] else . end)//empty' <<< "$inbound")
    uuid=$(jq -r '.users[0].uuid//empty' <<< "$inbound"); password=$(jq -r '.password//.users[0].password//empty' <<< "$inbound")
    path=$(jq -r '.transport.path//"/"' <<< "$inbound")
    private=$(jq -r '.tls.reality.private_key//empty' <<< "$inbound"); public=''; short=$(jq -r '.tls.reality.short_id[0]//""' <<< "$inbound")
    if [[ -n $private ]]; then public=$(reality_public_key "$private"); fi
    certchain=$(jq -r '.tls.certificate_path//empty' <<< "$inbound"); certkey=$(jq -r '.tls.key_path//empty' <<< "$inbound")
    if [[ $security == tls && -z $domain ]]; then
        [[ -f $certchain ]] || die 'TLS 导入需要源证书文件或明确域名'
        domain=$(openssl x509 -in "$certchain" -noout -ext subjectAltName | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -n 1)
    fi
    [[ $security != tls ]] || valid_domain "$domain" || die '无法确定 TLS 证书域名'
    local backend=0
    if [[ $protocol == *-tls ]]; then backend=$(free_port "$(read_state)"); fi
    node=$(jq -n --arg id "$id" --arg name "$(basename "$file" .json)" --arg proto "$protocol" --argjson port "$port" --argjson backend "$backend" \
      --arg address "$(detect_address)" --arg domain "$domain" --arg path "$path" --arg uuid "$uuid" --arg password "$password" --arg private "$private" --arg public "$public" --arg short "$short" --argjson i "$inbound" \
      '{id:$id,name:$name,protocol:$proto,port:$port,backend_port:$backend,address:$address,listen:"::",domain:$domain,path:$path,uuid:$uuid,password:$password,username:($i.users[0].username//"user"),method:($i.method//"2022-blake3-aes-128-gcm"),external_tls:false,certificate_id:"",web:"",target_server:($i.override_address//""),target_port:($i.override_port//0),outbound:{type:"direct"},reality:(if $private=="" then null else {sni:($i.tls.server_name//$i.tls.reality.handshake.server),private_key:$private,public_key:$public,short_id:$short} end)}')
    jq -n --argjson node "$node" --arg chain "$certchain" --arg key "$certkey" --arg security "$security" --argjson external "$legacy_external" '{node:$node,certificate:(if $security=="tls" then {chain:$chain,key:$key,legacy_external:$external} else null end)}'
}
import_command() (
    local source=/etc/sing-box/conf apply=false takeover=false file item plan='[]' node id
    if (( $# )) && [[ $1 != --* ]]; then source=$1; shift; fi
    while (( $# )); do case $1 in --apply) apply=true; shift;; --takeover) takeover=true; shift;; *) die '未知导入选项';; esac; done
    local files=()
    if [[ -d $source ]]; then
        for file in "$source/"*.json; do [[ ! -f $file ]] || files+=("$file"); done
    elif [[ -f $source ]]; then files+=("$source"); else die '导入源不存在'; fi
    (( ${#files[@]} )) || die '未找到 JSON 配置'
    for file in "${files[@]}"; do item=$(import_preview_file "$file"); plan=$(jq --argjson i "$item" '.+[$i]' <<< "$plan"); done
    if [[ $apply == false ]]; then printf '%s\n' "$plan" | redact_json; return; fi
    while IFS= read -r item; do
        node=$(jq .node <<< "$item")
        if [[ $(jq -r '.certificate!=null' <<< "$item") == true ]]; then
            local chain key self_signed=false
            chain=$(jq -r .certificate.chain <<< "$item"); key=$(jq -r .certificate.key <<< "$item")
            if [[ $(jq -r .certificate.legacy_external <<< "$item") == true ]]; then
                id=$(certificate_for_domain "$(read_state)" "$(jq -r .domain <<< "$node")")
                [[ -n $id ]] || die '旧反代 TLS 入口需要先用 cert issue/import 配置对应域名证书，不读取或修改 Caddy 私有目录'
            else
                [[ -f $chain && -f $key ]] || die '源证书文件缺失'
                if ! openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$chain" "$chain" >/dev/null 2>&1; then self_signed=true; fi
                id=$(cert_import "$(jq -r .domain <<< "$node")" "$chain" "$key" "$self_signed")
            fi
            node=$(jq --arg id "$id" '.certificate_id=$id' <<< "$node")
        fi
        plan=$(jq --argjson n "$node" 'map(if .node.id==$n.id then .node=$n else . end)' <<< "$plan")
    done < <(jq -c '.[]' <<< "$plan")
    if [[ $takeover == true && $SB_SERVICE_MODE == systemd ]]; then
        local legacy_units=() value import_committed=false rc=0
        for value in sing-box.service xray.service v2ray.service; do
            if systemctl is-active --quiet "$value"; then legacy_units+=("$value"); fi
        done
        trap 'rc=$?; if (( rc != 0 )) && [[ $import_committed == false ]]; then for value in "${legacy_units[@]}"; do systemctl start "$value" || true; done; fi; exit "$rc"' EXIT
        # The explicit flag authorizes stopping only known, previously active units.
        for value in "${legacy_units[@]}"; do systemctl stop "$value"; done
    fi
    with_lock _import_apply "$plan"
    import_committed=true
)
_import_apply() { local state; state=$(read_state | jq --argjson p "$1" '.nodes+=( $p|map(.node))'); _apply_state "$state"; }
