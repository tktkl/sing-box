#!/usr/bin/env bash
render_config() { jq -L "$SB_HOME/jq" --arg root "$SB_ROOT" 'include "model"; config($root)' <<< "$1"; }
node_client() { jq -L "$SB_HOME/jq" --arg id "$2" 'include "model";. as $s|.nodes[]|select(.id==$id)|client_outbound($s)' <<< "$1"; }
nginx_quote() {
    local value=$1
    no_controls "$value" || die 'Nginx 值不允许控制字符'
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//\$/\\\$}
    printf '"%s"' "$value"
}
nginx_web() {
    local web=$1 host
    if [[ -z $web ]]; then printf '    root %s;\n    try_files $uri /index.html;\n' "$(nginx_quote "$SB_ROOT/www")"; return; fi
    [[ $web =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/[^\ \"\'\{\}\\]*)?$ ]] || die '伪装地址必须是合法 HTTP/HTTPS URL'
    host=${web#*://}; host=${host%%/*}; host=${host%%:*}
    printf '    proxy_pass %s;\n    proxy_set_header Host %s;\n    proxy_ssl_server_name on;\n    proxy_ssl_name %s;\n    proxy_ssl_verify on;\n    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n' "$(nginx_quote "$web")" "$(nginx_quote "$host")" "$(nginx_quote "$host")"
}
render_nginx_server() {
    local item=$1 cert=$2 generation=$3 protocol port domain path backend web
    protocol=$(jq -r '.protocol//"website"' <<< "$item"); port=$(jq -r .port <<< "$item")
    domain=$(jq -r .domain <<< "$item"); web=$(jq -r '.web//""' <<< "$item")
    printf 'server {\n  listen 0.0.0.0:%s ssl;\n  listen [::]:%s ssl;\n  http2 on;\n  server_name %s;\n' "$port" "$port" "$domain"
    printf '  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_certificate %s;\n  ssl_certificate_key %s;\n' \
        "$(nginx_quote "$(jq -r .version_dir <<< "$cert")/fullchain.pem")" "$(nginx_quote "$(jq -r .version_dir <<< "$cert")/privkey.pem")"
    printf '  location = /._sb_health_%s { allow 127.0.0.1; allow ::1; deny all; access_log off; return 200 "%s"; }\n' "$generation" "$generation"
    if [[ $protocol != website ]]; then
        path=$(jq -r .path <<< "$item"); backend=$(jq -r .backend_port <<< "$item")
        printf '  location ^~ %s {\n    proxy_pass http://127.0.0.1:%s;\n' "$(nginx_quote "$path")" "$backend"
        # H2 keeps the request body open for uploads; its idle timer is separate
        # from the upstream proxy timers and defaults to only 60 seconds.
        printf '    proxy_set_header Host %s;\n    proxy_set_header X-Forwarded-For $remote_addr;\n    proxy_buffering off;\n    proxy_request_buffering off;\n    proxy_read_timeout 1d;\n    proxy_send_timeout 1d;\n    client_body_timeout 1d;\n    send_timeout 1d;\n    client_max_body_size 0;\n' "$(nginx_quote "$domain")"
        case $protocol in
            *-h2-tls) printf '    proxy_http_version 2;\n    proxy_set_header Connection "";\n';;
            *) printf '    proxy_http_version 1.1;\n    proxy_set_header Upgrade $http_upgrade;\n    proxy_set_header Connection "upgrade";\n';;
        esac
        printf '  }\n'
    fi
    printf '  location / {\n'; nginx_web "$web"; printf '  }\n}\n'
}
render_nginx() {
    local state=$1 directory=$2 generation=$3 domain item cert file
    mkdir -p "$directory/domains"
    printf '%s\n' "$generation" > "$directory/generation"
    hash_file "$SB_HOME/lib/render.sh" > "$directory/template.sha256"
    while IFS= read -r domain; do
        [[ -n $domain ]] || continue
        valid_domain "$domain" || die 'Nginx 域名无效'
        file="$directory/domains/$domain.conf"
        : > "$file"
        while IFS= read -r item; do
            cert=$(jq --arg id "$(jq -r .certificate_id <<< "$item")" '.certificates[]|select(.id==$id)' <<< "$state")
            [[ -n $cert ]] || die 'Nginx 证书引用缺失'
            render_nginx_server "$item" "$cert" "$generation" >> "$file"
        done < <(jq -c --arg d "$domain" '[.nodes[]|select((.protocol|endswith("-tls")) and (.external_tls|not))]+.websites|.[]|select(.domain==$d)' <<< "$state")
    done < <(jq -r '[.nodes[]|select((.protocol|endswith("-tls")) and (.external_tls|not))|.domain]+[.websites[].domain]|unique[]' <<< "$state")
    cat > "$directory/nginx.conf" <<EOF
worker_processes 1;
pid $SB_ROOT/run/nginx.pid;
error_log $SB_ROOT/logs/nginx-error.log warn;
events { worker_connections 2048; }
http {
  access_log off;
  client_body_temp_path $SB_ROOT/run/nginx-body;
  proxy_temp_path $SB_ROOT/run/nginx-proxy;
  include $directory/domains/*.conf;
}
EOF
}
nginx_fingerprint() {
    jq -cS -L "$SB_HOME/jq" 'include "model";
      . as $s|([.nodes[]|select(proxied)|{id,protocol,port,backend_port,domain,path,web,certificate_id}]+.websites) as $r|
      {resources:$r,certificates:([$r[].certificate_id as $id|$s.certificates[]|select(.id==$id)|{id,version_dir}]|unique_by(.id))}' <<< "$1"
}
write_generation() {
    local state=$1 directory=$2 id
    mkdir -p "$directory/nodes"
    jq .settings <<< "$state" > "$directory/settings.json"
    jq .certificates <<< "$state" > "$directory/certificates.json"
    jq .websites <<< "$state" > "$directory/websites.json"
    while IFS= read -r id; do jq --arg id "$id" '.nodes[]|select(.id==$id)' <<< "$state" > "$directory/nodes/$id.json"; done < <(jq -r '.nodes[].id' <<< "$state")
    render_config "$state" > "$directory/config.json"
    render_nginx "$state" "$directory/nginx" "${directory##*/}"
}
