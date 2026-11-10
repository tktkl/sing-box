#!/usr/bin/env bash
cert_id() { printf 'cert-%s\n' "$(hash_text "$1" | cut -c1-24)"; }
certbot_args() {
    CERTBOT_ARGS=(--config-dir "$SB_ROOT/acme/config" --work-dir "$SB_ROOT/acme/work" --logs-dir "$SB_ROOT/logs/acme")
    if [[ -n ${SB_ACME_SERVER:-} ]]; then CERTBOT_ARGS+=(--server "$SB_ACME_SERVER"); fi
}
ensure_certbot() {
    if ! command -v certbot >/dev/null || ! certbot plugins 2>/dev/null | rg_or_grep_dns; then
        [[ $SB_SERVICE_MODE == systemd ]] || die '缺少 certbot 和 python3-certbot-dns-cloudflare'
        apt-get update >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare >&2
    fi
    certbot plugins 2>/dev/null | rg_or_grep_dns || die '缺少 dns-cloudflare 插件'
}
rg_or_grep_dns() { grep -q dns-cloudflare; }
cert_token_set() {
    local profile=$1 token
    valid_name "$profile" || die '凭据名称无效'
    mkdir -p "$SB_ROOT/credentials"; chmod 700 "$SB_ROOT/credentials"
    if [[ -t 0 ]]; then read -rs -p 'Cloudflare API Token: ' token; printf '\n' >&2
    else IFS= read -r token || [[ -n ${token:-} ]]; fi
    [[ $token =~ ^[a-zA-Z0-9_-]{20,256}$ ]] || die 'Token 格式无效'
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$SB_ROOT/credentials/.$profile.tmp"
    chmod 600 "$SB_ROOT/credentials/.$profile.tmp"
    mv -f -- "$SB_ROOT/credentials/.$profile.tmp" "$SB_ROOT/credentials/$profile.ini"
    unset token
    note '已保存凭据；不包含在备份中'
}
validate_certificate() {
    local chain=$1 key=$2 domains=$3 self_signed=$4 domain certpub keypub
    [[ -f $chain && -f $key ]] || die '证书或私钥不存在'
    openssl x509 -in "$chain" -noout -checkend 0 >/dev/null || die '证书无效或已到期'
    certpub=$(openssl x509 -in "$chain" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
    keypub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum)
    [[ $certpub == "$keypub" ]] || die '证书与私钥不匹配'
    while IFS= read -r domain; do
        [[ $domain != \*.* ]] || domain="sb-probe.${domain#*.}"
        openssl x509 -in "$chain" -noout -checkhost "$domain" >/dev/null || die '证书不覆盖所需域名'
    done < <(jq -r '.[]' <<< "$domains")
    if [[ $self_signed != true ]]; then
        openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$chain" "$chain" >/dev/null 2>&1 || die '证书链未通过系统信任校验'
    fi
}
certificate_record() {
    local id=$1 domains=$2 profile=$3 chain=$4 key=$5 self_signed=$6 digest directory expires
    validate_certificate "$chain" "$key" "$domains" "$self_signed"
    digest=$(hash_file "$chain"); directory="$SB_ROOT/certificates/$id/$digest"
    if [[ ! -d $directory ]]; then
        mkdir -p "$SB_ROOT/certificates/$id"
        local temp; temp=$(mktemp -d "$SB_ROOT/certificates/$id/.publish.XXXXXXXX")
        install -m 640 "$chain" "$temp/fullchain.pem"
        install -m 640 "$key" "$temp/privkey.pem"
        if getent group sb-manager >/dev/null 2>&1; then chgrp -R sb-manager "$temp"; fi
        chmod 750 "$temp"
        mv -- "$temp" "$directory"
    fi
    expires=$(openssl x509 -in "$chain" -noout -enddate); expires=${expires#notAfter=}
    jq -n --arg id "$id" --argjson domains "$domains" --arg profile "$profile" --arg dir "$directory" --arg expires "$expires" --argjson self_signed "$self_signed" \
      '{id:$id,domains:$domains,profile:$profile,version_dir:$dir,expires:$expires,self_signed:$self_signed,last_deployed_at:(now|todateiso8601)}'
}
_save_certificates() {
    local records=$1 state
    state=$(read_state | jq --argjson records "$records" '.certificates=((.certificates|map(select(.id as $id|all($records[];.id!=$id))))+$records)')
    _apply_state "$state"
}
cert_import() {
    local domain=$1 chain=$2 key=$3 self_signed=${4:-false} id record
    valid_domain "$domain" || die '证书域名无效'
    id=$(cert_id "$domain")
    record=$(certificate_record "$id" "$(jq -n --arg d "$domain" '[$d]')" '' "$chain" "$key" "$self_signed")
    with_lock _save_certificates "[$record]"
    printf '%s\n' "$id"
}
cert_self_signed() {
    local domain=$1 id temp record
    valid_domain "$domain" || die '自签模式仍需填写证书域名'
    temp=$(mktemp -d "$SB_ROOT/run/selfsigned.XXXXXXXX")
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" -keyout "$temp/key.pem" -out "$temp/cert.pem" >/dev/null 2>&1
    id=$(cert_import "$domain" "$temp/cert.pem" "$temp/key.pem" true)
    rm -rf -- "$temp"; printf '%s\n' "$id"
}
cert_issue() {
    local domain=$1 profile=${2:-default} wildcard=${3:-false} propagation=${4:-60} email=${5:-} id domains
    valid_domain "$domain" || die '证书域名无效'
    valid_name "$profile" || die '凭据名称无效'
    [[ $propagation =~ ^[0-9]+$ && $propagation -le 600 ]] || die 'DNS 等待时间须为 0..600 秒'
    [[ -f $SB_ROOT/credentials/$profile.ini ]] || die "缺少 Cloudflare 凭据: $profile，请先 sb cert token set"
    ensure_certbot
    domains=$(jq -n --arg d "$domain" --argjson w "$wildcard" '[$d]+(if $w then ["*."+$d] else [] end)')
    id=$(cert_id "$(jq -c . <<< "$domains")")
    local fd; exec {fd}>"$SB_ROOT/.acme.lock"; flock -w 300 "$fd" || die '另一个证书操作正在执行'
    certbot_args
    local args=(certonly "${CERTBOT_ARGS[@]}" --non-interactive --agree-tos --key-type ecdsa --cert-name "$id" --keep-until-expiring
        --dns-cloudflare --dns-cloudflare-credentials "$SB_ROOT/credentials/$profile.ini" --dns-cloudflare-propagation-seconds "$propagation" -d "$domain")
    [[ $wildcard != true ]] || args+=(-d "*.$domain")
    if [[ -n $email ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
    local rc=0
    certbot "${args[@]}" >&2 || rc=$?
    flock -u "$fd"; exec {fd}>&-
    (( rc == 0 )) || die 'DNS-01 签发失败，现有证书未变更'
    local record; record=$(certificate_record "$id" "$domains" "$profile" "$SB_ROOT/acme/config/live/$id/fullchain.pem" "$SB_ROOT/acme/config/live/$id/privkey.pem" false)
    with_lock _save_certificates "[$record]"
    printf '%s\n' "$id"
}
cert_deploy_hook() {
    local lineage=${RENEWED_LINEAGE:-} id resolved base chain
    [[ -n $lineage ]] || die '只允许由 Certbot deploy hook 调用'
    resolved=$(realpath "$lineage"); base=$(realpath "$SB_ROOT/acme/config")
    id=${lineage##*/}; [[ $id =~ ^cert-[a-f0-9]{24}$ ]] || die '无效证书 ID'
    [[ $resolved == "$base/live/$id" ]] || die 'Certbot lineage 不属于本项目'
    chain=$(realpath "$lineage/fullchain.pem")
    [[ $chain == "$base/archive/$id/"* || $chain == "$base/live/$id/fullchain.pem" ]] || die 'Certbot 证书路径不属于本项目'
    mkdir -p "$SB_ROOT/run/renewed"
    jq -n --arg id "$id" --arg path "$lineage" '{id:$id,lineage:$path}' > "$SB_ROOT/run/renewed/$id.json"
}
cert_renew() {
    local domain=${1:-} state id record records='[]' item lineage fd rc=0
    state=$(read_state)
    if ! jq -e 'any(.certificates[];.profile!="")' <<< "$state" >/dev/null; then note '没有本项目管理的 ACME 证书'; return 0; fi
    ensure_certbot
    exec {fd}>"$SB_ROOT/.acme.lock"; flock -w 300 "$fd" || die '另一个证书操作正在执行'
    mkdir -p "$SB_ROOT/run/renewed"
    certbot_args
    local args=(renew "${CERTBOT_ARGS[@]}" --no-random-sleep-on-renew --deploy-hook "$SB_HOME/scripts/certbot-deploy-hook")
    if [[ -n $domain ]]; then
        id=$(jq -r --arg d "$domain" '.certificates[]|select(.domains|index($d))|.id' <<< "$state")
        [[ -n $id && $id != *$'\n'* ]] || die '证书域名不唯一或不存在'
        args+=(--cert-name "$id")
    fi
    # Hooks enqueue only. One state transaction deploys the complete renewal batch.
    export SB_ROOT SB_CORE SB_SERVICE_MODE
    certbot "${args[@]}" >&2 || rc=$?
    flock -u "$fd"; exec {fd}>&-
    for item in "$SB_ROOT/run/renewed/"*.json; do
        [[ -f $item ]] || continue
        id=$(jq -r .id "$item"); lineage=$(jq -r .lineage "$item")
        record=$(jq --arg id "$id" '.certificates[]|select(.id==$id)' <<< "$(read_state)")
        [[ -n $record ]] || continue
        record=$(certificate_record "$id" "$(jq .domains <<< "$record")" "$(jq -r .profile <<< "$record")" "$lineage/fullchain.pem" "$lineage/privkey.pem" false)
        records=$(jq --argjson r "$record" '.+[$r]' <<< "$records")
    done
    if [[ $(jq length <<< "$records") != 0 ]]; then
        with_lock _save_certificates "$records"
        while IFS= read -r id; do rm -f -- "$SB_ROOT/run/renewed/$id.json"; done < <(jq -r '.[].id' <<< "$records")
    fi
    jq -n --argjson rc "$rc" '{last_attempt:(now|todateiso8601),certbot_exit_code:$rc}' > "$SB_ROOT/acme/renewal-status.json"
    (( rc == 0 )) || die '部分证书续期失败；成功签发的证书已单独验证部署'
}
certificate_for_domain() {
    jq -r --arg domain "$2" '[.certificates[]|select(any(.domains[];.==$domain or (startswith("*.") and ($domain|split(".")|.[1:]|join("."))==.[2:])))]|sort_by(.self_signed)|first.id//empty' <<< "$1"
}
cert_check() {
    local domain=${1:-} record profile renewal
    while IFS= read -r record; do
        profile=$(jq -r .profile <<< "$record"); renewal=unmanaged
        if [[ -n $profile ]]; then
            if [[ -f $SB_ROOT/credentials/$profile.ini ]]; then renewal=credentials-present; else renewal=TOKEN-MISSING; fi
        fi
        jq --arg renewal "$renewal" '.+{renewal_credentials:$renewal}' <<< "$record"
        openssl x509 -in "$(jq -r .version_dir <<< "$record")/fullchain.pem" -noout -checkend 1209600 >/dev/null || note '证书将在 14 天内到期或已过期'
    done < <(read_state | jq -c --arg d "$domain" '.certificates[]|select($d=="" or (.domains|index($d)))')
    if [[ -f $SB_ROOT/acme/renewal-status.json ]]; then cat "$SB_ROOT/acme/renewal-status.json"; fi
    if [[ $SB_SERVICE_MODE == systemd ]]; then systemctl list-timers sb-manager-renew.timer --no-pager; fi
}
