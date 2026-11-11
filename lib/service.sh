#!/usr/bin/env bash
service_active() {
    local name=$1 pidfile pid
    case $SB_SERVICE_MODE in
        systemd) systemctl is-active --quiet "$([[ $name == core ]] && printf %s "$SB_UNIT" || printf nginx.service)";;
        process)
            pidfile="$SB_ROOT/run/$name.pid"; [[ $name != nginx ]] || pidfile="$SB_ROOT/run/nginx.pid"
            [[ -f $pidfile ]] || return 1
            read -r pid < "$pidfile"
            [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ $(ps -o stat= -p "$pid" 2>/dev/null) != Z* ]];;
        none) return 1;;
        *) die 'SB_SERVICE_MODE 只能是 systemd、process 或 none';;
    esac
}
service_action() {
    local name=$1 action=$2 pidfile pid tries
    [[ $SB_SERVICE_MODE != none ]] || return 0
    if [[ $SB_SERVICE_MODE == systemd ]]; then
        # Deliberate configuration commits and rollback starts must not consume
        # the crash-loop budget left by previous managed restarts.
        if [[ $name == core && ( $action == start || $action == restart ) ]]; then systemctl reset-failed "$SB_UNIT"; fi
        systemctl "$action" "$([[ $name == core ]] && printf %s "$SB_UNIT" || printf nginx.service)"
        return "$?"
    fi
    [[ $name == core || $name == nginx ]] || die '未知服务'
    pidfile="$SB_ROOT/run/$name.pid"
    case $action in
        stop)
            if service_active "$name"; then
                read -r pid < "$pidfile"; kill -TERM "$pid"
                for ((tries=0; tries<50; tries++)); do kill -0 "$pid" 2>/dev/null || break; sleep .1; done
                # A terminated child can remain a zombie until PID 1 reaps it.
                if kill -0 "$pid" 2>/dev/null && [[ $(ps -o stat= -p "$pid" 2>/dev/null) != Z* ]]; then kill -KILL "$pid"; fi
            fi
            rm -f -- "$pidfile";;
        start)
            service_active "$name" && return 0
            mkdir -p "$SB_ROOT/run" "$SB_ROOT/logs"
            if [[ $name == core ]]; then
                ( close_inherited_locks; exec nohup "$SB_CORE" run -c "$SB_ROOT/current/config.json" ) </dev/null >>"$SB_ROOT/logs/core.log" 2>&1 &
                printf '%s\n' "$!" > "$pidfile"
            else
                without_locks nginx -c "$SB_ROOT/current/nginx/nginx.conf"
            fi;;
        restart) service_action "$name" stop; service_action "$name" start;;
        reload)
            if [[ $name == nginx ]]; then nginx -s reload -c "$SB_ROOT/current/nginx/nginx.conf"
            else service_action core restart; fi;;
        *) die '未知服务操作';;
    esac
}
has_nginx() { jq -e -L "$SB_HOME/jq" 'include "model";any(.nodes[];proxied) or (.websites|length)>0' <<< "$1" >/dev/null; }
check_nginx_version() {
    local state=$1 version
    need nginx
    version=$(nginx -v 2>&1); version=${version#*nginx/}; version=${version%% *}
    [[ $(printf '%s\n' 1.25.1 "$version" | sort -V | head -n1) == 1.25.1 ]] || die 'Nginx 版本过低，至少需要 1.25.1；不会自动替换现有服务'
    if jq -e 'any(.nodes[];.protocol|endswith("-h2-tls"))' <<< "$state" >/dev/null; then
        [[ $(printf '%s\n' 1.29.4 "$version" | sort -V | head -n1) == 1.29.4 ]] || die 'H2 反代要求 Nginx >=1.29.4'
    fi
}
validate_nginx() {
    local directory=$1 shadow file
    if [[ $SB_SERVICE_MODE != systemd ]]; then nginx -t -c "$directory/nginx/nginx.conf" >"$directory/nginx-check.log" 2>&1; return; fi
    [[ -f /etc/nginx/conf.d/sb-manager.conf ]] || die '缺少项目 Nginx include；请运行安装器配置 Nginx 集成'
    shadow=$(mktemp -d "$SB_ROOT/run/nginx-check.XXXXXXXX")
    cp -aL /etc/nginx/. "$shadow/"
    while IFS= read -r -d '' file; do
        # Rewrite include directives in copies, never the live configuration.
        sed -E "s#(include[[:space:]]+)/etc/nginx/#\\1$shadow/#g" "$file" > "$file.tmp"
        mv -f -- "$file.tmp" "$file"
    done < <(find "$shadow" -type f -name '*.conf' -print0)
    printf 'include %s/nginx/domains/*.conf;\n' "$directory" > "$shadow/conf.d/sb-manager.conf"
    local status=0
    nginx -t -p /etc/nginx/ -c "$shadow/nginx.conf" >"$directory/nginx-check.log" 2>&1 || status=$?
    rm -rf -- "$shadow"
    return "$status"
}
runtime_health() {
    local state=$1 generation=$2 checkcore=$3 checknginx=$4 attempts port record domain expected actual
    if [[ $checkcore == true ]]; then
        for ((attempts=0;attempts<50;attempts++)); do
            if service_active core; then
                local missing=false
                while IFS= read -r port; do port_is_listening "$port" || missing=true; done < <(jq -L "$SB_HOME/jq" -r 'include "model";.nodes[]|if proxied or external_http then .backend_port else .port end' <<< "$state")
                [[ $missing != false ]] || break
            fi
            sleep .1
        done
        (( attempts < 50 )) || { note 'sing-box 未保持运行或缺少监听端口'; return 1; }
        sleep .2; service_active core || return 1
    fi
    if [[ $checknginx == true ]]; then
        while IFS= read -r record; do
            domain=$(jq -r .domain <<< "$record"); port=$(jq -r .port <<< "$record")
            for ((attempts=0;attempts<40;attempts++)); do
                actual=$(curl --noproxy '*' --fail --silent --insecure --max-time 2 --resolve "$domain:$port:127.0.0.1" "https://$domain:$port/._sb_health_$generation" 2>/dev/null) || actual=''
                [[ $actual != "$generation" ]] || break
                sleep .1
            done
            (( attempts < 40 )) || { note 'Nginx 未加载候选版本'; return 1; }
        done < <(jq -c -L "$SB_HOME/jq" 'include "model";[.nodes[]|select(proxied)]+.websites|.[]' <<< "$state")
    fi
    # Verify the certificate actually served by every native TCP TLS listener.
    if [[ $checkcore == true || $checknginx == true ]]; then
        while IFS= read -r record; do
            domain=$(jq -r .domain <<< "$record"); port=$(jq -r .port <<< "$record")
            expected=$(jq -r --arg id "$(jq -r .certificate_id <<< "$record")" '.certificates[]|select(.id==$id)|.version_dir+"/fullchain.pem"' <<< "$state")
            expected=$(openssl x509 -in "$expected" -noout -fingerprint -sha256)
            actual=$(timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
            [[ $actual == "$expected" ]] || { note '实际 TLS 证书与候选版本不同'; return 1; }
        done < <(jq -c -L "$SB_HOME/jq" --argjson ca "$checkcore" --argjson na "$checknginx" \
          'include "model";[.nodes[]|select(($na and proxied) or ($ca and (.protocol|IN("trojan","anytls"))))]+(if $na then .websites else [] end)|.[]' <<< "$state")
    fi
}
