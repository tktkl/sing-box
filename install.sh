#!/usr/bin/env bash
set -Eeuo pipefail
(( BASH_VERSINFO[0] >= 5 )) || { printf 'Requires Bash 5+\n' >&2; exit 1; }
SB_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SB_HOME/lib/common.sh"
for module in links render service state certificates nodes maintenance install import cli; do source "$SB_HOME/lib/$module.sh"; done
require_root
address='' no_node=false version=1.14.4
while (( $# )); do
    case $1 in
        --address) address=${2:?}; shift 2;;
        --no-node) no_node=true; shift;;
        --reinstall) no_node=true; shift;;
        -v|--core-version) version=${2:?}; shift 2;;
        -l) shift;;
        -h|--help) printf 'install.sh [--address IP] [--no-node] [--reinstall] [-v 1.14.4]\n'; exit 0;;
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
note '安装完成，使用 sb help 查看命令；未关闭防火墙'
