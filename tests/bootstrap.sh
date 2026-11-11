#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/standalone" "$temporary/bin" "$temporary/source/sb-manager-0.1.0/lib" "$temporary/assets"
cp "$root/install.sh" "$temporary/standalone/install.sh"
printf '{}\n' > "$temporary/source/sb-manager-0.1.0/dependencies.lock.json"
touch "$temporary/source/sb-manager-0.1.0/lib/common.sh"
cat > "$temporary/source/sb-manager-0.1.0/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SB_BOOTSTRAP_TEST_OUTPUT"
INSTALL
cat > "$temporary/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
target='' url=''
while (( $# )); do
    case $1 in
        --output) target=$2; shift 2;;
        https://*) url=$1; shift;;
        *) shift;;
    esac
done
case $url in
    https://github.com/tktkl/sing-box/releases/download/v0.1.0/sb-manager-0.1.0.tar.gz*) ;;
    *) exit 22;;
esac
cp "$SB_BOOTSTRAP_TEST_ASSETS/${url##*/}" "$target"
CURL
chmod +x "$temporary/bin/curl"
export PATH="$temporary/bin:$PATH" SB_BOOTSTRAP_TEST_ASSETS="$temporary/assets" SB_BOOTSTRAP_TEST_OUTPUT="$temporary/installed-arguments"
package_fixture() {
    tar -czf "$temporary/assets/sb-manager-0.1.0.tar.gz" -C "$temporary/source" sb-manager-0.1.0
    (cd "$temporary/assets"; sha256sum sb-manager-0.1.0.tar.gz > sb-manager-0.1.0.tar.gz.sha256)
}
package_fixture
bash "$temporary/standalone/install.sh" --address 2001:db8::1 --no-node
printf '%s\n' --address 2001:db8::1 --no-node > "$temporary/expected"
cmp "$temporary/expected" "$SB_BOOTSTRAP_TEST_OUTPUT"
rm "$SB_BOOTSTRAP_TEST_OUTPUT"
printf 'corrupt download\n' >> "$temporary/assets/sb-manager-0.1.0.tar.gz"
if bash "$temporary/standalone/install.sh" >/dev/null 2>&1; then printf 'Corrupt archive accepted\n' >&2; exit 1; fi
[[ ! -e $SB_BOOTSTRAP_TEST_OUTPUT ]]
ln -s /etc/passwd "$temporary/source/sb-manager-0.1.0/escape"
package_fixture
if bash "$temporary/standalone/install.sh" >/dev/null 2>&1; then printf 'Archive symlink accepted\n' >&2; exit 1; fi
[[ ! -e $SB_BOOTSTRAP_TEST_OUTPUT ]]
printf 'STANDALONE RELEASE FETCH, ARGUMENTS, CORRUPTION AND LINK REJECTION PASSED\n'
