#!/usr/bin/env bash
help_text() {
    cat <<'EOF'
sb-manager — 一个 sing-box 进程，各节点独立入口和出口

用法: sb <命令> [参数]       sing-box <命令> [参数]

  a, add [协议] [位置参数|auto] [选项]  交互时按序号选协议；非交互默认 REALITY
  c, change [节点] [修改项] [...]      修改一个节点
  d, del [节点]                       删除一个节点
  dd, ddel [节点...]                  删除多个唯一匹配节点
  i, info [节点]                      完整节点信息（包含真实凭据）
  list                                全部节点摘要
  url, qr [节点]                      分享链接 / 二维码（包含凭据）
  outbound [节点] [链接|direct]        独立出口；省略链接可从标准输入粘贴
  full/id/host/port/path/passwd/key/method/sni/new/web/name/address/username [节点] [...]

协议: r/reality, rh2, ss, tcp/http/quic/ws, wss/h2/hu,
      vws/vh2/vhu, tws/th2/thu, trojan, hy/hy2, tuic, anytls, socks, door
REALITY: [port] [uuid] [sni]；SS: [port] [password] [method]
HTTP-TLS: [domain] [uuid|password] [/path]；其他详见 docs/COMPATIBILITY.md
公共选项: --port --address --name --cert-domain --cf-profile --certificate
          --self-signed --skip-probe --listen --path --uuid --password --method
SNI 预设: apps.mzstatic.com（默认）、xp.apple.com；允许自定义。

  init [--address 地址]               初始化（不创建节点）
  cert token set <名称>               隐藏输入 Cloudflare Token
  cert issue <域名> [--profile 名称] [--wildcard] [--propagation 秒] [--email 邮箱]
  cert import <域名> <fullchain.pem> <privkey.pem> [--self-signed]
  cert list/check [域名] | cert renew [域名]
  web --domain <域名> [URL] [--port 443] [--profile 名称] [--delete]
  dns [11|88|gg|cf|nosex|set 地址|none]  全局 DNS
  log [级别|del]                      查看/设置全局日志
  s, status | start/stop/restart [nginx]
  t, test | fix [节点] | fix-all | fix-config.json | fix-nginx
  import [文件或目录] [--apply] [--takeover]
  backup [文件] | restore <文件>
  u, update [core|sh|nginx] [版本] | U, update.sh | reinstall | un, uninstall
  update core [--check]               获取官方最新稳定内核；--check 仅检查兼容性和字段变化
  gen [协议] [...]                    只输出 JSON，无文件或签发操作
  no-auto-tls [HTTP-TLS协议] [...]     使用你自行管理的外部 TLS 代理
  pbk | get-port | ss2022 | ip | bbr | debug [节点]
  bin [...]                           直接调用真实 sing-box 内核
  v, version | h, help

全局操作影响所有节点。应用内核配置会短暂中断连接。
Caddy 已移除；使用 nginx、fix-nginx 和 cert 命令。
EOF
}
status_report() {
    local ca=false na=false phase=none
    service_active core && ca=true
    service_active nginx && na=true
    [[ ! -f $SB_ROOT/transaction.json ]] || phase=$(jq -r .phase "$SB_ROOT/transaction.json")
    read_state | jq --argjson ca "$ca" --argjson na "$na" --arg phase "$phase" --arg version "$(cat "$SB_HOME/VERSION")" \
      '{script_version:$version,core_active:$ca,nginx_active:$na,transaction:$phase,nodes:(.nodes|length),certificates:(.certificates|length),global_dns:.settings.dns}'
}
set_log_level() { with_lock _set_log_level "$1"; }
_set_log_level() { local state; state=$(read_state | jq --arg v "$1" '.settings.log_level=$v'); _apply_state "$state"; }
main() {
    local cmd=${1:-} node state domain profile wildcard propagation email selfsigned value ids selector action
    (( $# == 0 )) || shift
    case $cmd in
        h|help|--help|-h) help_text; return;;
        v|version|--version) printf 'sb-manager %s\n' "$(cat "$SB_HOME/VERSION")"; core version; return;;
        bin) core "$@"; return;;
        generate|check|format|completion|merge|rule-set|run|tools|geoip|geosite) core "$cmd" "$@"; return;;
        pbk) core generate reality-keypair; return;;
        ss2022) core generate rand --base64 16; return;;
        gen) need jq; need openssl; gen_node "$@"; return;;
    esac
    require_root
    [[ $SB_ROOT =~ ^/[-a-zA-Z0-9_/.]+$ && $SB_ROOT != / && $SB_ROOT != *..* ]] || die '管理目录必须是无空格、无 .. 的绝对路径'
    need jq; need openssl; need flock; need ss
    if [[ $cmd == init ]]; then
        value=''; if (( $# )); then [[ $1 == --address && $# == 2 ]] || die 'init [--address 地址]'; value=$2; fi
        with_lock init_manager "$value"; return
    fi
    [[ -L $SB_ROOT/current ]] || die '尚未初始化，请执行安装器或 sb init'
    if [[ $cmd == cert && ${1:-} == deploy-hook ]]; then cert_deploy_hook; return; fi
    if [[ -f $SB_ROOT/transaction.json || -f $SB_ROOT/core-update.json ]]; then with_lock recover_transaction; fi
    case $cmd in
        '')
            if [[ -t 0 ]]; then ui_main; else help_text; fi;;
        __ui) [[ -t 0 ]] || die '菜单操作需要交互终端'; ui_dispatch "$@";;
        a|add)
            if [[ -t 0 && $# -le 1 ]]; then ui_add "$@"; else add_node "$@"; fi;;
        c|change)
            if [[ -t 0 && $# -le 2 ]]; then ui_change "$@"; else change_node "$@"; fi;;
        full|id|host|port|path|passwd|key|method|sni|new|outbound|name|address|username)
            selector=${1:-}; (( $# == 0 )) || shift
            if [[ -t 0 && $# == 0 ]]; then ui_change "$selector" "$cmd"
            else change_node "$selector" "$cmd" "$@"; fi;;
        web)
            if [[ -t 0 && $# == 0 ]]; then ui_web
            elif [[ -t 0 && $# == 1 ]]; then ui_change "$1" web
            elif [[ ${1:-} == --domain ]]; then
                domain=${2:-}; shift 2; value=''; profile=default; local port=443 remove=false
                if (( $# )) && [[ $1 != --* ]]; then value=$1; shift; fi
                while (( $# )); do case $1 in --port) port=${2:?}; shift 2;; --profile) profile=${2:?}; shift 2;; --delete) remove=true; shift;; *) die '未知网站选项';; esac; done
                if [[ $remove == true ]]; then valid_domain "$domain" || die '域名无效'; with_lock _website_delete "$domain"
                else website_set "$domain" "$value" "$port" "$profile"; fi
            else selector=${1:-}; (( $# == 0 )) || shift; change_node "$selector" web "$@"; fi;;
        d|del)
            if [[ -t 0 ]]; then ui_delete "${1:-}"
            else node=$(select_node "${1:-}"); delete_nodes "$(jq '[.id]' <<< "$node")"; fi;;
        dd|ddel)
            ids='[]'
            for selector in "$@"; do node=$(SB_REQUIRE_UNIQUE=1 select_node "$selector"); ids=$(jq --arg id "$(jq -r .id <<< "$node")" '.+[$id]|unique' <<< "$ids"); done
            [[ $(jq length <<< "$ids") != 0 ]] || die 'ddel 需要至少一个唯一节点'
            delete_nodes "$ids";;
        i|info) select_node "${1:-}" | jq .;;
        list) read_state | jq '[.nodes[]|{id,name,protocol,port,backend_port,address,domain,outbound:{type:.outbound.type,server:.outbound.server}}]';;
        url|qr)
            node=$(select_node "${1:-}"); state=$(read_state); value=$(node_client "$state" "$(jq -r .id <<< "$node")")
            value=$(uri_from_outbound "$value" "$(jq -r .name <<< "$node")")
            if [[ $cmd == qr ]]; then need qrencode; qrencode -t ANSIUTF8 "$value"; else printf '%s\n' "$value"; fi;;
        no-auto-tls) add_node "${1:-wss}" "${@:2}" --no-auto-tls;;
        cert)
            if [[ -t 0 && $# == 0 ]]; then ui_cert; return; fi
            action=${1:-list}; (( $# == 0 )) || shift
            case $action in
                token) [[ ${1:-} == set && -n ${2:-} ]] || die 'cert token set <名称>'; cert_token_set "$2";;
                issue)
                    domain=${1:-}; (( $# == 0 )) || shift; profile=default; wildcard=false; propagation=60; email=''
                    while (( $# )); do
                        case $1 in --profile) profile=${2:?}; shift 2;; --wildcard) wildcard=true; shift;; --propagation) propagation=${2:?}; shift 2;; --email) email=${2:?}; shift 2;; *) die '未知证书选项';; esac
                    done
                    cert_issue "$domain" "$profile" "$wildcard" "$propagation" "$email";;
                import)
                    (( $# >= 3 )) || die 'cert import <域名> <证书链> <私钥> [--self-signed]'
                    selfsigned=false; [[ ${4:-} != --self-signed ]] || selfsigned=true
                    cert_import "$1" "$2" "$3" "$selfsigned";;
                list|check) cert_check "${1:-}";; renew) cert_renew "${1:-}";;
                *) die '未知证书命令';;
            esac;;
        dns) if (( $# )); then set_dns "$@"; elif [[ -t 0 ]]; then ui_dns; else read_state | jq .settings.dns; fi;;
        log)
            case ${1:-} in
                '') touch "$SB_ROOT/logs/core.log"; tail -n 100 -F "$SB_ROOT/logs/core.log";;
                del) : > "$SB_ROOT/logs/core.log";;
                trace|debug|info|warn|error|fatal|panic|none) set_log_level "$1";;
                *) die '未知日志级别';;
            esac;;
        s|status) status_report;;
        start|stop|restart)
            action=core
            if (( $# )); then [[ $1 == nginx && $# == 1 ]] || die '服务参数只接受 nginx'; action=nginx; fi
            service_action "$action" "$cmd"
            if [[ $cmd != stop ]]; then
                state=$(read_state)
                runtime_health "$state" "$(cat "$SB_ROOT/current/nginx/generation")" "$([[ $action == core ]] && printf true || printf false)" "$([[ $action == nginx ]] && printf true || printf false)"
            fi;;
        t|test) rules_verify; core check -c "$SB_ROOT/current/config.json"; status_report;;
        fix|fix-all|fix-config.json|fix-nginx)
            if [[ $cmd == fix && -n ${1:-} ]]; then select_node "$1" >/dev/null; fi
            SB_FORCE_NGINX=1 apply_state "$(read_state)";;
        get-port) free_port "$(read_state)";;
        ip) detect_address;;
        debug) status_report; if (( $# )); then select_node "$1" | jq .; else read_state | jq .; fi;;
        backup) with_lock backup_create "${1:-}";;
        restore) [[ -n ${1:-} ]] || die 'restore 需要备份文件'; backup_restore "$1";;
        import) import_command "$@";;
        bbr) bbr_enable;;
        u|update)
            if [[ -t 0 && $# == 0 ]]; then ui_update; return; fi
            action=${1:-core}; (( $# == 0 )) || shift
            case $action in core) update_core "$@";; sh) update_script "$@";; nginx) update_nginx "$@";; caddy) die 'Caddy 已移除，请使用 update nginx';; *) die '未知更新对象';; esac;;
        U|update.sh) update_script "$@";;
        reinstall) "$SB_HOME/install.sh" --reinstall;;
        un|uninstall) uninstall_manager;;
        fix-caddyfile) die 'Caddy 已移除，请使用 fix-nginx';;
        *) die '未知命令，请使用 sb help；内核命令使用 sb bin';;
    esac
}
