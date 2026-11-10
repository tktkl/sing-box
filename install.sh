#!/usr/bin/env bash
set -Eeuo pipefail
(( BASH_VERSINFO[0] >= 5 )) || { printf 'Requires Bash 5+\n' >&2; exit 1; }
SB_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SB_HOME/lib/common.sh"
source "$SB_HOME/lib/maintenance.sh"
source "$SB_HOME/lib/install.sh"
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
apt-get update
apt-get install -y bash jq curl ca-certificates openssl iproute2 util-linux procps tar gzip coreutils qrencode
install_release "$SB_HOME"
[[ -x $SB_CORE ]] || download_core "$version"
create_systemd_units
SB_SERVICE_MODE=none /usr/local/bin/sb init ${address:+--address "$address"}
grant_runtime_access
systemctl daemon-reload
systemctl enable sb-manager.service sb-manager-renew.timer
systemctl start sb-manager-renew.timer
if [[ $no_node == false ]]; then /usr/local/bin/sb add reality ${address:+--address "$address"}; fi
note '安装完成，使用 sb help 查看命令；未关闭防火墙'
