#!/usr/bin/env bash
set -Eeuo pipefail
(( BASH_VERSINFO[0] >= 5 )) || { printf 'Requires Bash 5+\n' >&2; exit 1; }
bootstrap_install() (
    set -Eeuo pipefail
    (( EUID == 0 )) || { printf '请使用 sudo 或 root 运行安装器\n' >&2; exit 1; }
    [[ $(uname -s) == Linux ]] || { printf '安装仅支持 Linux\n' >&2; exit 1; }
    local dependency temporary release_version release_base archive digest member kind
    for dependency in curl tar gzip sha256sum; do
        command -v "$dependency" >/dev/null || { printf '缺少安装引导依赖: %s\n' "$dependency" >&2; exit 1; }
    done
    # Standalone installers are versioned with their release and always load
    # the matching complete package, never mutable main-branch modules.
    release_version=0.1.3
    archive="sb-manager-$release_version.tar.gz"
    release_base="https://github.com/tktkl/sing-box/releases/download/v$release_version"
    temporary=$(mktemp -d)
    trap 'rm -rf -- "$temporary"' EXIT
    printf '下载并验证 sb-manager v%s 正式发布包\n' "$release_version" >&2
    for member in "$archive.sha256" "$archive"; do
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 300 --retry 3 --retry-all-errors \
            "$release_base/$member" --output "$temporary/$member"
    done
    read -r digest member < "$temporary/$archive.sha256"
    [[ $digest =~ ^[a-f0-9]{64}$ && $member == "$archive" ]] || { printf '发布校验格式无效\n' >&2; exit 1; }
    printf '%s  %s\n' "$digest" "$temporary/$archive" | sha256sum -c - >&2
    tar -tzf "$temporary/$archive" > "$temporary/members"
    while IFS= read -r member; do
        [[ $member == "sb-manager-$release_version/"* && $member != *..* && $member != *\\* &&
           $member =~ ^[a-zA-Z0-9_./-]+$ ]] || { printf '发布包路径无效\n' >&2; exit 1; }
    done < "$temporary/members"
    tar -tvzf "$temporary/$archive" > "$temporary/member-types"
    while IFS= read -r kind; do
        [[ ${kind:0:1} == d || ${kind:0:1} == - ]] || { printf '发布包不允许链接或特殊文件\n' >&2; exit 1; }
    done < "$temporary/member-types"
    tar --no-same-owner --no-same-permissions -xzf "$temporary/$archive" -C "$temporary"
    [[ -f $temporary/sb-manager-$release_version/lib/common.sh && -f $temporary/sb-manager-$release_version/dependencies.lock.json ]] || { printf '发布包结构无效\n' >&2; exit 1; }
    bash "$temporary/sb-manager-$release_version/install.sh" "$@"
)
SB_HOME=''
if [[ -n ${BASH_SOURCE[0]:-} ]]; then SB_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); fi
if [[ -z $SB_HOME || ! -f $SB_HOME/lib/common.sh ]]; then bootstrap_install "$@"; exit; fi
source "$SB_HOME/lib/common.sh"
for module in links render service state certificates nodes core maintenance install import ui cli; do source "$SB_HOME/lib/$module.sh"; done
require_root
address='' no_node=true version=1.14.4
while (( $# )); do
    case $1 in
        --address) address=${2:?}; shift 2;;
        --no-node) no_node=true; shift;;
        --with-node) no_node=false; shift;;
        --reinstall) no_node=true; shift;;
        -v|--core-version) version=${2:?}; shift 2;;
        -l) shift;;
        -h|--help) printf 'install.sh [--address IP] [--with-node|--no-node] [--reinstall] [-v 1.14.4]\n默认仅安装；--with-node 显式创建一个 REALITY 节点。\n'; exit 0;;
        *) die '未知安装参数';;
    esac
done
[[ $(uname -s) == Linux ]] || die '安装仅支持 Linux；请用 Docker 运行开发测试'
source /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die '仅支持 Debian/Ubuntu'
case "$ID:$VERSION_ID" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;; *) die '此发行版尚未列入验证矩阵';; esac
export DEBIAN_FRONTEND=noninteractive
missing_dependencies=false
for dependency in jq curl openssl ss flock ps tar gzip sha256sum qrencode; do
    command -v "$dependency" >/dev/null || missing_dependencies=true
done
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing_dependencies=true
if [[ $missing_dependencies == true ]]; then
    apt-get -o APT::Update::Error-Mode=any update
    apt-get install -y bash jq curl ca-certificates openssl iproute2 util-linux procps tar gzip coreutils qrencode
fi
previous_script='' install_snapshot=''
install_files=(/etc/systemd/system/sb-manager.service /etc/systemd/system/sb-manager-renew.service /etc/systemd/system/sb-manager-renew.timer /etc/logrotate.d/sb-manager)
if [[ -L /usr/local/lib/sb-manager/script && -L $SB_ROOT/current ]]; then
    preflight_install
    previous_script=$(readlink /usr/local/lib/sb-manager/script)
    install_snapshot=$(mktemp -d "$SB_ROOT/run/install-rollback.XXXXXXXX")
    for installed_file in "${install_files[@]}"; do
        [[ ! -f $installed_file ]] || cp -p -- "$installed_file" "$install_snapshot/${installed_file##*/}"
    done
fi
finish_install() {
    local rc=$? installed_file
    trap - EXIT
    if (( rc != 0 )) && [[ -n $previous_script && $(readlink /usr/local/lib/sb-manager/script) != "$previous_script" ]]; then
        ln -s "$previous_script" /usr/local/lib/sb-manager/.script.rollback
        mv -Tf /usr/local/lib/sb-manager/.script.rollback /usr/local/lib/sb-manager/script
        for installed_file in "${install_files[@]}"; do
            if [[ -f $install_snapshot/${installed_file##*/} ]]; then cp -p -- "$install_snapshot/${installed_file##*/}" "$installed_file"
            else rm -f -- "$installed_file"; fi
        done
        systemctl daemon-reload
        /usr/local/bin/sb fix-all || note '旧脚本已恢复，但配置恢复未通过，请检查事务日志'
        note '升级失败，已恢复旧脚本和服务定义'
    fi
    [[ -z $install_snapshot ]] || rm -rf -- "$install_snapshot"
    exit "$rc"
}
trap finish_install EXIT
install_release "$SB_HOME"
[[ -x $SB_CORE ]] || download_core "$version"
create_systemd_units
SB_SERVICE_MODE=none /usr/local/bin/sb init ${address:+--address "$address"}
grant_runtime_access
systemctl daemon-reload
systemctl enable sb-manager.service sb-manager-renew.timer
systemctl start sb-manager-renew.timer
if [[ -n $previous_script ]]; then /usr/local/bin/sb fix-all; fi
if [[ $no_node == false ]]; then /usr/local/bin/sb add reality ${address:+--address "$address"}; fi
note '安装完成，输入 sb 打开菜单，再选择「添加节点」；未关闭防火墙'
