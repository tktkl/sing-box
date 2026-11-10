#!/usr/bin/env bash
set -Eeuo pipefail
[[ -n ${SB_TEST_DOMAIN:-} && -n ${SB_TEST_CF_PROFILE:-} ]] || {
    printf 'Set SB_TEST_DOMAIN and SB_TEST_CF_PROFILE for a dedicated staging domain. Configure its token with sb cert token set.\n' >&2
    exit 2
}
[[ ${SB_ACME_SERVER:-https://acme-staging-v02.api.letsencrypt.org/directory} == https://acme-staging-v02.api.letsencrypt.org/directory ]] || {
    printf 'This acceptance target only uses Let\x27s Encrypt staging.\n' >&2; exit 2;
}
export SB_ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
# Staging roots are deliberately not trusted by production deployment. Run certbot
# directly to verify Cloudflare TXT lifecycle without deploying an untrusted leaf.
export SB_HOME=${SB_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
source "$SB_HOME/lib/common.sh"
source "$SB_HOME/lib/certificates.sh"
require_root
ensure_certbot
valid_domain "$SB_TEST_DOMAIN" && valid_name "$SB_TEST_CF_PROFILE" || die '测试域名或凭据名称无效'
[[ -f $SB_ROOT/credentials/$SB_TEST_CF_PROFILE.ini ]] || die '缺少测试专用 Token'
temporary=$(mktemp -d "$SB_ROOT/run/staging.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
certbot certonly --non-interactive --agree-tos --register-unsafely-without-email --key-type ecdsa \
    --server "$SB_ACME_SERVER" --config-dir "$temporary/config" --work-dir "$temporary/work" --logs-dir "$temporary/logs" \
    --dns-cloudflare --dns-cloudflare-credentials "$SB_ROOT/credentials/$SB_TEST_CF_PROFILE.ini" \
    --dns-cloudflare-propagation-seconds 60 -d "$SB_TEST_DOMAIN"
certbot renew --force-renewal --non-interactive --server "$SB_ACME_SERVER" \
    --config-dir "$temporary/config" --work-dir "$temporary/work" --logs-dir "$temporary/logs"
printf 'Real Cloudflare staging issuance and renewal passed. Verify no residual _acme-challenge TXT remains in the test zone.\n'
