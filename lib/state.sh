#!/usr/bin/env bash
atomic_current() {
    local target=$1
    ln -s "$target" "$SB_ROOT/.current.$$"
    mv -Tf -- "$SB_ROOT/.current.$$" "$SB_ROOT/current"
}
rules_verify() {
    [[ -f $SB_ROOT/rules/geoip-cn.srs ]] || die '缺少中国 IP 本地规则集，请先 sb init'
    [[ $(hash_file "$SB_ROOT/rules/geoip-cn.srs") == "$(jq -r .geoip_cn.sha256 "$SB_HOME/dependencies.lock.json")" ]] || die '中国 IP 规则集校验失败'
}
init_layout() {
    mkdir -p "$SB_ROOT"/{generations,run,logs,rules,www,credentials,certificates,acme,cache}
    chmod 700 "$SB_ROOT/credentials" "$SB_ROOT/acme"
    chmod 751 "$SB_ROOT"
    printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>Welcome</title><h1>Welcome</h1></html>\n' > "$SB_ROOT/www/index.html"
    chmod 755 "$SB_ROOT/www"; chmod 644 "$SB_ROOT/www/index.html"
}
init_manager() {
    local address=${1:-} state id
    init_layout
    check_core_version
    if [[ ! -f $SB_ROOT/rules/geoip-cn.srs ]]; then
        download "$(jq -r .geoip_cn.url "$SB_HOME/dependencies.lock.json")" "$SB_ROOT/rules/geoip-cn.srs" "$(jq -r .geoip_cn.sha256 "$SB_HOME/dependencies.lock.json")"
    fi
    rules_verify
    if [[ ! -L $SB_ROOT/current ]]; then
        state=$(default_state)
        if [[ -n $address ]]; then valid_host "$address" || die '无效连接地址'; state=$(jq --arg v "$address" '.settings.public_address=$v' <<< "$state"); fi
        id=$(stamp); write_generation "$state" "$SB_ROOT/generations/$id"
        core check -c "$SB_ROOT/generations/$id/config.json"
        atomic_current "generations/$id"
    fi
    note '已初始化独立节点管理目录'
}
journal_write() {
    local phase=$1 old=$2 new=$3 core_active=$4 nginx_active=$5
    jq -n --arg phase "$phase" --arg old "$old" --arg new "$new" --argjson ca "$core_active" --argjson na "$nginx_active" \
      '{phase:$phase,old:$old,new:$new,core_active:$ca,nginx_active:$na}' > "$SB_ROOT/.transaction.tmp"
    mv -f "$SB_ROOT/.transaction.tmp" "$SB_ROOT/transaction.json"
}
rollback_transaction() {
    [[ -f $SB_ROOT/transaction.json ]] || return 0
    local old ca na state port attempts
    old=$(jq -r .old "$SB_ROOT/transaction.json")
    [[ $old =~ ^generations/[a-zA-Z0-9-]+$ && -d $SB_ROOT/$old ]] || { note '事务旧版本无效，停止自动恢复'; return 1; }
    ca=$(jq -r .core_active "$SB_ROOT/transaction.json"); na=$(jq -r .nginx_active "$SB_ROOT/transaction.json")
    atomic_current "$old" || { note '回滚配置指针失败'; return 1; }
    # Release possibly changed ports before restoring their previous owners.
    service_action core stop || { note '回滚停止 core 失败'; return 1; }
    if [[ $SB_SERVICE_MODE == process ]]; then service_action nginx stop || { note '回滚停止 nginx 失败'; return 1; }
    elif [[ $na == true ]]; then service_action nginx reload || { note '回滚重载 nginx 失败'; return 1; }
    elif service_active nginx; then service_action nginx stop || { note '回滚停止新启动的 nginx 失败'; return 1; }; fi
    if [[ $ca == true ]]; then
        state=$(read_state)
        while IFS= read -r port; do
            for ((attempts=0;attempts<50;attempts++)); do port_is_listening "$port" || break; sleep .1; done
            (( attempts < 50 )) || { note '回滚端口未释放'; return 1; }
        done < <(jq -r -L "$SB_HOME/jq" 'include "model";.nodes[]|if proxied or external_http then .backend_port else .port end' <<< "$state")
        service_action core start || { note '回滚启动 core 失败'; return 1; }
    fi
    if [[ $na == true && $SB_SERVICE_MODE == process ]]; then service_action nginx start || { note '回滚启动 nginx 失败'; return 1; }; fi
    state=$(read_state)
    runtime_health "$state" "$(cat "$SB_ROOT/current/nginx/generation")" "$ca" "$na" || { note '回滚后的服务未通过健康检查'; return 1; }
    jq '.phase="rolled-back"' "$SB_ROOT/transaction.json" > "$SB_ROOT/.transaction.tmp"
    mv -f "$SB_ROOT/.transaction.tmp" "$SB_ROOT/transaction.json"
    note '已恢复上一版配置与原服务状态'
}
recover_transaction() {
    [[ -f $SB_ROOT/transaction.json ]] || return 0
    local phase; phase=$(jq -r .phase "$SB_ROOT/transaction.json")
    case $phase in switched|applying) rollback_transaction;; esac
}
validate_ports() {
    local state=$1 old=$2 port
    jq -e '[.nodes[]|.port,.backend_port|select(.>0)]+[.websites[].port]|length== (unique|length)' <<< "$state" >/dev/null || die '公网、网站或内部端口冲突'
    while IFS= read -r port; do
        if port_is_listening "$port"; then
            jq -e --argjson p "$port" 'any(.nodes[];.port==$p or .backend_port==$p) or any(.websites[];.port==$p)' <<< "$old" >/dev/null || die "端口 $port 已被其他服务占用"
        fi
    done < <(jq -r '.nodes[]|.port,.backend_port|select(.>0)' <<< "$state"; jq -r '.websites[].port' <<< "$state")
}
apply_state() { with_lock _apply_state "$1"; }
_apply_state() (
    set -Eeuo pipefail
    local state=$1 old id directory previous ca=false na=false cc=false nc=false wantcore=false wantnginx=false switched=false rc=0
    recover_transaction
    check_core_version
    rules_verify
    jq -e -L "$SB_HOME/jq" 'include "model";valid_state' <<< "$state" >/dev/null || die '节点数据结构无效'
    old=$(read_state); previous=$(readlink "$SB_ROOT/current")
    validate_ports "$state" "$old"
    id=$(stamp); directory="$SB_ROOT/generations/$id"
    write_generation "$state" "$directory"
    core check -c "$directory/config.json" > "$directory/core-check.log" 2>&1 || die "sing-box 配置检查失败，详见 $directory/core-check.log"
    if has_nginx "$state"; then
        ensure_nginx_integration
        check_nginx_version "$state"
        validate_nginx "$directory" || die "Nginx 候选配置检查失败，详见 $directory/nginx-check.log"
    fi
    service_active core && ca=true
    service_active nginx && na=true
    [[ $ca != true ]] || wantcore=true
    [[ $na != true ]] || wantnginx=true
    if [[ $(jq '.nodes|length' <<< "$old") == 0 && $(jq '.nodes|length' <<< "$state") != 0 ]]; then wantcore=true; fi
    if ! has_nginx "$old" && has_nginx "$state"; then wantnginx=true; fi
    cmp -s "$SB_ROOT/current/config.json" "$directory/config.json" && [[ ${SB_FORCE_CORE:-0} != 1 ]] || cc=true
    # Domain configuration contains a generation marker; compare resource state instead.
    if [[ $(nginx_fingerprint "$old") != "$(nginx_fingerprint "$state")" ||
          $(cat "$SB_ROOT/current/nginx/template.sha256" 2>/dev/null || true) != "$(cat "$directory/nginx/template.sha256")" ||
          ${SB_FORCE_NGINX:-0} == 1 ]]; then nc=true; fi
    # Preserve nginx bytes when nothing it serves changes, so health markers stay truthful.
    if [[ $nc == false ]]; then
        rm -rf "$directory/nginx"; cp -a "$SB_ROOT/current/nginx" "$directory/nginx"
        sed -E "s#include [^;]+/nginx/domains/\\*\\.conf;#include $directory/nginx/domains/*.conf;#" "$directory/nginx/nginx.conf" > "$directory/nginx/nginx.conf.tmp"
        mv -f "$directory/nginx/nginx.conf.tmp" "$directory/nginx/nginx.conf"
    fi
    if [[ $SB_SERVICE_MODE == systemd ]]; then grant_runtime_access; fi
    journal_write prepared "$previous" "generations/$id" "$ca" "$na"
    trap 'rc=$?; if (( rc != 0 )) && [[ $switched == true ]]; then trap - EXIT; rollback_transaction || note "自动恢复失败，请检查事务记录"; fi; exit "$rc"' EXIT
    trap 'exit 130' INT TERM
    journal_write switched "$previous" "generations/$id" "$ca" "$na"
    switched=true; atomic_current "generations/$id"
    if [[ $SB_SERVICE_MODE != none ]]; then
        journal_write applying "$previous" "generations/$id" "$ca" "$na"
        # Stop the core first so a changed protocol can hand its public port to nginx.
        if [[ $cc == true && $ca == true ]]; then service_action core stop; fi
        if [[ $nc == true ]]; then
            if [[ $SB_SERVICE_MODE == process ]]; then
                service_action nginx stop
                if has_nginx "$state" && [[ $wantnginx == true ]]; then service_action nginx start; fi
            elif [[ $wantnginx == true ]]; then
                if service_active nginx; then service_action nginx reload; else service_action nginx start; fi
            fi
        fi
        if [[ $cc == true && $wantcore == true ]]; then
            # nginx reload is asynchronous: wait until old workers release ports
            # whose ownership is moving back to the core.
            local port attempts
            while IFS= read -r port; do
                for ((attempts=0;attempts<50;attempts++)); do port_is_listening "$port" || break; sleep .1; done
                (( attempts < 50 )) || die "端口 $port 在服务交接后仍未释放"
            done < <(jq -r -L "$SB_HOME/jq" 'include "model";.nodes[]|if proxied or external_http then .backend_port else .port end' <<< "$state")
            service_action core start
        fi
        runtime_health "$state" "$id" "$([[ $cc == true && $wantcore == true ]] && printf true || printf false)" "$([[ $nc == true && $wantnginx == true ]] && printf true || printf false)"
    fi
    journal_write committed "$previous" "generations/$id" "$ca" "$na"
    switched=false
    # Keep ten historical generations plus the current version. Never remove certificates here.
    local retained=0 path
    while IFS= read -r path; do
        [[ $path != "$directory" ]] || continue
        (( retained+=1 )); (( retained <= 10 )) || rm -rf -- "$path"
    done < <(find "$SB_ROOT/generations" -mindepth 1 -maxdepth 1 -type d | sort -r)
)
