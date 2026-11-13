#!/usr/bin/env bash
# Interactive choices print to stderr; stdout is reserved for selected data.
ui_choose() {
    local title=$1 choice index=0 key label
    shift
    local keys=() labels=()
    while (( $# )); do keys+=("$1"); labels+=("$2"); shift 2; done
    while true; do
        printf '\n%s\n' "$title" >&2
        for index in "${!keys[@]}"; do printf '  %d) %s\n' "$((index+1))" "${labels[index]}" >&2; done
        printf '  0) 返回 / 取消\n' >&2
        IFS= read -r -p '请选择序号: ' choice || return 2
        [[ $choice != 0 ]] || return 2
        if [[ $choice =~ ^[0-9]{1,3}$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#keys[@]} )); then
            printf '%s\n' "${keys[10#$choice-1]}"; return
        fi
        note '序号无效，请重新选择'
    done
}
ui_prompt() {
    local fallback=${2:-} secret=${3:-false} value prompt="$1"
    [[ -z $fallback ]] || { if [[ $secret == true ]]; then prompt+='（回车自动生成或保留）'; else prompt+=" [$fallback]"; fi; }
    if [[ $secret == true ]]; then
        IFS= read -rs -p "$prompt: " value || return 2
        printf '\n' >&2
    else IFS= read -r -p "$prompt: " value || return 2; fi
    printf '%s\n' "${value:-$fallback}"
}
ui_confirm() {
    local choice
    choice=$(ui_choose "$1" yes '确认执行' no '取消') || return 2
    [[ $choice == yes ]] || return 2
}
ui_protocols() {
    cat <<'PROTOCOLS'
reality|VLESS-REALITY
rh2|VLESS-HTTP2-REALITY
ss|Shadowsocks
tcp|VMess TCP
http|VMess HTTP
ws|VMess WebSocket
quic|VMess QUIC（需要证书）
wss|VMess WebSocket + TLS
h2|VMess HTTP/2 + TLS
hu|VMess HTTPUpgrade + TLS
vws|VLESS WebSocket + TLS
vh2|VLESS HTTP/2 + TLS
vhu|VLESS HTTPUpgrade + TLS
trojan|Trojan
tws|Trojan WebSocket + TLS
th2|Trojan HTTP/2 + TLS
thu|Trojan HTTPUpgrade + TLS
hy2|Hysteria2
tuic|TUIC
anytls|AnyTLS
socks|Socks5
door|端口转发（door）
PROTOCOLS
}
ui_protocol() {
    local key label options=()
    while IFS='|' read -r key label; do options+=("${key// /}" "$label"); done < <(ui_protocols)
    ui_choose '选择入口协议' "${options[@]}"
}
ui_sni() {
    local choice
    choice=$(ui_choose '选择 REALITY SNI / 握手目标' apps.mzstatic.com 'apps.mzstatic.com（推荐）' xp.apple.com 'xp.apple.com' custom '自定义域名') || return 2
    if [[ $choice == custom ]]; then ui_prompt 'SNI 域名' "${1:-}"; else printf '%s\n' "$choice"; fi
}
ui_method() {
    ui_choose '选择 Shadowsocks 加密方式' \
        2022-blake3-aes-128-gcm '2022-blake3-aes-128-gcm' \
        2022-blake3-aes-256-gcm '2022-blake3-aes-256-gcm' \
        2022-blake3-chacha20-poly1305 '2022-blake3-chacha20-poly1305' \
        aes-128-gcm 'aes-128-gcm' aes-256-gcm 'aes-256-gcm' chacha20-ietf-poly1305 'chacha20-ietf-poly1305'
}
ui_profile() {
    local file profile options=()
    for file in "$SB_ROOT/credentials/"*.ini; do
        [[ -f $file ]] || continue
        profile=${file##*/}; profile=${profile%.ini}; options+=("$profile" "$profile")
    done
    options+=('@new' '新增 Cloudflare Token 凭据')
    profile=$(ui_choose '选择 Cloudflare 凭据' "${options[@]}") || return 2
    if [[ $profile == @new ]]; then
        profile=$(ui_prompt '凭据名称' default)
        cert_token_set "$profile"
    fi
    printf '%s\n' "$profile"
}
ui_domain() {
    local domain options=()
    while IFS= read -r domain; do [[ -z $domain ]] || options+=("$domain" "$domain（已有证书）"); done < <(read_state | jq -r '[.certificates[].domains[]|select(startswith("*.")|not)]|unique[]')
    if (( ${#options[@]} )); then
        domain=$(ui_choose '选择证书域名' "${options[@]}" new '输入其他域名') || return 2
        [[ $domain != new ]] || domain=$(ui_prompt '你控制的证书域名' "${1:-}")
    else domain=$(ui_prompt '你控制的证书域名' "${1:-}"); fi
    valid_domain "$domain" || die '证书域名无效'
    printf '%s\n' "$domain"
}
# Populates the current wizard's argument array; credentials never enter argv.
ui_tls_args() {
    local domain=$1 certificate choice profile
    UI_NODE_ARGS+=(--cert-domain "$domain")
    certificate=$(certificate_for_domain "$(read_state)" "$domain")
    if [[ -n $certificate ]]; then UI_NODE_ARGS+=(--certificate "$certificate"); note "使用已有证书: $domain"; return; fi
    choice=$(ui_choose '该域名没有证书，选择证书方式' cloudflare 'Cloudflare DNS-01 签发可信证书' selfsigned '显式使用自签证书（客户端需允许自签）') || return 2
    if [[ $choice == selfsigned ]]; then UI_NODE_ARGS+=(--self-signed)
    else profile=$(ui_profile); UI_NODE_ARGS+=(--cf-profile "$profile"); fi
}
ui_node_inputs() {
    local protocol=$1 old=$2 port address name credential sni domain path method target target_port username
    UI_NODE_ARGS=()
    protocol=$(normalize_protocol "$protocol")
    port=$(ui_prompt '公网端口（auto 自动分配）' "$(jq -r '.port//"auto"' <<< "$old")")
    if [[ $port == auto ]]; then port=$(free_port "$(read_state)"); else port=$(checked_port "$port"); fi
    address=$(jq -r '.address//empty' <<< "$old")
    if [[ -z $address ]]; then address=$(detect_address) || address=''; fi
    address=$(ui_prompt '客户端连接地址（公网 IP 或域名）' "$address")
    valid_host "$address" || die '无效连接地址'
    name=$(ui_prompt '节点名称（可留空）' "$(jq -r '.name//empty' <<< "$old")")
    UI_NODE_ARGS+=(--port "$port" --address "$address")
    [[ -z $name ]] || UI_NODE_ARGS+=(--name "$name")
    case $protocol in
        *reality)
            credential=$(ui_prompt 'UUID（auto 自动生成）' "$(jq -r '.uuid//"auto"' <<< "$old")")
            sni=$(ui_sni "$(jq -r '.reality.sni//empty' <<< "$old")")
            UI_NODE_ARGS+=("$port" "$credential" "$sni");;
        shadowsocks)
            method=$(ui_method)
            credential=$(ui_prompt '密码（auto 自动生成）' auto true)
            UI_NODE_ARGS+=(--method "$method" --password "$credential");;
        socks)
            username=$(ui_prompt 'Socks 用户名' "$(jq -r '.username//"user"' <<< "$old")")
            credential=$(ui_prompt '密码（auto 自动生成）' auto true)
            UI_NODE_ARGS+=("$port" "$username" "$credential");;
        direct)
            target=$(ui_prompt '转发目标地址' "$(jq -r '.target_server//empty' <<< "$old")")
            target_port=$(ui_prompt '转发目标端口' "$(jq -r '.target_port//empty|select(.!=0)' <<< "$old")")
            UI_NODE_ARGS+=("$port" "$target" "$target_port");;
        *)
            if [[ $protocol == vmess-* || $protocol == vless-* || $protocol == tuic ]]; then
                credential=$(ui_prompt 'UUID（auto 自动生成）' "$(jq -r '.uuid//"auto"' <<< "$old")")
                UI_NODE_ARGS+=(--uuid "$credential")
            else credential=$(ui_prompt '密码（auto 自动生成）' auto true); UI_NODE_ARGS+=(--password "$credential"); fi;;
    esac
    if [[ $protocol == *-tls || $protocol == trojan || $protocol == hysteria2 || $protocol == tuic || $protocol == anytls || $protocol == vmess-quic ]]; then
        domain=$(ui_domain "$(jq -r '.domain//empty' <<< "$old")")
        if [[ $(jq -r '.external_tls//false' <<< "$old") == true && $protocol == *-tls ]]; then UI_NODE_ARGS+=(--cert-domain "$domain")
        else ui_tls_args "$domain"; fi
    fi
    if [[ $protocol == *-tls || $protocol == vmess-ws || $protocol == vmess-http || $protocol == vless-http2-reality ]]; then
        path=$(ui_prompt 'HTTP 传输路径（auto 自动生成）' "$(jq -r '.path//"auto"' <<< "$old")")
        [[ $path != auto ]] || path="/$(openssl rand -hex 6)"
        UI_NODE_ARGS+=(--path "$path")
    fi
    note "即将配置: $protocol；公网端口 $port；连接地址 $address"
    ui_confirm '保存这个节点？应用配置会短暂中断现有连接'
}
ui_add() {
    local protocol=${1:-} result
    if [[ -z $protocol ]]; then protocol=$(ui_protocol); fi
    # A numeric protocol shortcut uses the same displayed order.
    if [[ $protocol =~ ^[0-9]{1,2}$ ]]; then protocol=$(ui_protocols | sed -n "$((10#$protocol))s/|.*//p" | tr -d ' '); fi
    [[ -n $protocol ]] || die '协议序号无效'
    ui_node_inputs "$protocol" '{}'
    result=$(add_node "$protocol" "${UI_NODE_ARGS[@]}")
    ui_node_summary "$result"
    note "节点已添加。分享链接: sb url $(jq -r .id <<< "$result")"
}
ui_change() {
    local selector=${1:-} option=${2:-} node id protocol value method private public domain result
    node=$(select_node "$selector"); id=$(jq -r .id <<< "$node"); protocol=$(jq -r .protocol <<< "$node")
    note "当前节点: $id；$protocol；端口 $(jq -r .port <<< "$node")"
    if [[ -z $option ]]; then
        local options=(port '公网端口' new '切换协议' outbound '出口' name '节点名称' address '客户端连接地址')
        [[ $protocol != vmess-* && $protocol != vless-* && $protocol != tuic ]] || options+=(id 'UUID')
        [[ $protocol != shadowsocks && $protocol != socks && $protocol != trojan* && $protocol != hysteria2 && $protocol != tuic && $protocol != anytls ]] || options+=(passwd '密码')
        [[ $protocol != socks ]] || options+=(username 'Socks 用户名')
        [[ $protocol != *reality ]] || options+=(sni 'REALITY SNI / 握手目标' key 'REALITY 密钥')
        [[ $protocol != shadowsocks ]] || options+=(method 'SS 加密方式（会重新生成匹配的密码）')
        [[ $protocol != *-tls && $protocol != vmess-ws && $protocol != vmess-http && $protocol != vless-http2-reality ]] || options+=(path 'HTTP 传输路径')
        [[ $protocol != *-tls && $protocol != trojan && $protocol != hysteria2 && $protocol != tuic && $protocol != anytls && $protocol != vmess-quic ]] || options+=(host 'TLS 证书域名')
        [[ $protocol != *-tls || $(jq -r .external_tls <<< "$node") != false ]] || options+=(web '伪装网站')
        options+=(full '完整设置')
        option=$(ui_choose '选择修改项' "${options[@]}")
    fi
    case $option in
        new|full)
            [[ $option != new ]] || protocol=$(ui_protocol)
            ui_node_inputs "$protocol" "$node"
            # Use the originally selected record for optimistic concurrency.
            result=$(build_node "$protocol" "$node" false "${UI_NODE_ARGS[@]}")
            save_node "$result" "$node";;
        outbound)
            value=$(ui_choose '选择节点出口' direct '直连' proxy '粘贴代理节点链接')
            if [[ $value == proxy ]]; then value=$(ui_prompt '粘贴出口链接' '' true); fi
            value=$(outbound_from_uri "$value")
            result=$(jq --argjson out "$value" '.outbound=$out' <<< "$node")
            save_node "$result" "$node";;
        port) value=$(ui_prompt '新的公网端口（auto 自动分配）' "$(jq -r .port <<< "$node")"); change_node "$id" port "$value";;
        sni) value=$(ui_sni "$(jq -r .reality.sni <<< "$node")"); change_node "$id" sni "$value";;
        method) method=$(ui_method); change_node "$id" method "$method";;
        id|passwd)
            value=$(ui_choose '选择凭据设置方式' auto '自动重新生成' manual '手动输入')
            if [[ $value == manual ]]; then value=$(ui_prompt '新的凭据' '' "$([[ $option == passwd ]] && printf true || printf false)"); fi
            change_node "$id" "$option" "$value";;
        key)
            value=$(ui_choose '选择 REALITY 密钥设置方式' auto '自动重新生成密钥对' manual '输入已有密钥对')
            if [[ $value == auto ]]; then change_node "$id" key auto
            else private=$(ui_prompt 'REALITY 私钥' '' true); public=$(ui_prompt '对应的公钥'); change_node "$id" key "$private" "$public"; fi;;
        path) value=$(ui_prompt '新的 HTTP 路径（auto 自动生成）' "$(jq -r .path <<< "$node")"); change_node "$id" path "$value";;
        host)
            domain=$(ui_domain)
            UI_NODE_ARGS=(); ui_tls_args "$domain"
            ui_confirm "将证书域名改为 $domain？"
            change_node "$id" host "$domain" "${UI_NODE_ARGS[@]}";;
        name|address|username)
            value=$(ui_prompt '新的值' "$(jq -r --arg key "$option" '.[$key]' <<< "$node")")
            change_node "$id" "$option" "$value";;
        web) value=$(ui_web_url); change_node "$id" web "$value";;
        *) die '未知修改项';;
    esac
    note "节点设置已保存: $id"
}
ui_delete() {
    local node id
    node=$(select_node "${1:-}"); id=$(jq -r .id <<< "$node")
    ui_confirm "删除节点 $id（$(jq -r .protocol <<< "$node")，端口 $(jq -r .port <<< "$node")）？"
    # An exact ID only is removed, even if another node changes meanwhile.
    delete_nodes "$(jq '[.id]' <<< "$node")"
    note '节点已删除'
}
ui_node_summary() {
    jq -r '"名称: \(.name)\nID: \(.id)\n协议: \(.protocol)\n公网端口: \(.port)\n连接地址: \(.address)\n证书域名: \(.domain//""|if .=="" then "无" else . end)\n出口: \(.outbound.type)"' <<< "$1"
}
ui_view() {
    local node id choice
    node=$(select_node "${1:-}"); id=$(jq -r .id <<< "$node")
    choice=$(ui_choose '查看节点' info '完整节点信息（包含真实凭据）' url '分享链接（含凭据）' qr '分享二维码（含凭据）')
    "$SB_HOME/bin/sb" "$choice" "$id"
}
ui_web_url() {
    local choice
    choice=$(ui_choose '选择伪装页面' local '本地静态页面' remote '反代 HTTP/HTTPS 网站')
    if [[ $choice == remote ]]; then ui_prompt '伪装网站 URL'; else printf '\n'; fi
}
ui_cert() {
    local choice domain profile chain key selfsigned=false
    choice=$(ui_choose '证书管理（证书可被多个节点共用）' issue '签发证书' check '查看证书和续期状态' renew '手动续期' token '配置 Cloudflare Token' import '导入证书文件')
    case $choice in
        check) cert_check;;
        token) profile=$(ui_prompt '凭据名称' default); cert_token_set "$profile";;
        issue)
            domain=$(ui_prompt '你控制的证书域名'); valid_domain "$domain" || die '证书域名无效'
            profile=$(ui_profile)
            ui_confirm "为 $domain 使用 DNS-01 签发证书？"
            cert_issue "$domain" "$profile";;
        renew) domain=$(ui_choose_certificate); cert_renew "$domain";;
        import)
            domain=$(ui_prompt '证书域名'); chain=$(ui_prompt '证书链文件绝对路径'); key=$(ui_prompt '私钥文件绝对路径')
            choice=$(ui_choose '导入证书的类型' trusted '可信 CA 证书' selfsigned '显式导入自签证书')
            [[ $choice != selfsigned ]] || selfsigned=true
            cert_import "$domain" "$chain" "$key" "$selfsigned";;
    esac
}
ui_choose_certificate() {
    local domain options=('' '所有 ACME 证书')
    while IFS= read -r domain; do options+=("$domain" "$domain"); done < <(read_state | jq -r '.certificates[]|select(.profile!="")|.domains[0]')
    ui_choose '选择需要续期的证书' "${options[@]}"
}
ui_web() {
    local choice domain web profile port node id nodes=() options=(node '设置节点伪装页面' new '创建 / 修改独立网站')
    while IFS= read -r domain; do options+=("$domain" "删除独立网站: $domain"); done < <(read_state | jq -r '.websites[].domain')
    choice=$(ui_choose '网站管理' "${options[@]}")
    case $choice in
        node)
            while IFS= read -r node; do
                id=$(jq -r .id <<< "$node")
                nodes+=("$id" "$(jq -r '"\(.name) · \(.protocol) · :\(.port)"' <<< "$node")")
            done < <(read_state | jq -c '.nodes[]|select((.protocol|endswith("-tls")) and (.external_tls|not))')
            if (( ${#nodes[@]} == 0 )); then note '没有使用受管 HTTP TLS 反代的节点，请先添加相应节点'; return 2; fi
            id=$(ui_choose '选择可设置伪装的节点' "${nodes[@]}")
            ui_change "$id" web;;
        new)
            domain=$(ui_domain); web=$(ui_web_url); port=$(ui_prompt '独立网站端口' 443)
            profile=default
            if [[ -z $(certificate_for_domain "$(read_state)" "$domain") ]]; then profile=$(ui_profile); fi
            ui_confirm "保存独立网站 $domain:$port？"
            website_set "$domain" "$web" "$port" "$profile";;
        *) ui_confirm "删除独立网站 $choice？"; with_lock _website_delete "$choice";;
    esac
}
ui_dns() {
    local choice address
    note "当前全局 DNS: $(read_state | jq -c .settings.dns)"
    choice=$(ui_choose '选择全局 DNS（影响所有节点）' none '系统 DNS' 11 'Cloudflare 1.1.1.1' 88 'Google 8.8.8.8' cf 'Cloudflare 加密 DNS' gg 'Google 加密 DNS' nosex 'Cloudflare 家庭过滤' set '自定义解析器')
    if [[ $choice == set ]]; then address=$(ui_prompt '解析器地址（例如 tls://1.1.1.1）'); set_dns set "$address"
    else set_dns "$choice"; fi
}
ui_service() {
    local target action
    target=$(ui_choose '选择服务（共享，影响相关节点）' core 'sing-box' nginx 'Nginx')
    action=$(ui_choose '选择服务操作' status '查看状态' restart '重启' start '启动' stop '停止')
    if [[ $action == status ]]; then status_report
    elif [[ $target == core ]]; then "$SB_HOME/bin/sb" "$action"
    else "$SB_HOME/bin/sb" "$action" nginx; fi
}
ui_log() {
    local choice level
    choice=$(ui_choose '日志管理（全局）' view '查看实时日志，Ctrl+C 退出' level '修改日志级别' clear '清空日志')
    case $choice in
        view) "$SB_HOME/bin/sb" log;;
        clear) ui_confirm '清空运行日志？'; : > "$SB_ROOT/logs/core.log";;
        level) level=$(ui_choose '选择日志级别' warn '警告 warn' info '普通 info' error '错误 error' debug '调试 debug' none '关闭 none'); set_log_level "$level";;
    esac
}
ui_backup() {
    local choice path takeover
    choice=$(ui_choose '备份、恢复和导入' backup '创建备份（不含 Cloudflare Token）' restore '恢复备份' import '导入旧脚本配置')
    case $choice in
        backup) path=$(ui_prompt '备份文件路径' "/root/sb-manager-$(stamp).tar.gz"); with_lock backup_create "$path";;
        restore) path=$(ui_prompt '备份文件路径'); ui_confirm "使用 $path 恢复节点配置？"; backup_restore "$path";;
        import)
            path=$(ui_prompt '旧配置文件或目录' /etc/sing-box/conf); import_command "$path"
            ui_confirm '预览如上，应用这些节点？'
            takeover=$(ui_choose '是否接管旧服务' no '不停止旧服务' yes '显式停止已知旧核心服务并接管')
            if [[ $takeover == yes ]]; then import_command "$path" --apply --takeover; else import_command "$path" --apply; fi;;
    esac
}
ui_update() {
    local choice
    choice=$(ui_choose '选择更新对象（共享操作）' sh '管理脚本' core 'sing-box 内核（官方最新稳定版）' nginx 'Nginx')
    if [[ $choice == core ]]; then
        choice=$(ui_choose '内核更新' update '检查字段变化并更新到官方最新稳定版' check '仅检查版本、兼容性及字段变化')
        if [[ $choice == check ]]; then "$SB_HOME/bin/sb" update core --check; else "$SB_HOME/bin/sb" update core; fi
        return
    fi
    "$SB_HOME/bin/sb" update "$choice"
}
ui_maintenance() {
    local choice
    choice=$(ui_choose '检查与维护' test '检查配置及服务状态' fix-all '从节点记录修复配置' fix-nginx '修复 Nginx' ip '查看公网地址' bbr '启用 BBR（主机全局）' reinstall '重装管理脚本' uninstall '卸载服务及命令，保留数据')
    case $choice in uninstall|reinstall|bbr) ui_confirm "执行 $choice？";; esac
    "$SB_HOME/bin/sb" "$choice"
}
ui_dispatch() {
    local action=${1:-}; (( $# == 0 )) || shift
    case $action in
        add) ui_add "$@";; change) ui_change "$@";; view) ui_view "$@";; delete) ui_delete "$@";;
        outbound) ui_change "${1:-}" outbound;; cert) ui_cert;; web) ui_web;; dns) ui_dns;;
        service) ui_service;; log) ui_log;; backup) ui_backup;; update) ui_update;; maintenance) ui_maintenance;;
        *) die '未知菜单操作';;
    esac
}
ui_main() {
    local choice rc
    while true; do
        note "节点数量: $(read_state | jq '.nodes|length')"
        choice=$(ui_choose 'sb-manager 主菜单' add '添加节点' change '修改节点' view '查看 / 分享节点' delete '删除节点' \
            outbound '设置节点出口' cert '证书管理' web '伪装网站' service '服务管理（共享）' log '日志管理（全局）' \
            dns 'DNS 设置（全局）' backup '备份 / 恢复 / 导入' update '更新脚本 / 内核' maintenance '检查 / 修复 / 卸载') || return 0
        # A fresh shell preserves errexit inside an operation, even while the
        # menu catches failures to let the user choose another action.
        rc=0
        "$SB_HOME/bin/sb" __ui "$choice" || rc=$?
        case $rc in 0) ;; 2|130) note '已返回主菜单';; *) note '操作失败，原错误已显示；可重新选择';; esac
    done
}
